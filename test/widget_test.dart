import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pdf_tool/hwp/data/hwp_working_document_store.dart';
import 'package:pdf_tool/pdf_picker/cubit/pdf_asset_picker_bloc.dart';
import 'package:pdf_tool/pdf_picker/data/document_asset_store.dart';
import 'package:pdf_tool/pdf_picker/data/imported_pdf_store.dart';
import 'package:pdf_tool/pdf_picker/screens/pdf_asset_picker_page.dart';

void main() {
  testWidgets('POC 0 renders picker and viewer shell', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PdfAssetPickerPage(
          cubit: PdfAssetPickerCubit(
            store: _FakeImportedPdfStore(),
            hwpStore: _FakeHwpWorkingDocumentStore(),
            assetStore: _FakeDocumentAssetStore(),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Chọn tài liệu'), findsOneWidget);
    final Finder samplePdf = find.text('existing_annotations.pdf');
    expect(samplePdf, findsOneWidget);

    await tester.tap(samplePdf);
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

class _FakeDocumentAssetStore extends DocumentAssetStore {
  @override
  Future<List<String>> listPdfAssets() async => const <String>[
    'assets/poc/existing_annotations.pdf',
  ];

  @override
  Future<List<String>> listHwpAssets() async => const <String>[
    'assets/hwp/example.hwp',
  ];
}

class _FakeImportedPdfStore extends ImportedPdfStore {
  @override
  Future<List<ImportedPdf>> list() async => const <ImportedPdf>[];
}

class _FakeHwpWorkingDocumentStore extends HwpWorkingDocumentStore {
  @override
  Future<List<HwpWorkingDocument>> list() async => const <HwpWorkingDocument>[];
}
