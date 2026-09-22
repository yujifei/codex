#!/usr/bin/env bash
# Build the native CLI directly on an OpenHarmony host (host == target).
#
# This is the on-device counterpart of build.sh: no cross sysroot juggling and
# no compiler wrappers are needed because the host toolchain (Harmonybrew's
# llvm-gcc-compat clang plus the rustup aarch64-unknown-linux-ohos toolchain)
# already targets OpenHarmony, and the SDK's wrapped ld.lld signs binaries at
# link time.
set -euo pipefail
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
target=aarch64-unknown-linux-ohos
mode=${1:-build}
profile=${2:-release}
if [[ $mode != build && $mode != check ]]; then
    echo 'Usage: bash ohos/build-native.sh [build|check] [release|dev]' >&2
    exit 2
fi
if [[ $profile != release && $profile != dev ]]; then
    echo 'Profile must be release or dev.' >&2
    exit 2
fi
kernel=$(uname -s)
case $kernel in
    Linux | OpenHarmony | HarmonyOS | OHOS) ;;
    *)
        echo "Unsupported kernel: $kernel. Use an ARM64 OpenHarmony host, e.g. inside HiShell." >&2
        exit 2
        ;;
esac
if [[ $(uname -m) != aarch64 ]]; then
    echo 'Use this script on an ARM64 OpenHarmony host, e.g. inside HiShell.' >&2
    exit 2
fi
for tool in cargo rustc perl make cmake python3 clang clang++; do
    command -v "$tool" >/dev/null || { echo "Missing host tool: $tool"; exit 2; }
done
cd -- "$repo_dir/codex-rs"
if [[ ! -d "$(rustc --print target-libdir --target "$target")" ]]; then
    echo "Install the toolchain first: rustup toolchain install $(rustc --version | cut -d' ' -f2)" >&2
    exit 2
fi
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-"$repo_dir/target-ohos"}
export CARGO_TARGET_DIR
mkdir -p -- "$CARGO_TARGET_DIR"
CARGO_TARGET_DIR=$(cd -- "$CARGO_TARGET_DIR" && pwd)
shim_dir="$CARGO_TARGET_DIR/ohos-tools/shims"
# Locates the SDK and shadows uname, which third party configure scripts
# (OpenSSL, CMake probes) do not recognise as a supported host.
source "$repo_dir/ohos/ohos-host-env.sh" "$shim_dir"
# Harmonybrew publishes liblzma and libbz2 as shared libraries, so the
# pkg-config probes in lzma-sys and bzip2-sys link them dynamically and the
# resulting CLI carries NEEDED entries that ohos/package.py refuses to bundle.
# Hide just those two packages so both crates fall back to their bundled static
# sources, and forward every other probe to the real pkg-config.
mkdir -p -- "$shim_dir"
real_pkg_config=$(
    PATH="${PATH#"$shim_dir":}" command -v pkg-config ||
        PATH="${PATH#"$shim_dir":}" command -v pkgconf || true
)
if [[ -n $real_pkg_config ]]; then
    cat > "$shim_dir/pkg-config" <<EOF
#!/system/bin/sh
for arg in "\$@"; do
    case \$arg in
        bzip2 | liblzma) exit 1 ;;
    esac
done
exec "$real_pkg_config" "\$@"
EOF
    chmod +x -- "$shim_dir/pkg-config"
    export PKG_CONFIG="$shim_dir/pkg-config"
fi
# Name the compilers explicitly: Harmonybrew exposes the OHOS clang under
# several aliases and CMake-based dependencies must not pick a host compiler.
export CC_aarch64_unknown_linux_ohos=$(command -v clang)
export CXX_aarch64_unknown_linux_ohos=$(command -v clang++)
# code-mode-protocol shells out to protoc; the vendored protoc binary is
# unsigned and cannot execute on OpenHarmony, so prefer a signed system one.
if command -v protoc >/dev/null 2>&1; then
    export PROTOC
    PROTOC=$(command -v protoc)
