#!/usr/bin/env python3
"""Writes the fixture filter_test.cpp runs against.

Hand-built rather than produced by a real generator, because the point of the
fixture is to contain what generators do not emit. CoreGraphics and every
library like it show text with `Tj` and `TJ`; `'` and `"` are legal, common in
documents produced by older tools, and the only two text-showing operators that
also move the text line matrix. They are exactly the cases the filter cannot
handle by deletion, so a fixture without them tests the easy half.

The strings are tagged KEEP or GONE so a test can grep the uncompressed result
and see whether the right ones survived.
"""

import sys

CONTENT = b"""BT
/F1 18 Tf
20 TL
50 700 Td
(ALPHA-KEEP) Tj
0 -30 Td
(BRAVO-GONE) Tj
0 -30 Td
(CHARLIE-KEEP) '
(DELTA-GONE) '
1 2 (ECHO-GONE) "
(FOXTROT-KEEP) Tj
ET
"""

# ordinals:  0 ALPHA(Tj) 1 BRAVO(Tj) 2 CHARLIE(') 3 DELTA(') 4 ECHO(") 5 FOXTROT(Tj)


def build() -> bytes:
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
        b"/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
        b"<< /Length " + str(len(CONTENT)).encode() + b" >>\nstream\n" + CONTENT + b"endstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]

    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for i, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % i
        out += body
        out += b"\nendobj\n"

    xref_at = len(out)
    out += b"xref\n0 %d\n" % (len(objects) + 1)
    out += b"0000000000 65535 f \n"
    for off in offsets:
        out += b"%010d 00000 n \n" % off
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\n" % (len(objects) + 1)
    out += b"startxref\n%d\n%%%%EOF\n" % xref_at
    return bytes(out)


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else "test.pdf"
    with open(path, "wb") as handle:
        handle.write(build())
    print(f"wrote {path}")
