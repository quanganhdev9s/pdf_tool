#!/bin/bash
# Builds libjpeg-turbo + qpdf as static libraries for iOS device and simulator,
# then packages them as a single qpdf.xcframework.
#
# Crypto: native only. The default build would pick GnuTLS (LGPL) if it found
# it, which cannot be statically linked into an App Store binary.
#
# One arch at a time: libjpeg-turbo refuses multiple values in
# CMAKE_OSX_ARCHITECTURES because it ships assembly. Slices are lipo'd after.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/src"
OUT="$ROOT/out"
QV="$(cat "$ROOT/QPDF_VERSION")"
JV="$(cat "$ROOT/JPEG_VERSION")"
MINIOS=15.0

rm -rf "$OUT"
mkdir -p "$OUT"

if [ ! -d "$SRC/qpdf-$QV" ]; then tar -xzf "$SRC/qpdf.tar.gz" -C "$SRC"; fi
if [ ! -d "$SRC/libjpeg-turbo-$JV" ]; then tar -xzf "$SRC/jpeg.tar.gz" -C "$SRC"; fi

# build_arch <tag> <sdk> <arch>
build_arch() {
  local TAG="$1" SDK="$2" ARCH="$3"
  local SDKROOT; SDKROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
  local PREFIX="$OUT/$TAG"

  echo ""
  echo ">>> $TAG   sdk=$SDK arch=$ARCH"

  # ---------- libjpeg-turbo ----------
  echo "    libjpeg-turbo..."
  rm -rf "$ROOT/b-jpeg-$TAG"
  cmake -S "$SRC/libjpeg-turbo-$JV" -B "$ROOT/b-jpeg-$TAG" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_SYSTEM_PROCESSOR="$ARCH" \
    -DCMAKE_OSX_SYSROOT="$SDKROOT" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MINIOS" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DENABLE_SHARED=OFF -DENABLE_STATIC=ON \
    -DWITH_TURBOJPEG=OFF -DWITH_SIMD=OFF \
    > "$ROOT/log-jpeg-$TAG-configure.txt" 2>&1
  cmake --build "$ROOT/b-jpeg-$TAG" --target install --parallel \
    > "$ROOT/log-jpeg-$TAG-build.txt" 2>&1

  # ---------- qpdf ----------
  echo "    qpdf..."
  rm -rf "$ROOT/b-qpdf-$TAG"
  cmake -S "$SRC/qpdf-$QV" -B "$ROOT/b-qpdf-$TAG" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_SYSTEM_PROCESSOR="$ARCH" \
    -DCMAKE_OSX_SYSROOT="$SDKROOT" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MINIOS" \
    -DCMAKE_MACOSX_BUNDLE=OFF \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_STANDARD=20 \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON \
    -DUSE_IMPLICIT_CRYPTO=OFF \
    -DREQUIRE_CRYPTO_NATIVE=ON \
    -DDEFAULT_CRYPTO=native \
    -DBUILD_DOC=OFF -DBUILD_DOC_HTML=OFF -DBUILD_DOC_PDF=OFF \
    -DINSTALL_EXAMPLES=OFF -DINSTALL_MANUAL=OFF \
    -DINSTALL_PKGCONFIG=OFF -DINSTALL_CMAKE_PACKAGE=OFF \
    -DZLIB_LIBRARY="$SDKROOT/usr/lib/libz.tbd" \
    -DZLIB_INCLUDE_DIR="$SDKROOT/usr/include" \
    -DJPEG_LIBRARY="$PREFIX/lib/libjpeg.a" \
    -DJPEG_INCLUDE_DIR="$PREFIX/include" \
    > "$ROOT/log-qpdf-$TAG-configure.txt" 2>&1
  cmake --build "$ROOT/b-qpdf-$TAG" --target libqpdf --parallel \
    > "$ROOT/log-qpdf-$TAG-build.txt" 2>&1

  local QLIB; QLIB="$(find "$ROOT/b-qpdf-$TAG" -name 'libqpdf.a' | head -1)"
  libtool -static -o "$PREFIX/lib/libqpdf-combined.a" \
    "$QLIB" "$PREFIX/lib/libjpeg.a" 2>/dev/null
  echo "    -> $(lipo -archs "$PREFIX/lib/libqpdf-combined.a") $(du -h "$PREFIX/lib/libqpdf-combined.a" | cut -f1)"
}

build_arch "ios-arm64"     "iphoneos"        "arm64"
build_arch "sim-arm64"     "iphonesimulator" "arm64"
build_arch "sim-x86_64"    "iphonesimulator" "x86_64"

# ---- fatten the simulator slice ------------------------------------------
echo ""
echo ">>> lipo simulator slices"
mkdir -p "$OUT/sim/lib"
lipo -create \
  "$OUT/sim-arm64/lib/libqpdf-combined.a" \
  "$OUT/sim-x86_64/lib/libqpdf-combined.a" \
  -output "$OUT/sim/lib/libqpdf-combined.a"
echo "    -> $(lipo -archs "$OUT/sim/lib/libqpdf-combined.a")"

# ---- headers --------------------------------------------------------------
# Same public headers for both slices; qpdf-config.h is generated at configure
# time but its contents are arch-independent for our options.
for SLICE in ios-arm64 sim; do
  rm -rf "$OUT/$SLICE/Headers"
  mkdir -p "$OUT/$SLICE/Headers"
  cp -R "$SRC/qpdf-$QV/include/qpdf" "$OUT/$SLICE/Headers/"
done
CONFIG_H="$(find "$ROOT/b-qpdf-ios-arm64" -name 'qpdf-config.h' | head -1)"
if [ -n "$CONFIG_H" ]; then
  cp "$CONFIG_H" "$OUT/ios-arm64/Headers/qpdf/"
  cp "$CONFIG_H" "$OUT/sim/Headers/qpdf/"
fi

# ---- xcframework ----------------------------------------------------------
echo ""
echo ">>> assembling qpdf.xcframework"
rm -rf "$OUT/qpdf.xcframework"
xcodebuild -create-xcframework \
  -library "$OUT/ios-arm64/lib/libqpdf-combined.a" -headers "$OUT/ios-arm64/Headers" \
  -library "$OUT/sim/lib/libqpdf-combined.a"       -headers "$OUT/sim/Headers" \
  -output "$OUT/qpdf.xcframework" > /dev/null

echo ""
echo ">>> DONE"
find "$OUT/qpdf.xcframework" -maxdepth 1 -mindepth 1
du -sh "$OUT/qpdf.xcframework"
