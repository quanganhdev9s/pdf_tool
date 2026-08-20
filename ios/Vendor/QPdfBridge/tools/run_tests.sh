#!/bin/bash
# Builds and runs the host-side test of the content-stream filters.
#
#   usage: run_tests.sh <path-to-qpdf-build-dir>
#
# The build dir is whatever build_qpdf.sh left behind — the test links against
# the host copy of qpdf, not the iOS one. Nothing here runs during a normal
# `flutter build`; it is meant for anyone about to change QPdfShowTextFilters.hpp.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="${1:-}"
if [ -z "$BUILD" ] || [ ! -d "$BUILD" ]; then
  echo "usage: $0 <qpdf-build-dir>" >&2
  exit 2
fi

QV="$(cat "$BUILD/QPDF_VERSION")"
QLIB="$(find "$BUILD/b-qpdf-host" -name libqpdf.a | head -1)"
CFGDIR="$(dirname "$(find "$BUILD/b-qpdf-host" -name qpdf-config.h | head -1)")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

clang++ -std=c++20 -O1 -Wall \
  -I"$BUILD/src/qpdf-$QV/include" -I"$CFGDIR" \
  "$HERE/filter_test.cpp" "$QLIB" "$BUILD/out/host/lib/libjpeg.a" -lz \
  -o "$WORK/filter_test"

python3 "$HERE/make_test_pdf.py" "$WORK/in.pdf" > /dev/null

# ALPHA(Tj) BRAVO(Tj) CHARLIE(') DELTA(') ECHO(") FOXTROT(Tj)
# Drop 1, 3, 4 — one of each kind of operator that can be dropped.
OUT="$("$WORK/filter_test" "$WORK/in.pdf" "$WORK/out.pdf" 1 3 4)"
echo "$OUT" | grep -qx "count=6"   || fail "expected 6 text operators, got: $OUT"
echo "$OUT" | grep -qx "dropped=3" || fail "expected 3 dropped, got: $OUT"

# The words must be gone from the bytes, not merely covered.
for gone in BRAVO-GONE DELTA-GONE ECHO-GONE; do
  if strings "$WORK/out.pdf" | grep -q "$gone"; then fail "$gone survived in the file"; fi
done
for keep in ALPHA-KEEP CHARLIE-KEEP FOXTROT-KEEP; do
  strings "$WORK/out.pdf" | grep -q "$keep" || fail "$keep was removed"
done

# A replacement must never fuse onto the token before it: `'` followed by `T*`
# with no separator tokenises as one word and stops working silently.
if grep -aq "'T\*" "$WORK/out.pdf"; then fail "replacement fused onto the preceding operator"; fi

# And the result has to still be a PDF qpdf can read. Three operators drawn,
# because the two dropped ' became T*, which draws nothing.
AFTER="$("$WORK/filter_test" "$WORK/out.pdf" "$WORK/again.pdf")"
echo "$AFTER" | grep -qx "count=3" || fail "output did not re-parse to 3 operators: $AFTER"

echo "PASS: 6 operators found, 3 dropped, 3 kept, output re-parses"
