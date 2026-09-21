#!/usr/bin/env python3
"""Package a linked OHOS CLI; never substitute SDK libc link stubs for a runtime."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tarfile


def inspect_elf(path, readelf):
    with path.open("rb") as stream:
        header = stream.read(20)
    if (
        len(header) != 20
        or header[:6] != b"\x7fELF\x02\x01"
        or struct.unpack_from("<H", header, 18)[0] != 183
    ):
        raise ValueError(f"Not a little-endian ARM64 ELF: {path}")
    return subprocess.check_output([str(readelf), "-l", "-d", str(path)], text=True)


def signature_report(path, sign_tool):
    report = subprocess.check_output(
        [str(sign_tool), "display-sign", "-inFile", str(path)], text=True
    )
    if "code signature is self-sign" not in report:
        raise ValueError(f"Missing self-signed ELF code signature: {path}\n{report}")
    return report


def sign_elf(path, sign_tool):
    signed = path.with_name(path.name + ".signed")
    subprocess.run(
        [
            str(sign_tool),
            "sign",
            "-inFile",
            str(path),
            "-outFile",
            str(signed),
            "-selfSign",
            "1",
        ],
        check=True,
    )
    report = signature_report(signed, sign_tool)
    signed.chmod(path.stat().st_mode & 0o777)
    signed.replace(path)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--sdk-native", type=Path, required=True)
    parser.add_argument("--bwrap", type=Path, help="Cross-built bubblewrap executable")
    parser.add_argument("--libcap-license", type=Path)
    parser.add_argument(
        "--sign-tool",
        type=Path,
        help="SDK binary-sign-tool; sign CLI after stripping. Bwrap must already be signed.",
    )
    parser.add_argument("--name", default="codex-ohos-arm64")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", args.name) or args.name in {".", ".."}:
        parser.error("name must be a simple directory name")
    here = Path(__file__).resolve().parent
    sdk = args.sdk_native.resolve()
    readelf = sdk / "llvm/bin/llvm-readelf"
    elf_report = inspect_elf(args.binary, readelf)
    if "ld-musl-aarch64.so.1" not in elf_report:
        raise ValueError("Missing the OHOS/musl ARM64 dynamic interpreter")
    needed = re.findall(r"\(NEEDED\).*?\[(.*?)\]", elf_report)
    runtime_libraries = []
    for name in needed:
        if name in {
            "libc.so",
            "libm.so",
            "libdl.so",
            "libpthread.so",
            "librt.so",
            # iana-time-zone uses the device's Time Service (API 12+).
            "libtime_service_ndk.so",
        }:
            continue
        if name not in {"libc++_shared.so", "libunwind.so"}:
            raise ValueError(
                f"Resolve this runtime dependency before packaging: {name}"
            )
        library = sdk / "llvm/lib/aarch64-unknown-linux-ohos" / name
        inspect_elf(library, readelf)
        runtime_libraries.append(library)
    if runtime_libraries and "$ORIGIN/../lib" not in elf_report:
        raise ValueError("Binary needs an ORIGIN-relative runtime library search path")
    bwrap_report = None
    if args.bwrap:
        bwrap_report = inspect_elf(args.bwrap, readelf)
        if "ld-musl-aarch64.so.1" not in bwrap_report:
            raise ValueError("Bubblewrap is missing the OHOS/musl ARM64 interpreter")
        bwrap_needed = re.findall(r"\(NEEDED\).*?\[(.*?)\]", bwrap_report)
        if set(bwrap_needed) - {
            "libc.so",
            "libm.so",
            "libdl.so",
            "libpthread.so",
            "librt.so",
        }:
            raise ValueError(
                f"Unexpected bubblewrap runtime dependencies: {bwrap_needed}"
            )
        if not args.libcap_license or not args.libcap_license.is_file():
            raise ValueError("Bundled bubblewrap requires the static libcap license")
        if args.sign_tool:
            # Signing changes bytes: sign bwrap BEFORE pinning its digest in Codex.
            signature_report(args.bwrap, args.sign_tool)
    package_dir = here / "dist" / args.name
    package_dir.mkdir(parents=True, exist_ok=False)
    (package_dir / "bin").mkdir()
    shutil.copy2(args.binary, package_dir / "bin/codex")
    shutil.copy2(here / "codex", package_dir / "codex")
    shutil.copy2(here / "smoke-test.sh", package_dir / "smoke-test.sh")
    (package_dir / "bin/codex").chmod(0o755)
    (package_dir / "codex").chmod(0o755)
    (package_dir / "smoke-test.sh").chmod(0o755)
    # Keep the original build for debugging and strip only the distribution copy.
    subprocess.run(
        [
            str(sdk / "llvm/bin/llvm-strip"),
            "--strip-debug",
            str(package_dir / "bin/codex"),
        ],
        check=True,
    )
    signatures = {}
    if args.sign_tool:
        signatures["bin/codex"] = sign_elf(package_dir / "bin/codex", args.sign_tool)
    if args.bwrap:
        resources = package_dir / "codex-resources"
        resources.mkdir()
        shutil.copy2(args.bwrap, resources / "bwrap")
        (resources / "bwrap").chmod(0o755)
        if args.sign_tool:
            signatures["codex-resources/bwrap"] = signature_report(
                resources / "bwrap", args.sign_tool
            )
        licenses = package_dir / "licenses"
        licenses.mkdir()
        shutil.copy2(
            here.parent / "codex-rs/vendor/bubblewrap/COPYING",
            licenses / "bubblewrap.txt",
        )
        shutil.copy2(args.libcap_license, licenses / "libcap.txt")
        (package_dir / "bwrap-elf-dependencies.txt").write_text(
            bwrap_report, encoding="utf-8"
        )
    for source in runtime_libraries:
        (package_dir / "lib").mkdir(exist_ok=True)
        shutil.copy2(source, package_dir / "lib" / source.name)
        if args.sign_tool:
            signatures[f"lib/{source.name}"] = sign_elf(
                package_dir / "lib" / source.name, args.sign_tool
            )
    for name in ("LICENSE", "NOTICE"):
        source = here.parent / name
        if source.exists():
            shutil.copy2(source, package_dir / name)
    shutil.copy2(here / "README.md", package_dir / "README.md")
    shutil.copy2(here / "README.zh-CN.md", package_dir / "README.zh-CN.md")
    (package_dir / "elf-dependencies.txt").write_text(elf_report, encoding="utf-8")
    with (package_dir / "bin/codex").open("rb") as stream:
        binary_sha256 = hashlib.file_digest(stream, "sha256").hexdigest()
    sdk_info = json.loads((sdk / "oh-uni-package.json").read_text(encoding="utf-8"))
    metadata = {
        "version": "0.153.4",
        "target": "aarch64-unknown-linux-ohos",
        "sdk_version": sdk_info["version"],
        "sdk_api": sdk_info["apiVersion"],
        "source_commit": subprocess.check_output(
            ["git", "-C", str(here.parent), "rev-parse", "HEAD"], text=True
        ).strip(),
        "source_modified": True,
        "needed": needed,
        "device_tested": False,
        "code_signature": "self-sign" if args.sign_tool else "unsigned",
        "sha256": binary_sha256,
    }
    if args.bwrap:
        with args.bwrap.open("rb") as stream:
            metadata["bwrap_sha256"] = hashlib.file_digest(stream, "sha256").hexdigest()
    (package_dir / "build-info.json").write_text(
        json.dumps(metadata, indent=2) + "\n", encoding="utf-8"
    )
    if signatures:
        (package_dir / "code-signatures.json").write_text(
            json.dumps(signatures, indent=2) + "\n", encoding="utf-8"
        )
    archive = package_dir.parent / (package_dir.name + ".tar.gz")

    def archive_permissions(info):
        # WSL's Windows mounts can report every source file as world-writable.
        relative = Path(info.name).relative_to(package_dir.name).as_posix()
        executable = relative in {
            "codex",
            "bin/codex",
            "codex-resources/bwrap",
            "smoke-test.sh",
        }
        info.mode = 0o755 if info.isdir() or executable else 0o644
        info.uid = info.gid = 0
        info.uname = info.gname = "root"
        return info

    with tarfile.open(archive, "x:gz") as output:
        output.add(package_dir, arcname=package_dir.name, filter=archive_permissions)
    with archive.open("rb") as stream:
        archive_sha256 = hashlib.file_digest(stream, "sha256").hexdigest()
    archive.with_suffix(archive.suffix + ".sha256").write_text(
        f"{archive_sha256}  {archive.name}\n", encoding="utf-8"
    )
    print(archive)


if __name__ == "__main__":
    main()