fi
export AR_aarch64_unknown_linux_ohos="$OHOS_SDK_NATIVE/llvm/bin/llvm-ar"
export RANLIB_aarch64_unknown_linux_ohos="$OHOS_SDK_NATIVE/llvm/bin/llvm-ranlib"
# bindgen-driven build dependencies (vendored zstd-sys) look for libclang
# through clang-sys, which does not know about the OHOS SDK layout.
if [[ -z ${LIBCLANG_PATH:-} ]]; then
    for cand in "$OHOS_SDK_NATIVE/llvm/lib" "$OHOS_SDK_NATIVE/llvm/lib64"; do
        if compgen -G "$cand/libclang.so*" >/dev/null; then
            LIBCLANG_PATH=$cand
            export LIBCLANG_PATH
            break
        fi
    done
fi
# Keep bundled C++ runtime lookup working when Codex hardens its environment.
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_RUSTFLAGS="${CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_RUSTFLAGS:-} -C link-arg=-Wl,-rpath,\$ORIGIN/../lib"
# OHOS uses its own musl ABI; do not substitute a Linux-musl/Android target.
export CFLAGS_aarch64_unknown_linux_ohos="${CFLAGS_aarch64_unknown_linux_ohos:-} -D__MUSL__"
export CXXFLAGS_aarch64_unknown_linux_ohos="${CXXFLAGS_aarch64_unknown_linux_ohos:-} -D__MUSL__"
export CARGO_PROFILE_DEV_DEBUG=${CARGO_PROFILE_DEV_DEBUG:-0}
export CARGO_PROFILE_RELEASE_DEBUG=${CARGO_PROFILE_RELEASE_DEBUG:-0}
cargo "$mode" --locked --keep-going --target "$target" --profile "$profile" -p codex-cli --bin codex
profile_dir=$profile
if [[ $profile == dev ]]; then
    profile_dir=debug
fi
# rusty_v8 publishes no prebuilt archive for aarch64-unknown-linux-ohos, so the
# code-mode host is only built when a locally built librusty_v8.a is supplied
# through RUSTY_V8_ARCHIVE. Reuse the cross-compiled archive: it is a target
# artifact and needs no rebuild on the device.
host_binary=''
if [[ -n ${RUSTY_V8_ARCHIVE:-} ]]; then
    export RUSTY_V8_ARCHIVE
    # librusty_v8.a embeds a static libc++; keep the v8 crate from also asking
    # the linker for a dynamic C++ standard library.
    export CXXSTDLIB=
    # rustc links with -nodefaultlibs, so clang's compiler-rt builtins are never
    # added automatically. V8's ARM64 CpuFeatures::FlushICache needs
    # __clear_cache, which glibc targets get from libgcc_s but OHOS does not.
    builtins=$(
        "$OHOS_SDK_NATIVE/llvm/bin/clang" --target=aarch64-linux-ohos \
            --sysroot="$OHOS_SDK_NATIVE/sysroot" -print-libgcc-file-name
    )
    if [[ ! -f $builtins ]]; then
        echo "Missing compiler-rt builtins archive: $builtins" >&2
        exit 2
    fi
    export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_RUSTFLAGS="${CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_RUSTFLAGS:-} -C link-arg=$builtins"
    cargo "$mode" --locked --keep-going --target "$target" --profile "$profile" \
        -p codex-code-mode-host --bin codex-code-mode-host
    host_binary="$CARGO_TARGET_DIR/$target/$profile_dir/codex-code-mode-host"
fi
if [[ $mode == check ]]; then
    exit 0
fi
binary="$CARGO_TARGET_DIR/$target/$profile_dir/codex"
"$OHOS_SDK_NATIVE/llvm/bin/llvm-readelf" -h -l -d "$binary"
echo "Native ARM64 OHOS executable: $binary"
if [[ -n $host_binary ]]; then
    "$OHOS_SDK_NATIVE/llvm/bin/llvm-readelf" -h -l -d "$host_binary"
    echo "Native ARM64 OHOS code-mode host: $host_binary"
fi
