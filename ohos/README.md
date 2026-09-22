# Codex CLI for native OpenHarmony ARM64

This port starts from OpenAI Codex CLI `rust-v0.153.4`, commit
`3d2ee51ca2d5db578f328aa75e20aa22c0197c9a`. It targets
`aarch64-unknown-linux-ohos`, not Android or desktop Linux. Node.js is not
required to run the native binary.

## Build

Use Linux or WSL2, Rust 1.95.0, and the Linux OpenHarmony native SDK. Install the
Rust target and the host tools `perl`, `make`, `cmake`, and `python3` first.

```sh
rustup target add aarch64-unknown-linux-ohos --toolchain 1.95.0
export OHOS_SDK_NATIVE=/path/to/openharmony/native
# An ext4 target directory is considerably faster than /mnt/c or /mnt/d in WSL.
export CARGO_TARGET_DIR=/path/to/codex-ohos-target
bash ohos/build.sh check dev
bash ohos/build.sh build release
```

The result is `$CARGO_TARGET_DIR/aarch64-unknown-linux-ohos/release/codex`.
`build.sh` prints the ELF architecture, interpreter and dynamic dependencies.
Use `build dev` for a faster unoptimized build. The source checkout, Cargo
lockfile and vendored dependency fixes are all required to reproduce the port.
For a quicker optimized build without link-time optimization, prefix the last
command with `CARGO_PROFILE_RELEASE_LTO=false`.

Build the optional bundled sandbox helper with genuine, statically linked
libcap (the script downloads the fixed kernel.org source and checks SHA-256):

```sh
export OHOS_LIBCAP_WORK_DIR=/path/to/libcap-build
CARGO_TARGET_DIR=/path/to/codex-ohos-bwrap-target bash ohos/build-bwrap.sh
export BINARY_SIGN_TOOL=/path/to/openharmony/toolchains/lib/binary-sign-tool
export BWRAP_BINARY=/path/to/codex-ohos-bwrap-target/aarch64-unknown-linux-ohos/release/bwrap.signed
"$BINARY_SIGN_TOOL" sign -selfSign 1 \
  -inFile "${BWRAP_BINARY%.signed}" -outFile "$BWRAP_BINARY"
export CODEX_BWRAP_SHA256=$(sha256sum "$BWRAP_BINARY" | cut -d ' ' -f 1)
# Rebuild the CLI with the bundled helper's integrity digest.
CARGO_PROFILE_RELEASE_LTO=false bash ohos/build.sh build release
```

Package the result with:

```sh
python3 ohos/package.py "$CARGO_TARGET_DIR/aarch64-unknown-linux-ohos/release/codex" \
  --sdk-native "$OHOS_SDK_NATIVE" --name codex-ohos-arm64-0.153.4-signed \
  --sign-tool "$BINARY_SIGN_TOOL" \
  --code-mode-host "$CARGO_TARGET_DIR/aarch64-unknown-linux-ohos/release/codex-code-mode-host" \
  --bwrap "$BWRAP_BINARY" --libcap-license "$OHOS_LIBCAP_WORK_DIR/libcap-2.78/License"
```

`--code-mode-host` is optional; see the Code Mode host section below for how to
produce that binary.

This produces an archive and an unpacked directory under `ohos/dist/`, including
the launcher, sandbox helper, licenses, ELF dependency reports and build metadata.
The helper retains its signed bytes to match the CLI's integrity digest.
The packager strips debug information only from the distribution copy of Codex
and then signs it. Never strip or modify an ELF after signing. It also writes a
SHA-256 sidecar for the archive. The packager
refuses Windows/x86 binaries and unexpected runtime dependencies.

## Port changes

- Use `/system/bin/sh` when no supported user shell is found.
- Exclude X11/Wayland clipboard dependencies. Text copy uses terminal OSC 52;
  pasting a clipboard image reports that the platform is unsupported.
- Exclude Linux Secret Service/D-Bus credential storage. Unsupported keyring
  operations return an error rather than succeeding against an in-memory mock.
  The CLI and MCP OAuth `auto` modes use files consistently, including logout;
  explicit keyring mode remains unsupported. The upstream CLI default is `file`.
- Build OpenSSL from source for the OHOS ABI.
- Use zstd's existing portable sort on OHOS, whose libc has no `qsort_r`.
- Correct nix's socket-message and ioctl types to match the OHOS libc ABI.
- The launcher discovers `/system/etc/security/certificates` for TLS roots when
  no explicit certificate environment variable is set. Certificate verification
  remains enabled.

## Deployment prerequisites

Use an authorized `hdc`/SSH terminal or native terminal application that can
execute ARM64 ELF files. A HAP/ArkTS GUI application is outside this CLI port.
On retail HarmonyOS PCs, code signing and an authorized native terminal such as
DevBox/CodeArts IDE are needed. The device's setting allowing external-source
extensions must also permit execution. An ordinary `uid=2000(shell)` HDC session
may refuse even signed files with exit 126; copying a file is not proof it runs.
Use the user's Docs directory and an authorized terminal for persistent use;
`/data/local/tmp` is only a development transfer location.
The linked SDK is OpenHarmony 6.0.0.47 (API 20), matching the existing WSL
browser build's `clang_base_path`. The executable needs the device's `libc.so`
and `libtime_service_ndk.so`; do not copy the SDK link stubs to the device.
The time service API was introduced in API 12, but compatibility of the entire
binary with older SDK/system versions has not been established.
The shell needs a writable home/configuration directory, temporary directory,
and project directory. If setting `CODEX_HOME`, create that directory first.

