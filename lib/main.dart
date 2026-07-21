import 'package:flutter/material.dart';

import 'pdf_picker/screens/pdf_asset_picker_page.dart';

void main() {
  runApp(const PdfPocApp());
}

class PdfPocApp extends StatelessWidget {
  const PdfPocApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PDF POC 0',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const PdfAssetPickerPage(),
    );
  }
}
