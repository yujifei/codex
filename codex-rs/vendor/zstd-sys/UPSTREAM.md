# zstd-sys OpenHarmony compatibility patch

- Upstream crate: `zstd-sys` `2.0.16+zstd.1.5.7`, downloaded from crates.io.
- Registry archive SHA-256, as recorded in the original `codex-rs/Cargo.lock`:
  `91e19ebc2adc8f83e43039e79776e3fda8ca919132d68a1fed6a5faca2683748`.
- Upstream repository: https://github.com/gyscos/zstd-rs.
- Original source and license files are preserved. Cargo cache markers
  `.cargo-ok` and `.cargo-checksum.json` are omitted.

The OpenHarmony SDK used for this port exports `qsort`, but neither declares nor
exports `qsort_r`. Because Clang defines `__linux__` for OpenHarmony, upstream
`cover.c` enables `_GNU_SOURCE` and incorrectly selects the GNU `qsort_r` path.

The only source patch changes four preprocessor conditions in
`zstd/lib/dictBuilder/cover.c` so `__OHOS__` selects the existing C90 `qsort`
fallback. Other GNU feature declarations and other target platforms are
unchanged.

The upstream fallback uses a global sorting context and is not reentrant.
Concurrent dictionary-training calls using this fallback must be serialized.
Ordinary compression and decompression do not use this dictionary-training sort.
