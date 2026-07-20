import 'dart:io';

import 'package:flutter/material.dart';

class NativePdfWorkspace extends StatelessWidget {
  const NativePdfWorkspace({super.key});

  @override
  Widget build(BuildContext context) {
    if (!Platform.isIOS) {
      return const Center(child: Text('This technical POC supports iOS only.'));
    }
    return const UiKitView(viewType: 'pdf_poc_view');
  }
}
