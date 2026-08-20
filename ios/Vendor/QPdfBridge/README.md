# QPdfBridge

qpdf, wrapped so that page text can be **deleted** rather than covered.

## Why this exists

PDFKit can add annotations. It cannot rewrite the operators a page is drawn
from — there is no public API on iOS for that. So `PdfTextEditManager` replaces
text by laying a paper-coloured rectangle over it and drawing the replacement on
top. The page looks right, but the original words are still in the content
stream underneath: search finds them, copy yields them, and any tool that reads
a PDF properly extracts them. Fine for an edit; a data leak for anyone who used
"edit text" to take a number out of a document before sending it on.

`PdfContentTextEraser` (Swift, in `Runner/PdfPoc/`) is the other half. It runs
after PDFKit has saved, hands qpdf a list of operators to drop, and the words
leave the file.

## Layout

```
QPdfBridge.podspec                     local pod, wired from ios/Podfile
qpdf.xcframework/                      prebuilt static qpdf + libjpeg-turbo
Sources/QPdfBridge/
  include/QPdfTextEraser.h             the Objective-C surface Swift imports
  QPdfShowTextFilters.hpp              the filters — plain C++, so they can be tested
  QPdfTextEraser.mm                    QPDF/QPDFWriter plumbing
tools/
  build_qpdf.sh                        rebuilds the xcframework from source
  filter_test.cpp                      host-side exercise of the filters
  make_test_pdf.py                     the fixture it runs against
  run_tests.sh                         builds and runs the above, with assertions
LICENSE-qpdf.txt  NOTICE-qpdf.md  LICENSE-libjpeg-turbo.md
```

The xcframework is checked in on purpose. Building it takes several minutes and
needs CMake, and neither belongs in the path of a normal `flutter run`.

## How deletion is addressed

A page's content stream shows text with `Tj`, `TJ`, `'` and `"`. Each is
identified by its **ordinal** among the text-showing operators on that page,
counting from zero in draw order — invisible ones included, because a scanned
page's OCR layer is drawn in render mode 3 and skipping it would shift every
ordinal after it.

Two parsers assign those ordinals: `CGPDFScanner` on the Swift side
(`PdfContentStreamReader.showTextOps(on:)`) and qpdf's tokenizer here. They agree
because both walk only the page's own content streams, in order, and count the
same four operators. That agreement is an assumption, so
`showTextOperatorCountAtURL:page:error:` exists to check it, and
`PdfContentTextEraser` calls it before every erase. A mismatch aborts rather
than deleting arbitrary text.

## Why some deletions are refused

Showing text advances the text matrix `Tm`, but never the text *line* matrix
`Tlm` — and `Td`, `TD`, `Tm`, `T*`, `'` and `"` all compute their position from
`Tlm`. So dropping an operator can only disturb operators that draw after it
**within the same segment**, where a segment is a run between two moves of the
line matrix. Once the line matrix moves again, the page has forgotten where the
deleted words left off.

`PdfContentStreamReader.deletionPlan(for:on:)` therefore only returns a plan when,
in every segment it touches, the doomed operators run to the end of that segment.
Selecting a whole paragraph normally satisfies this, because the line below
begins with a `Td` or a `T*`. When it does not, the plan is refused and the
caller keeps its covering rectangle.

`'` and `"` are the exception: they begin a new line as well as draw. Deleting
them outright would slide every line below up the page, so they are replaced by
the positioning they performed — `'` becomes `T*`, and `aw ac (s) "` becomes
`aw Tw ac Tc T*`.

## Rebuilding qpdf

```sh
tools/build_qpdf.sh          # writes out/qpdf.xcframework
```

Two things about that build are not optional:

- **`-DUSE_IMPLICIT_CRYPTO=OFF -DREQUIRE_CRYPTO_NATIVE=ON`.** Left to itself,
  qpdf picks GnuTLS when it can find it. GnuTLS is LGPL, and statically linking
  LGPL into an App Store binary is not something the licence permits, because
  nobody downstream can relink it. The native provider is qpdf's own, ships
  inside qpdf, and needs no external library at all. Verify after any rebuild:

  ```sh
  ar t out/ios-arm64/lib/libqpdf-combined.a | grep -i crypto
  # QPDFCrypto_native.cc.o and nothing else
  ```

- **one architecture per CMake run.** libjpeg-turbo refuses multiple values in
  `CMAKE_OSX_ARCHITECTURES` because it ships assembly; the slices are `lipo`'d
  afterwards.

## Testing the filters

```sh
tools/run_tests.sh <qpdf-build-dir>
```

The fixture is written by hand rather than generated, because generators emit
`Tj` and `TJ` and nothing else. `'` and `"` are the two operators that cannot be
handled by deletion, so a fixture without them tests the easy half.

## Licences

Everything here is permissive; nothing is copyleft.

| | |
|---|---|
| qpdf 12.4.0 | Apache-2.0 |
| libjpeg-turbo 3.2.0 | IJG + BSD-3-Clause |
| zlib | from the iOS SDK, zlib licence |

Apache-2.0 §4(d) makes `NOTICE-qpdf.md` **mandatory** to reproduce, not optional.
All three files in this directory need to reach an acknowledgements screen in the
app before it ships.
