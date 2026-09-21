# nix OpenHarmony compatibility patch

- Upstream crate: `nix` `0.29.0`, downloaded from crates.io.
- Registry archive SHA-256, as recorded in the original `codex-rs/Cargo.lock`:
  `71e2746dc3a24dd78b3cfcb7be93368c6de9963d30f43a6a73998a9cf4b17b46`.
- Upstream repository: https://github.com/nix-rust/nix.
- Original source and license files are preserved. Cargo cache markers
  `.cargo-ok` and `.cargo-checksum.json` are omitted.

OpenHarmony uses `target_os = "linux"` and `target_env = "ohos"`. Its libc
`cmsghdr.cmsg_len` and `CMSG_LEN` use `c_uint`, matching the musl ABI, while
upstream nix selects a `usize` return value for every non-musl Linux environment.
This causes `ControlMessage::encode_into` to fail to compile on ARM64 OpenHarmony.

The socket ABI patch adds `target_env = "ohos"` alongside `target_env = "musl"`
in the two complementary `ControlMessage::cmsg_len` conditions in
`src/sys/socket/mod.rs`. OpenHarmony now uses the existing `c_uint` implementation;
other targets and the actual assignment retain their existing type checks.

The socket module's other control-message lengths and message-vector lengths
already account for target field types. No additional ABI condition changes were
needed there.

`src/sys/ioctl/linux.rs` also selects the existing `c_int` ioctl request type for
OpenHarmony, matching its libc signature and the musl implementation. This fixes
the same ABI mismatch seen through rustyline's nix 0.28 ioctl macro.

Vendoring makes upstream's `deny(unused)` apply to this local dependency on every
target, including ordinary Linux. In `src/sys/socket/sockopt.rs`, `GetU8` and
`SetU8` are only constructed by `IpMulticastTtl`, which requires `net`.
`GetCString` is only constructed by `UtunIfname`, which requires both
`apple_targets` and `net`. The patch allows `dead_code` on each of these three
structs exactly when its caller is disabled. This follows the actual feature and
OS gates rather than restricting the allowances to OpenHarmony. The types and
implementations remain intact; no crate-wide lint suppression is added.

These patches do not claim compatibility for all nix features or other versions.
