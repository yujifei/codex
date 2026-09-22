#!/usr/bin/env bash
# Cross-compile the native CLI on Linux (including WSL2).
set -euo pipefail
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
target=aarch64-unknown-linux-ohos
mode=${1:-build}
profile=${2:-release}
if [[ $mode != build && $mode != check ]]; then
    echo 'Usage: bash ohos/build.sh [build|check] [release|dev]' >&2
    exit 2
fi
if [[ $profile != release && $profile != dev ]]; then
    echo 'Profile must be release or dev.' >&2
    exit 2
fi
if [[ $(uname -s) != Linux ]]; then
    echo 'Use Linux or WSL2 with the Linux OpenHarmony SDK.' >&2
    exit 2
fi
: "${OHOS_SDK_NATIVE:?Set OHOS_SDK_NATIVE to the SDK native directory}"
export OHOS_SDK_NATIVE
OHOS_SDK_NATIVE=$(cd -- "$OHOS_SDK_NATIVE" && pwd)
for tool in clang clang++ llvm-ar llvm-ranlib llvm-readelf; do
    if [[ ! -x "$OHOS_SDK_NATIVE/llvm/bin/$tool" ]]; then
        echo "Missing SDK tool: $OHOS_SDK_NATIVE/llvm/bin/$tool" >&2
        exit 2
    fi
done
if [[ ! -d "$OHOS_SDK_NATIVE/sysroot/usr/lib/aarch64-linux-ohos" ]]; then
    echo 'SDK does not contain the ARM64 OHOS sysroot.' >&2
    exit 2
fi
for tool in cargo rustc perl make cmake python3; do
    command -v "$tool" >/dev/null || { echo "Missing host tool: $tool" >&2; exit 2; }
done
cd -- "$repo_dir/codex-rs"
if [[ ! -d "$(rustc --print target-libdir --target "$target")" ]]; then
    echo "Install the target first: rustup target add $target" >&2
    exit 2
fi
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-"$repo_dir/target-ohos"}
mkdir -p -- "$CARGO_TARGET_DIR/ohos-tools"
export CARGO_TARGET_DIR
CARGO_TARGET_DIR=$(cd -- "$CARGO_TARGET_DIR" && pwd)
cc_wrapper="$CARGO_TARGET_DIR/ohos-tools/ohos-clang"
cxx_wrapper="$CARGO_TARGET_DIR/ohos-tools/ohos-clang++"
cp -- "$repo_dir/ohos/clang-wrapper.sh" "$cc_wrapper"
cp -- "$repo_dir/ohos/clang-wrapper.sh" "$cxx_wrapper"
chmod +x -- "$cc_wrapper" "$cxx_wrapper"
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_LINKER="$cc_wrapper"
export CC_aarch64_unknown_linux_ohos="$cc_wrapper"
export CXX_aarch64_unknown_linux_ohos="$cxx_wrapper"
export AR_aarch64_unknown_linux_ohos="$OHOS_SDK_NATIVE/llvm/bin/llvm-ar"
export RANLIB_aarch64_unknown_linux_ohos="$OHOS_SDK_NATIVE/llvm/bin/llvm-ranlib"
# Give CMake-based dependencies the target SDK, never the host toolchain.
export CMAKE_TOOLCHAIN_FILE_aarch64_unknown_linux_ohos="$OHOS_SDK_NATIVE/build/cmake/ohos.toolchain.cmake"
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
# code-mode host is only built when a locally cross-compiled librusty_v8.a is
# supplied through RUSTY_V8_ARCHIVE.
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
