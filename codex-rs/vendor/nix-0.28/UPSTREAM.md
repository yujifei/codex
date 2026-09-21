# nix 0.28 OpenHarmony compatibility patch

- Upstream crate: `nix` `0.28.0`, downloaded from crates.io.
- Registry archive SHA-256, as recorded in the original `codex-rs/Cargo.lock`:
  `ab2156c4fce2f8df6c499cc1c763e4394b7482525bf2a9701c9d79d215f519e4`.
- Upstream repository: https://github.com/nix-rust/nix.
- Original source and license files are preserved. Cargo cache markers
  `.cargo-ok` and `.cargo-checksum.json` are omitted.

`rustyline` 14 depends on nix 0.28 and uses `ioctl_read_bad!` for terminal sizing.
OpenHarmony libc takes a `c_int` ioctl request, but upstream nix selects `c_ulong`
because `target_env = "ohos"` is missing from its musl/Android condition. On ARM64
this makes the macro pass `u64` to an `i32` argument and fails to compile.

The only source patch adds `target_env = "ohos"` to the two complementary
`ioctl_num_type` conditions in `src/sys/ioctl/linux.rs`. OpenHarmony now uses the
existing musl `c_int` implementation. Other targets, request encodings, and the
libc call type checks remain unchanged. No rustyline patch is needed.

This patch covers the ioctl ABI needed by rustyline; it does not claim support
for all optional nix 0.28 features.
