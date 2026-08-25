#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE_DIR="$ROOT_DIR/packages/rhwp_bridge"
RUST_DIR="$BRIDGE_DIR/rust"
OUT_DIR="$BRIDGE_DIR/ios/Frameworks"
HEADERS_DIR="$BRIDGE_DIR/ios/include"

mkdir -p "$OUT_DIR"

ensure_target() {
  local target="$1"
  if ! rustc --print target-libdir --target "$target" >/dev/null 2>&1; then
    rustup target add "$target"
  fi
}

ensure_target aarch64-apple-ios
ensure_target aarch64-apple-ios-sim

cargo build --manifest-path "$RUST_DIR/Cargo.toml" --release --target aarch64-apple-ios
cargo build --manifest-path "$RUST_DIR/Cargo.toml" --release --target aarch64-apple-ios-sim

rm -rf "$OUT_DIR/RhwpBridge.xcframework"
xcodebuild -create-xcframework \
  -library "$RUST_DIR/target/aarch64-apple-ios/release/librhwp_bridge.a" \
  -headers "$HEADERS_DIR" \
  -library "$RUST_DIR/target/aarch64-apple-ios-sim/release/librhwp_bridge.a" \
  -headers "$HEADERS_DIR" \
  -output "$OUT_DIR/RhwpBridge.xcframework"
