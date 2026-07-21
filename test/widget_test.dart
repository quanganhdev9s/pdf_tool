import 'package:flutter_test/flutter_test.dart';

import 'package:pdf_tool/main.dart';

void main() {
  testWidgets('POC 0 renders picker and viewer shell', (tester) async {
    await tester.pumpWidget(const PdfPocApp());

    expect(find.text('Chọn PDF'), findsOneWidget);
    expect(find.text('text_document.pdf'), findsOneWidget);

    await tester.tap(find.text('text_document.pdf'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Search'), findsOneWidget);
    expect(find.byTooltip('Free text'), findsOneWidget);
    expect(find.byTooltip('Electronic signature'), findsOneWidget);
    expect(find.text('Find'), findsNothing);
    expect(find.text('Select area'), findsNothing);
    expect(find.text('Capture'), findsNothing);

    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    expect(find.text('Find'), findsOneWidget);

    await tester.tap(find.byTooltip('Free text'));
    await tester.pumpAndSettle();
    expect(find.text('Select area'), findsOneWidget);

    await tester.tap(find.byTooltip('Electronic signature'));
    await tester.pumpAndSettle();
    expect(find.text('Capture'), findsOneWidget);
    expect(find.byTooltip('Smaller signature'), findsOneWidget);
    expect(find.byTooltip('Larger signature'), findsOneWidget);
    expect(find.text('Export flattened'), findsOneWidget);
    expect(find.text('This technical POC supports iOS only.'), findsOneWidget);
  });
}
