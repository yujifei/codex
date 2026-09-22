#!/usr/bin/env bash
# Cross-build the rusty_v8 static archive (librusty_v8.a) and its bindgen
# binding for aarch64-unknown-linux-ohos, then wire them into the CLI build.
#
# rusty_v8 publishes no prebuilt archive for this target, so the V8 15.0
# sources shipped inside the `v8` crate are patched for OpenHarmony (see
# ohos/v8/v8-ohos-source.patch) and compiled with the OHOS SDK clang through gn
# + ninja. The OHOS gn toolchain and the musl/libc++ layout come from a
# Chromium tree that already targets OpenHarmony.
#
# Required environment:
#   OHOS_SDK_NATIVE   SDK native dir (…/openharmony/native)
#   OHOS_REF_TREE     Chromium secondary-development tree with OHOS support
# Optional environment (defaults shown):
#   V8_CRATE_SRC      pristine v8-150.4.0 crate source (cargo registry)
#   V8_WORK           $HOME/codex-ohos-v8/ws   patched working copy
#   V8_OUT            $HOME/codex-ohos-v8      artifacts (librusty_v8.a, gen/)
#   RUST_SYSROOT      host rust toolchain used by gn for bindgen/proc macros
#   BINDGEN_ROOT      rust-bindgen install (bin/ + lib/)
#   GN_TOOLS          dir containing gn and ninja binaries
set -euo pipefail

: "${OHOS_SDK_NATIVE:?Set OHOS_SDK_NATIVE to the SDK native directory}"
: "${OHOS_REF_TREE:?Set OHOS_REF_TREE to an OHOS-adapted Chromium tree}"
V8_CRATE_SRC=${V8_CRATE_SRC:-"$HOME/codex-ohos-tools/cargo/registry/src/index.crates.io-1949cf8c6b5b557f/v8-150.4.0"}
V8_WORK=${V8_WORK:-"$HOME/codex-ohos-v8/ws"}
V8_OUT=${V8_OUT:-"$HOME/codex-ohos-v8"}
RUST_SYSROOT=${RUST_SYSROOT:-"$HOME/codex-ohos-tools/rustup/toolchains/1.95.0-x86_64-unknown-linux-gnu"}
BINDGEN_ROOT=${BINDGEN_ROOT:-"$HOME/codex-ohos-v8/rust-bindgen"}
GN_TOOLS=${GN_TOOLS:-"$HOME/codex-ohos-v8/binaries"}
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BINDING_NAME=src_binding_ptrcomp_sandbox_release_aarch64-unknown-linux-ohos.rs

for tool in gn ninja; do
    command -v "$tool" >/dev/null || export PATH="$GN_TOOLS/$tool:$PATH"
done

# 1. Materialise a patched working copy of the crate's V8 sources.
if [[ ! -d $V8_WORK/v8 ]]; then
    mkdir -p -- "$(dirname -- "$V8_WORK")"
    cp -a -- "$V8_CRATE_SRC" "$V8_WORK"
fi
(cd -- "$V8_WORK" && patch -p1 --forward < "$here/v8/v8-ohos-source.patch") || true

# 2. Point gn at the OHOS SDK and the host Rust toolchain; the crate tarball
#    omits the ICU data blob, so take it from the reference Chromium tree.
ln -sfn -- "$OHOS_REF_TREE/ohos_sdk" "$V8_WORK/ohos_sdk"
ln -sfn -- "$RUST_SYSROOT" "$V8_WORK/third_party/rust-toolchain"
mkdir -p -- "$V8_WORK/third_party/icu/common"
cp -n -- "$OHOS_REF_TREE/third_party/icu/common/icudtl.dat" \
    "$V8_WORK/third_party/icu/common/icudtl.dat"
cd -- "$V8_WORK"

# 3. Configure. These args mirror what rusty_v8's build.rs emits for
#    `default + v8_enable_sandbox` in release, minus the features whose sources
#    the published crate tarball does not ship (temporal, partition_alloc).
gn gen out/ohos --args="target_os=\"ohos\" target_cpu=\"arm64\" is_debug=false is_clang=true use_musl=true use_sysroot=false use_custom_libcxx=true clang_base_path=\"//ohos_sdk/openharmony/native/llvm\" clang_version=\"22\" treat_warnings_as_errors=false v8_enable_sandbox=true v8_enable_external_code_space=true v8_enable_pointer_compression=true v8_enable_v8_checks=false v8_enable_temporal_support=false v8_enable_partition_alloc=false rusty_v8_enable_simdutf=false use_glib=false rust_sysroot_absolute=\"$RUST_SYSROOT\" rust_bindgen_root=\"$BINDGEN_ROOT\""

# 4. Build the monolith: binding.o + all of V8 + static libc++.
ninja -C out/ohos rusty_v8

# 5. The crate ships no ptrcomp+sandbox binding for any target, so generate it
#    with the same bindgen options build.rs uses, plus the target defines gn
#    computed for //v8:v8_headers.
mkdir -p -- "$V8_OUT/gen"
gn desc out/ohos //v8:v8_headers defines > "$V8_OUT/gen/v8_headers_defines.txt"
args=(-x c++ -std=c++20 -nostdinc++ -Iv8/include -I.
    -isystembuildtools/third_party/libc++
    -isystemthird_party/libc++/src/include
    -isystemthird_party/libc++abi/src/include
    "-isystem$OHOS_SDK_NATIVE/llvm/lib/clang/22/include"
    --target=aarch64-linux-ohos
    "--sysroot=$OHOS_SDK_NATIVE/sysroot")
while read -r def; do
    [[ -n $def ]] && args+=("-D$def")
done < "$V8_OUT/gen/v8_headers_defines.txt"
LIBCLANG_PATH="$BINDGEN_ROOT/lib" LD_LIBRARY_PATH="$BINDGEN_ROOT/lib" \
    PATH="$BINDGEN_ROOT/bin:$PATH" \
    bindgen src/binding.hpp \
    --generate-cstr \
    --rustified-enum '.*UseCounterFeature' --rustified-enum '.*ModuleImportPhase' \
    --rustified-enum '.*Intercepted' \
    --bitfield-enum '.*GCType' --bitfield-enum '.*GCCallbackFlags' \
    --allowlist-item 'v8__.*' --allowlist-item 'cppgc__.*' --allowlist-item 'RustObj' \
    --allowlist-item 'memory_span_t' --allowlist-item 'const_memory_span_t' \
    --allowlist-item 'ExternalConstOneByteStringResource' \
    --blocklist-item 'cppgc.*Visitor' --blocklist-item 'RustObj.*Trace' \
    -o "$V8_OUT/gen/$BINDING_NAME" -- "${args[@]}"

# 6. Publish the artifacts for ohos/build.sh.
cp -- out/ohos/obj/librusty_v8.a "$V8_OUT/librusty_v8.a"
echo "librusty_v8.a: $V8_OUT/librusty_v8.a"
echo "binding:       $V8_OUT/gen/$BINDING_NAME"
echo "Now build the host with:"
echo "  RUSTY_V8_ARCHIVE=$V8_OUT/librusty_v8.a \\"
echo "  RUSTY_V8_SRC_BINDING_PATH=$V8_OUT/gen/$BINDING_NAME \\"
echo "  bash ohos/build.sh build release"
