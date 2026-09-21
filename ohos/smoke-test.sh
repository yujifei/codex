#!/system/bin/sh
# Run on the target device without an account or any network requests.
set -eu
package_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
scratch=$(mktemp -d "${TMPDIR:-/data/local/tmp}/codex-ohos-smoke.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT HUP INT TERM
mkdir "$scratch/home" "$scratch/tmp" "$scratch/project"
export CODEX_HOME="$scratch/home"
export TMPDIR="$scratch/tmp"
cd "$scratch/project"
printf 'readable probe\n' > sandbox-probe
"$package_dir/codex" --version
"$package_dir/codex" --help >/dev/null
if [ -x "$package_dir/codex-resources/bwrap" ]; then
    "$package_dir/codex-resources/bwrap" --version
fi
# A missing namespace/seccomp capability must fail; never downgrade isolation.
"$package_dir/codex" -c 'sandbox_mode="read-only"' sandbox -- /system/bin/sh -c '
    test -r sandbox-probe || exit 10
    if (printf "unexpected write\n" > sandbox-probe) 2>/dev/null; then
        echo "FAIL: read-only sandbox allowed a write" >&2
        exit 11
    fi
    echo "PASS: native startup and sandbox read/write isolation"
'
echo 'TLS/login, PTY/TUI and project editing still require interactive validation.'
