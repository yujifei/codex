# shellcheck shell=bash
# Shared host setup for the ARM64 OpenHarmony builds where host == target.
#
# Source it with the directory that should hold the generated tool shims:
#
#   source "$repo_dir/ohos/ohos-host-env.sh" "$CARGO_TARGET_DIR/ohos-tools/shims"
#
# It exports OHOS_SDK_NATIVE and, on hosts whose uname does not report Linux,
# prepends a shim directory to PATH. Callers must run under `set -euo pipefail`.

ohos_shim_parent=${1:?Usage: source ohos-host-env.sh <shim-directory>}
# Harmonybrew installs the SDK without the usual `native/` level, so the prefix
# itself is the "native" directory: <prefix>/{llvm,sysroot,build,build-tools}.
if [[ -z ${OHOS_SDK_NATIVE:-} ]]; then
    for cand in "${HOMEBREW_PREFIX:-$HOME/.harmonybrew}/opt/ohos-sdk-native" \
        "$(command -v brew >/dev/null && brew --prefix ohos-sdk-native 2>/dev/null || true)"; do
        if [[ -n $cand && -x $cand/llvm/bin/clang && -d $cand/sysroot ]]; then
            OHOS_SDK_NATIVE=$cand
            break
        fi
    done
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
# OpenHarmony's uname answers "OpenHarmony" or "HarmonyOS" for -s, which third
# party configure scripts (OpenSSL, libcap, CMake probes) do not recognise as a
# supported host. Shadow it with a shim that reports Linux and passes every
# other flag through.
case $(uname -s) in
    Linux) ;;
    *)
        mkdir -p -- "$ohos_shim_parent"
        ohos_shim_dir=$(cd -- "$ohos_shim_parent" && pwd)
        if [[ ! -x $ohos_shim_dir/uname ]]; then
            real_uname=$(PATH=/system/bin:/usr/bin:/bin command -v uname || true)
            if [[ -n $real_uname ]]; then
                cat > "$ohos_shim_dir/uname" <<EOF
#!/system/bin/sh
case "\$1" in
    -s|'') echo Linux; exit 0 ;;
    -a|-sr|-rs|-srm)
        out=\$("$real_uname" "\$@") || exit \$?
        echo "Linux \${out#* }"
        exit 0
        ;;
esac
exec "$real_uname" "\$@"
EOF
                chmod +x -- "$ohos_shim_dir/uname"
            fi
        fi
        export PATH="$ohos_shim_dir:$PATH"
        ;;
esac
unset ohos_shim_parent ohos_shim_dir real_uname tool cand
