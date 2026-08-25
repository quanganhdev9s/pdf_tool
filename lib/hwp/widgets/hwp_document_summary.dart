import 'package:flutter/material.dart';

import '../../hwp_api.g.dart';

class HwpDocumentSummary extends StatelessWidget {
  const HwpDocumentSummary({
    required this.info,
    required this.status,
    super.key,
  });

  final HwpDocumentInfo? info;
  final String status;

  @override
  Widget build(BuildContext context) {
    final HwpDocumentInfo? document = info;
    return ListTile(
      dense: true,
      leading: const Icon(Icons.description_outlined),
      title: Text(document?.fileName ?? 'HWP'),
      subtitle: Text(
        document == null
            ? status
            : '${document.engineVersion} · ${document.pageCount} trang · $status',
      ),
    );
  }
}
