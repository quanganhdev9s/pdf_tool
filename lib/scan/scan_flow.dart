import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'bloc/scan_review_bloc.dart';
import 'screens/scan_review_page.dart';

/// Single entry point into the scan feature.
///
/// Navigation happens immediately rather than waiting for
/// `onScanSessionCreated`: the capture sheet is presented natively on top of
/// whatever is on screen, so pushing first means the review page is already
/// mounted — and its platform view already attached — when the first page
/// lands. `ScanReviewPage` pops itself if the user backs out of capture.
Future<void> startScanFlow(BuildContext context) async {
  final ScanReviewBloc bloc = context.read<ScanReviewBloc>();
  final NavigatorState navigator = Navigator.of(context);

  bloc.add(const ScanCaptureRequested());

  await navigator.push(
    MaterialPageRoute<void>(
      builder: (_) =>
          BlocProvider<ScanReviewBloc>.value(value: bloc, child: const ScanReviewPage()),
    ),
  );
}
