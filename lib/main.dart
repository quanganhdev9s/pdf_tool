import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'pdf_picker/screens/pdf_asset_picker_page.dart';
import 'scan/bloc/scan_review_bloc.dart';

void main() {
  runApp(const PdfPocApp());
}

class PdfPocApp extends StatelessWidget {
  const PdfPocApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Provided above the navigator: the bloc is the `PdfScanFlutterApi`
    // receiver, so it has to exist before capture starts and survive the push
    // into the review screen.
    return BlocProvider<ScanReviewBloc>(
      create: (_) => ScanReviewBloc(),
      child: MaterialApp(
        title: 'PDF POC 0',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
          useMaterial3: true,
        ),
        home: const PdfAssetPickerPage(),
      ),
    );
  }
}
