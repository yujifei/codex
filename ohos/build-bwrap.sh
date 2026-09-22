#!/usr/bin/env bash
# Build genuine libcap and bubblewrap for OHOS; never use host libcap.
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
target=aarch64-unknown-linux-ohos
libcap_version=2.78
libcap_sha256=0d621e562fd932ccf67b9660fb018e468a683d7b827541df27813228c996bb11
libcap_url="https://www.kernel.org/pub/linux/libs/security/linux-privs/libcap2/libcap-${libcap_version}.tar.xz"

kernel=$(uname -s)
case $kernel in
    Linux | OpenHarmony | HarmonyOS | OHOS) ;;
    *)
        echo "Unsupported kernel: $kernel. Use Linux or WSL2 with the Linux OpenHarmony SDK," >&2
        echo 'or build directly on an ARM64 OpenHarmony host, e.g. inside HiShell.' >&2
        exit 2
        ;;
esac
if [[ $kernel != Linux && $(uname -m) != aarch64 ]]; then
    echo 'Building on the device requires an ARM64 OpenHarmony host.' >&2
    exit 2
fi
: "${OHOS_LIBCAP_WORK_DIR:?Set OHOS_LIBCAP_WORK_DIR to a task-local build directory}"
if [[ ${CODEX_SKIP_BWRAP_BUILD+x} ]]; then
    echo 'Unset CODEX_SKIP_BWRAP_BUILD; this script must build the real sandbox helper.' >&2
    exit 2
fi
for tool in cargo rustc make pkg-config tar xz sha256sum; do
    command -v "$tool" >/dev/null || { echo "Missing host tool: $tool" >&2; exit 2; }
done
# Only _makenames runs on the build host; on the device that is the same
# compiler as every other object.
build_cc=$(command -v cc || command -v clang || true)
if [[ -z $build_cc ]]; then
    echo 'Missing host tool: cc (or clang)' >&2
    exit 2
fi
mkdir -p -- "$OHOS_LIBCAP_WORK_DIR"
work_dir=$(cd -- "$OHOS_LIBCAP_WORK_DIR" && pwd)
source_dir="$work_dir/libcap-$libcap_version"
prefix="$work_dir/target-$target"
archive="$work_dir/libcap-$libcap_version.tar.xz"
if [[ ! -f "$archive" ]]; then
    command -v curl >/dev/null || { echo 'Missing host tool: curl' >&2; exit 2; }
    curl --fail --location --retry 2 --connect-timeout 20 --max-time 120 \
        "$libcap_url" --output "$archive.part"
    mv -- "$archive.part" "$archive"
fi
printf '%s  %s\n' "$libcap_sha256" "$archive" | sha256sum --check --status
tar -xJf "$archive" -C "$work_dir"

export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-"$work_dir/cargo-target"}
mkdir -p -- "$CARGO_TARGET_DIR/ohos-tools"
CARGO_TARGET_DIR=$(cd -- "$CARGO_TARGET_DIR" && pwd)
# Locates the SDK (Harmonybrew when building on the device) and shadows uname,
# which libcap's makefiles do not recognise as a supported host.
source "$repo_dir/ohos/ohos-host-env.sh" "$CARGO_TARGET_DIR/ohos-tools/shims"
cc_wrapper="$CARGO_TARGET_DIR/ohos-tools/ohos-clang"
cp -- "$repo_dir/ohos/clang-wrapper.sh" "$cc_wrapper"
chmod +x -- "$cc_wrapper"

# _makenames runs on the build host; all library objects use the OHOS compiler.
# Build/install only the static cap library, not PAM, Go, utilities or setuid tools.
make_args=(
    "CC=$cc_wrapper" "BUILD_CC=$build_cc"
    "AR=$OHOS_SDK_NATIVE/llvm/bin/llvm-ar"
    "RANLIB=$OHOS_SDK_NATIVE/llvm/bin/llvm-ranlib"
    "prefix=$prefix" DESTDIR= lib=lib SHARED=no PTHREADS=no GOLANG=no PAM_CAP=no USE_GPERF=no
)
make -C "$source_dir/libcap" "${make_args[@]}" clean
make -C "$source_dir/libcap" "${make_args[@]}" -j "${CARGO_BUILD_JOBS:-2}" install-static-cap
"$OHOS_SDK_NATIVE/llvm/bin/llvm-readelf" -h "$prefix/lib/libcap.a"

# Isolate pkg-config to this target prefix. Target-scoped variables do not
# affect host build-script dependencies, and no host libcap search path is used.
export PKG_CONFIG_ALLOW_CROSS_aarch64_unknown_linux_ohos=1
export PKG_CONFIG_LIBDIR_aarch64_unknown_linux_ohos="$prefix/lib/pkgconfig"
export PKG_CONFIG_PATH_aarch64_unknown_linux_ohos=
export PKG_CONFIG_SYSROOT_DIR_aarch64_unknown_linux_ohos=/
# pkg-config only reads the target-scoped names above while cross compiling; on
# an OpenHarmony host the two triples match, so publish the plain names too.
if [[ $(rustc -vV | sed -n 's/^host: //p') == "$target" ]]; then
    export PKG_CONFIG_ALLOW_CROSS=1
    export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
    export PKG_CONFIG_PATH=
    export PKG_CONFIG_SYSROOT_DIR=/
fi
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_LINKER="$cc_wrapper"
export CC_aarch64_unknown_linux_ohos="$cc_wrapper"
export AR_aarch64_unknown_linux_ohos="$OHOS_SDK_NATIVE/llvm/bin/llvm-ar"
export RANLIB_aarch64_unknown_linux_ohos="$OHOS_SDK_NATIVE/llvm/bin/llvm-ranlib"
cd -- "$repo_dir/codex-rs"
cargo build --locked --release --target "$target" -p codex-bwrap --bin bwrap
binary="$CARGO_TARGET_DIR/$target/release/bwrap"
"$OHOS_SDK_NATIVE/llvm/bin/llvm-readelf" -h -l -d "$binary"
printf 'libcap source: %s\nlibcap SHA-256: %s\nOHOS bubblewrap: %s\n' \
    "$libcap_url" "$libcap_sha256" "$binary"
echo 'Device namespace/seccomp permissions remain unverified; sandbox and setuid settings are unchanged.'
