import 'package:flutter_test/flutter_test.dart';

import 'package:pdf_tool/main.dart';

void main() {
  testWidgets('POC 0 renders picker and viewer shell', (tester) async {
    await tester.pumpWidget(const PdfPocApp());

    expect(find.text('Chọn PDF'), findsOneWidget);
    expect(find.text('text_document.pdf'), findsOneWidget);

    await tester.tap(find.text('text_document.pdf'));
    await tester.pumpAndSettle();

    expect(find.text('Find'), findsOneWidget);
    expect(find.text('Select area'), findsOneWidget);
    expect(
      find.text('Select text to show Copy, Highlight, Underline, Strikeout'),
      findsOneWidget,
    );
    expect(find.text('This technical POC supports iOS only.'), findsOneWidget);
  });
}
