#!/usr/bin/env bash
set -euo pipefail
: "${OHOS_SDK_NATIVE:?Set OHOS_SDK_NATIVE to the SDK native directory}"
compiler=clang
if [[ ${0##*/} == *clang++* ]]; then
    compiler=clang++
fi
exec "$OHOS_SDK_NATIVE/llvm/bin/$compiler" \
    --target=aarch64-linux-ohos \
    --sysroot="$OHOS_SDK_NATIVE/sysroot" \
    -D__MUSL__ "$@"
