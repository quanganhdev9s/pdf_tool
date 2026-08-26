import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_tool/hwp/services/hwp_document_service.dart';
import 'package:pdf_tool/hwp_api.g.dart';

void main() {
  test(
    'renderPageSvg strips Flutter-unfriendly HWP SVG text attributes',
    () async {
      const String sourceSvg = '''
<svg viewBox="0 0 100 100">
  <clipPath id="cell-clip-58"><rect x="243.1467" y="306.48" width="47.5733" height="15.68"/></clipPath>
  <text x="10" y="20" textLength="6.2700" lengthAdjust="spacingAndGlyphs">1</text>
  <text transform="translate(20,20) scale(0.9500,1)" textLength='8.0' lengthAdjust='spacingAndGlyphs'>√</text>
  <image href="data:image/svg+xml;base64,AAAA"/>
</svg>
''';
      final HwpDocumentService service = HwpDocumentService(
        api: _FakeHwpHostApi(sourceSvg),
      );

      final String sanitized = await service.renderPageSvg(9);

      expect(sanitized, contains('>1</text>'));
      expect(sanitized, contains('>√</text>'));
      expect(sanitized, contains('x="20" y="20"'));
      expect(sanitized, contains('id="cell-clip-58"'));
      expect(sanitized, contains('x="240.1467"'));
      expect(sanitized, contains('y="302.48"'));
      expect(sanitized, contains('width="53.5733"'));
      expect(sanitized, contains('height="23.68"'));
      expect(sanitized, isNot(contains('transform="translate')));
      expect(sanitized, isNot(contains('textLength')));
      expect(sanitized, isNot(contains('lengthAdjust')));
      expect(sanitized, isNot(contains('data:image/svg+xml')));
    },
  );
}

class _FakeHwpHostApi extends HwpHostApi {
  _FakeHwpHostApi(this.svg);

  final String svg;

  @override
  Future<String> renderHwpPageSvg(int pageIndex) async => svg;
}
