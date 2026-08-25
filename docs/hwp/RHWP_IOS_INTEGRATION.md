# HWP iOS rhwp Integration

The app uses a dedicated HWP Pigeon API and an iOS runtime under
`ios/Runner/Hwp`. The actual HWP parser/editor/exporter is intended to live in
`packages/rhwp_bridge` as a Rust static library wrapped into
`RhwpBridge.xcframework`.

## Source Pinning

`rhwp` is pinned as a Git submodule:

```bash
git -C third_party/rhwp rev-parse HEAD
# 496333b27d21ddb9114ba9ae340bcb895870c9a7
```

The submodule uses sparse checkout for the source needed by the iOS bridge:

```bash
git -C third_party/rhwp sparse-checkout set src bindings/Native mydocs/manual saved
```

The upstream license is MIT. Keep the submodule pinned to an explicit commit
for App Store releases and review upstream changes before advancing it.

## Build

```bash
scripts/build_rhwp_bridge_ios.sh
```

The Rust bridge calls `rhwp_core::wasm_api::HwpDocument` directly and exposes a
narrow C ABI:

- `rhwp_bridge_open_path`
- `rhwp_bridge_extract_text`
- `rhwp_bridge_replace_text`
- `rhwp_bridge_export`
- `rhwp_bridge_close`
- `rhwp_bridge_string_free`

After the real framework exists, add
`packages/rhwp_bridge/ios/Frameworks/RhwpBridge.xcframework` to the Runner
target. `ios/Runner/Hwp/RhwpEngineBridge.swift` resolves the C symbols at
runtime so the app continues to build before the framework is linked. If the
bridge remains a static library, make sure the linker does not dead-strip the
archive; otherwise the `dlsym` lookup will not find the symbols.

The Runner target links the static archive with SDK-specific `-force_load`
flags so the `rhwp_bridge_*` C symbols are exported from the app process for
`dlsym`. The Swift lookup uses the default process scope first because Debug
simulator builds place the symbols in `Runner.debug.dylib`.

## Save Contract

Saving to the same `.hwp` must be atomic:

1. Export HWP bytes from `rhwp`.
2. Reopen those bytes with `rhwp` for basic validation.
3. Write to a temporary file.
4. Replace the source URL only after validation succeeds.

For files picked from iOS Files/iCloud, overwrite support must use open-in-place
and security-scoped URL access. A copied asset or imported copy is not the
user's original file and must not be treated as overwrite-capable.