Extract the package into a directory in which the device permits execution, and
run its top-level `./codex` launcher. A terminal with a PTY is needed for the TUI;
use `./codex exec` for a noninteractive shell. For an `hdc` development session,
an example of writable configuration and temporary directories is:

```sh
mkdir -p /data/local/tmp/codex-home /data/local/tmp/codex-tmp
chmod 700 /data/local/tmp/codex-home /data/local/tmp/codex-tmp
export CODEX_HOME=/data/local/tmp/codex-home
export TMPDIR=/data/local/tmp/codex-tmp
./codex --version
./codex --help
```

Start by checking `codex --version` and `codex --help`. For ChatGPT login without
a device browser, use `codex login --device-auth`; follow the printed URL and
code on a separate device. Account policy still controls device authorization.
No existing Windows credentials are copied by this port.

Keep this port in its own extracted directory and update it using these build
scripts. The upstream installer selects Linux-musl for Linux/aarch64 and cannot
update an OHOS binary. To suppress upstream version prompts, add the top-level
setting `check_for_update_on_startup = false` to `$CODEX_HOME/config.toml`.
Do not install this archive into Codex's managed standalone package layout or
set `CODEX_MANAGED_BY_*` package-manager markers.

The default Linux command sandbox requires bubblewrap and kernel features that
must be validated on the target device. This port does not automatically disable
the sandbox or approval checks. Missing sandbox support is an error. Do not
interpret successful login or `--help` as proof that command isolation works.
Run `./smoke-test.sh` on the device to check startup and read-only sandbox
enforcement without logging in. It uses a fresh temporary configuration and
removes its own test directory afterward. It does not validate network isolation.

## Code Mode host (V8)

`codex-code-mode-host` embeds V8 through the `v8` (rusty_v8) crate, which
publishes no prebuilt archive for `aarch64-unknown-linux-ohos`. Build the
archive from the crate's own V8 sources instead:

```sh
export OHOS_SDK_NATIVE=/path/to/openharmony/native
export OHOS_REF_TREE=/path/to/ohos-adapted-chromium/src   # supplies gn toolchain + icudtl.dat
bash ohos/build-v8.sh
RUSTY_V8_ARCHIVE=$HOME/codex-ohos-v8/librusty_v8.a \
RUSTY_V8_SRC_BINDING_PATH=$HOME/codex-ohos-v8/gen/src_binding_ptrcomp_sandbox_release_aarch64-unknown-linux-ohos.rs \
  bash ohos/build.sh build release
```

`build-v8.sh` applies `ohos/v8/v8-ohos-source.patch` (OpenHarmony ifdefs plus an
OHOS gn toolchain) to a copy of the `v8-150.4.0` crate, cross-compiles
`librusty_v8.a` with gn + ninja, and regenerates the pointer-compression +
sandbox bindgen binding that the crate does not ship for any target. With
`RUSTY_V8_ARCHIVE` set, `build.sh` additionally builds
`codex-code-mode-host`; without it only the CLI is built. `rustc` links with
`-nodefaultlibs`, so `build.sh` adds the SDK's `libclang_rt.builtins.a` to the
host link for V8's `__clear_cache`.

The standalone voice host and native desktop clipboard remain outside the
minimal CLI. `rg`, Git and runtimes for any configured MCP servers are separate
device tools.

## Verification status

The ARM64 Release CLI, bubblewrap and `codex-code-mode-host` (source-built V8)
have linked successfully. On a connected HarmonyOS PC the host executed a
code-mode JavaScript cell (`text(6 * 7);` returned `42`), which exercises V8
initialisation, ICU data and JIT on device. The login and MCP
OAuth tests also pass cross-target `cargo check --tests`. On the Linux host,
167 shell-command tests and 172 selected clipboard/storage/OAuth tests passed.
Two gateway tests initially failed with inherited proxy variables; clearing
those variables only for the test process made the complete selection pass. A
connected device is required to validate TUI rendering, PTY/process handling,
TLS/login, file editing, and sandbox behavior. The SDK's `libc.so` is a link
stub, so it cannot be used as a working runtime for QEMU smoke tests.

## Sources

- [OpenAI Codex CLI](https://developers.openai.com/codex/cli)
- [Rust OpenHarmony target support](https://doc.rust-lang.org/rustc/platform-support/openharmony.html)
- [Huawei: sign and deploy native tools to the PC user directory](https://consumer.huawei.com/cn/support/content/zh-cn16078461/)
- [Huawei: running external-source extensions](https://consumer.huawei.com/cn/support/content/zh-cn16079826/)
- Upstream licenses and notices remain in the repository and vendored crates.
