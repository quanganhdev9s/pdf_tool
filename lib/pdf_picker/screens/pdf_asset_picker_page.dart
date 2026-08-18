import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../pdf_viewer/data/pdf_assets.dart';
import '../../pdf_viewer/screens/pdf_viewer_page.dart';
import '../../scan/scan_flow.dart';
import '../../scan/screens/scan_library_page.dart';
import '../cubit/pdf_asset_picker_bloc.dart';

class PdfAssetPickerPage extends StatelessWidget {
  const PdfAssetPickerPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider<PdfAssetPickerCubit>(
      create: (_) => PdfAssetPickerCubit(),
      child: const _PdfAssetPickerView(),
    );
  }
}

class _PdfAssetPickerView extends StatelessWidget {
  const _PdfAssetPickerView();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PdfAssetPickerCubit, PdfAssetPickerState>(
      builder: (context, state) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Chọn PDF'),
            actions: <Widget>[
              IconButton(
                tooltip: 'PDF đã quét',
                icon: const Icon(Icons.folder_open_outlined),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ScanLibraryPage(),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Quét tài liệu',
                icon: const Icon(Icons.document_scanner_outlined),
                onPressed: () => startScanFlow(context, fromPhotoLibrary: false),
              ),
              IconButton(
                tooltip: 'Chọn ảnh',
                icon: const Icon(Icons.photo_library_outlined),
                onPressed: () => startScanFlow(context, fromPhotoLibrary: true),
              ),
            ],
          ),
          body: SafeArea(
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: state.assets.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final assetKey = state.assets[index];
                return Card(
                  margin: EdgeInsets.zero,
                  child: ListTile(
                    leading: const Icon(Icons.picture_as_pdf_outlined),
                    title: Text(assetName(assetKey)),
                    subtitle: Text(assetDescription(assetKey)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      context.read<PdfAssetPickerCubit>().selectAsset(assetKey);
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => PdfViewerPage(assetKey: assetKey),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}
