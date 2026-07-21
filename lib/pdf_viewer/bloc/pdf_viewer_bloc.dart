import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../pdf_poc_api.g.dart';
import '../data/pdf_assets.dart';
import '../data/pdf_event_log.dart';
import 'pdf_viewer_event.dart';
import 'pdf_viewer_state.dart';

export 'pdf_viewer_event.dart';
export 'pdf_viewer_state.dart';

class PdfViewerBloc extends Bloc<PdfViewerEvent, PdfViewerState>
    implements PdfPocFlutterApi {
  PdfViewerBloc({required this.assetKey}) : super(PdfViewerState()) {
    logPdfEvent('viewer_bloc_init', <String, Object?>{'asset': assetKey});
    PdfPocFlutterApi.setUp(this);

    on<PdfViewerOpenRequested>(_onOpenRequested);
    on<PdfViewerResetRequested>(_onResetRequested);
    on<PdfViewerPreviousPageRequested>(_onPreviousPageRequested);
    on<PdfViewerNextPageRequested>(_onNextPageRequested);
    on<PdfViewerJumpToPageRequested>(_onJumpToPageRequested);
    on<PdfViewerSearchRequested>(_onSearchRequested);
    on<PdfViewerPreviousSearchResultRequested>(
      _onPreviousSearchResultRequested,
    );
    on<PdfViewerNextSearchResultRequested>(_onNextSearchResultRequested);
    on<PdfViewerClearSearchRequested>(_onClearSearchRequested);
    on<PdfViewerCopySelectionRequested>(_onCopySelectionRequested);
    on<PdfViewerMarkupSelectionRequested>(_onMarkupSelectionRequested);
    on<PdfViewerAddFixedFreeTextRequested>(_onAddFixedFreeTextRequested);
    on<PdfViewerBeginFreeTextAreaSelectionRequested>(
      _onBeginFreeTextAreaSelectionRequested,
    );
    on<PdfViewerCommitSelectedFreeTextAreaRequested>(
      _onCommitSelectedFreeTextAreaRequested,
    );
    on<PdfViewerCancelSelectedFreeTextAreaRequested>(
      _onCancelSelectedFreeTextAreaRequested,
    );
    on<PdfViewerSaveRequested>(_onSaveRequested);
    on<PdfViewerInkModeChanged>(_onInkModeChanged);
    on<PdfViewerClearInkRequested>(_onClearInkRequested);
    on<PdfViewerCommitInkRequested>(_onCommitInkRequested);
    on<PdfViewerDeleteSelectedAnnotationRequested>(
      _onDeleteSelectedAnnotationRequested,
    );
    on<PdfViewerCaptureSignatureRequested>(_onCaptureSignatureRequested);
    on<PdfViewerClearSignatureCaptureRequested>(
      _onClearSignatureCaptureRequested,
    );
    on<PdfViewerConfirmSignatureCaptureRequested>(
      _onConfirmSignatureCaptureRequested,
    );
    on<PdfViewerBeginSignaturePlacementRequested>(
      _onBeginSignaturePlacementRequested,
    );
    on<PdfViewerResizeSignaturePlacementRequested>(
      _onResizeSignaturePlacementRequested,
    );
    on<PdfViewerCommitSignaturePlacementRequested>(
      _onCommitSignaturePlacementRequested,
    );
    on<PdfViewerCancelSignaturePlacementRequested>(
      _onCancelSignaturePlacementRequested,
    );
    on<PdfViewerDeleteSelectedSignatureRequested>(
      _onDeleteSelectedSignatureRequested,
    );
    on<PdfViewerExportFlattenedCopyRequested>(_onExportFlattenedCopyRequested);
    on<PdfViewerRotateCurrentPageRequested>(_onRotateCurrentPageRequested);
    on<PdfViewerDeleteCurrentPageRequested>(_onDeleteCurrentPageRequested);
    on<PdfViewerDuplicateCurrentPageRequested>(
      _onDuplicateCurrentPageRequested,
    );
    on<PdfViewerMoveCurrentPageRequested>(_onMoveCurrentPageRequested);
    on<PdfViewerCommitPendingPageReorderRequested>(
      _onCommitPendingPageReorderRequested,
    );
    on<PdfViewerCancelPendingPageReorderRequested>(
      _onCancelPendingPageReorderRequested,
    );
    on<PdfViewerCropCurrentPageRequested>(_onCropCurrentPageRequested);
    on<PdfViewerSavePageOperationsCopyRequested>(
      _onSavePageOperationsCopyRequested,
    );
    on<PdfViewerRunOcrCurrentPageRequested>(_onRunOcrCurrentPageRequested);
    on<PdfViewerRunOcrAllPagesRequested>(_onRunOcrAllPagesRequested);
    on<PdfViewerCancelOcrRequested>(_onCancelOcrRequested);
    on<PdfViewerShowOcrResultRequested>(_onShowOcrResultRequested);
    on<PdfViewerNativePageChanged>(_onNativePageChanged);
    on<PdfViewerNativeDirtyStateChanged>(_onNativeDirtyStateChanged);
    on<PdfViewerNativeDocumentClosed>(_onNativeDocumentClosed);
    on<PdfViewerNativeDocumentOpened>(_onNativeDocumentOpened);
    on<PdfViewerNativeOperationFailed>(_onNativeOperationFailed);
    on<PdfViewerNativeSearchStateChanged>(_onNativeSearchStateChanged);
    on<PdfViewerNativeSelectionChanged>(_onNativeSelectionChanged);
    on<PdfViewerNativeFreeTextAreaSelected>(_onNativeFreeTextAreaSelected);
    on<PdfViewerNativeOcrProgress>(_onNativeOcrProgress);
    on<PdfViewerNativeOcrResult>(_onNativeOcrResult);
    on<PdfViewerNativeOcrCompleted>(_onNativeOcrCompleted);
  }

  final String assetKey;
  final PdfPocHostApi _api = PdfPocHostApi();

  Future<void> _onOpenRequested(
    PdfViewerOpenRequested event,
    Emitter<PdfViewerState> emit,
  ) async {
    if (!Platform.isIOS) {
      logPdfEvent('open_skip_non_ios');
      return;
    }
    await _run(emit, 'open', () => _openAsset(emit));
  }

  Future<void> _onResetRequested(
    PdfViewerResetRequested event,
    Emitter<PdfViewerState> emit,
  ) async {
    await _run(emit, 'reset', () async {
      final bytes = await _loadAssetBytes(assetKey);
      logPdfEvent('reset_asset_bytes_loaded', <String, Object?>{
        'asset': assetKey,
        'bytes': bytes.length,
      });
      final info = await _api.resetWorkingCopy(assetKey, bytes);
      _applyDocumentInfo(emit, info);
      emit(
        state.copyWith(
          searchState: null,
          selectedText: null,
          pendingFreeTextArea: null,
          ocrRunning: false,
          ocrCompletedPages: 0,
          ocrTotalPages: 0,
          ocrResults: <PdfOcrBlock>[],
          status: 'Reset writable copy for ${assetName(assetKey)}.',
        ),
      );
    });
  }

  Future<void> _onPreviousPageRequested(
    PdfViewerPreviousPageRequested event,
    Emitter<PdfViewerState> emit,
  ) async {
    await _run(emit, 'previous page', _api.goToPreviousPage);
  }

  Future<void> _onNextPageRequested(
    PdfViewerNextPageRequested event,
    Emitter<PdfViewerState> emit,
  ) async {
    await _run(emit, 'next page', _api.goToNextPage);
  }

  Future<void> _onJumpToPageRequested(
    PdfViewerJumpToPageRequested event,
    Emitter<PdfViewerState> emit,
  ) async {
    final pageIndex = int.tryParse(event.pageText.trim());
    if (pageIndex == null) {
      logPdfEvent('jump_invalid_page', <String, Object?>{
        'input': event.pageText,
      });
      emit(state.copyWith(status: 'Enter a zero-based page index.'));
      return;
    }
    await _run(emit, 'jump to page', () => _api.goToPage(pageIndex));
  }

  Future<void> _onSearchRequested(
    PdfViewerSearchRequested event,
    Emitter<PdfViewerState> emit,
  ) async {
    await _run(emit, 'search', () async {
      logPdfEvent('search_request', <String, Object?>{
        'query': event.query.trim(),
      });
      final searchState = await _api.search(
        PdfSearchRequest(
          query: event.query.trim(),
          caseSensitive: false,
          wholeWord: false,
        ),
      );
      emit(state.copyWith(searchState: searchState));
    });
  }

  Future<void> _onPreviousSearchResultRequested(
    PdfViewerPreviousSearchResultRequested event,
    Emitter<PdfViewerState> emit,
  ) async {
    await _run(emit, 'previous search result', () async {
      final searchState = await _api.goToPreviousSearchResult();
      emit(state.copyWith(searchState: searchState));
    });
  }

  Future<void> _onNextSearchResultRequested(
    PdfViewerNextSearchResultRequested event,
    Emitter<PdfViewerState> emit,
  ) async {
    await _run(emit, 'next search result', () async {
      final searchState = await _api.goToNextSearchResult();
      emit(state.copyWith(searchState: searchState));
    });
  }

  Future<void> _onClearSearchRequested(
    PdfViewerClearSearchRequested event,
    Emitter<PdfViewerState> emit,
  ) async {
    await _run(emit, 'clear search', () async {
      await _api.clearSearch();
      emit(state.copyWith(searchState: null));
    });
  }

  Future<void> _onCopySelectionRequested(
    PdfViewerCopySelectionRequested event,
    Emitter<PdfViewerState> emit,
  ) async {
    await _run(emit, 'copy selection', () async {
      await _api.copySelectedText();
      final text = await _api.getSelectedText();
      logPdfEvent('copy_selected_text', <String, Object?>{
        'length': text?.length ?? 0,
      });
      emit(state.copyWith(selectedText: text, status: 'Copied selected text.'));
    });
  }

  Future<void> _onMarkupSelectionRequested(
    PdfViewerMarkupSelectionRequested event,
    Emitter<PdfViewerState> emit,
  ) async {
    await _run(emit, '${event.type.name} selection', () async {
      logPdfEvent('add_selection_markup_request', <String, Object?>{
        'type': event.type.name,
      });
      await _api.addMarkupFromCurrentSelection(event.type);
    });
  }

  Future<void> _onAddFixedFreeTextRequested(
    PdfViewerAddFixedFreeTextRequested event,
    Emitter<PdfViewerState> emit,
  ) async {
    await _run(emit, 'add free text', () async {
      final info = state.documentInfo;
      if (info == null) {
        throw PlatformException(
          code: 'document_not_open',
          message: 'Open a document first.',
        );
      }
      final pageIndex =
          int.tryParse(event.pageText.trim()) ?? info.currentPageIndex;
      logPdfEvent('add_free_text_fixed_request', <String, Object?>{
        'pageIndex': pageIndex,
        'textLength': event.text.trim().length,
      });
      await _api.addFreeText(
        PdfFreeTextRequest(
          pageIndex: pageIndex,
          text: event.text,
          bounds: PdfRect(x: 72, y: 72, width: 240, height: 64),
          fontSize: 16,
          textColor: PdfColor(argb: 0xFF111827),
        ),
      );
    });
  }

  Future<void> _onBeginFreeTextAreaSelectionRequested(
    PdfViewerBeginFreeTextAreaSelectionRequested event,
    Emitter<PdfViewerState> emit,
  ) async {
    emit(
      state.copyWith(
        busy: true,
        status: 'Starting free-text area selection...',
      ),
    );
    try {
      logPdfEvent('begin_free_text_area_selection');
      await _api.beginFreeTextAreaSelection();
      if (isClosed) {
        return;
      }
      // Native only captures a PDF rect. Flutter opens the keyboard composer
      // later when onFreeTextAreaSelected returns through Pigeon.
      emit(
        state.copyWith(
          pendingFreeTextArea: null,
          status: 'Drag an empty area on the PDF, then enter free text.',
        ),
      );
    } on PlatformException catch (error) {
      _showError(
        emit,
        'select free-text area',
        error.code,
        error.message ?? 'Operation failed.',
        error.details?.toString(),
      );
    } finally {
      if (!isClosed) {
        emit(state.copyWith(busy: false));
      }
    }
  }

  Future<void> _onCommitSelectedFreeTextAreaRequested(
    PdfViewerCommitSelectedFreeTextAreaRequested event,
    Emitter<PdfViewerState> emit,
  ) async {
    final selection = state.pendingFreeTextArea;
    final trimmedText = event.text.trim();
    if (selection == null) {
      logPdfEvent('commit_selected_area_missing_selection');
      return;
    }
    if (trimmedText.isEmpty) {
      logPdfEvent('commit_selected_area_empty_text', <String, Object?>{
        'pageIndex': selection.pageIndex,
      });
      emit(state.copyWith(status: 'Enter text for the selected area.'));
      return;
    }

    await _run(emit, 'add selected free text', () async {
      logPdfEvent('add_free_text_selected_area_request', <String, Object?>{
        'pageIndex': selection.pageIndex,
        'textLength': trimmedText.length,
        'x': selection.bounds.x,
        'y': selection.bounds.y,
        'width': selection.bounds.width,
        'height': selection.bounds.height,
      });
      await _api.addFreeText(
        PdfFreeTextRequest(
          pageIndex: selection.pageIndex,
          text: trimmedText,
          bounds: selection.bounds,
          fontSize: 16,
          textColor: PdfColor(argb: 0xFF111827),
        ),
      );
      emit(state.copyWith(pendingFreeTextArea: null));
    });
  }

  void _onCancelSelectedFreeTextAreaRequested(
    PdfViewerCancelSelectedFreeTextAreaRequested event,
    Emitter<PdfViewerState> emit,
  ) {
    logPdfEvent('cancel_selected_free_text_area');
    emit(
      state.copyWith(
        pendingFreeTextArea: null,
        status: 'Cancelled selected free-text area.',
      ),
    );
  }

  Future<void> _onSaveRequested(
    PdfViewerSaveRequested event,
    Emitter<PdfViewerState> emit,
  ) async {
    await _run(emit, 'save', () async {
      logPdfEvent('save_request');
      final info = await _api.save();
      _applyDocumentInfo(emit, info);
    });
  }

  Future<void> _onInkModeChanged(
    PdfViewerInkModeChanged event,
    Emitter<PdfViewerState> emit,
  ) async {
    await _run(
      emit,
      event.enabled ? 'enable ink mode' : 'enable read mode',
      () async {
        logPdfEvent('set_ink_mode_request', <String, Object?>{
          'enabled': event.enabled,
        });
        await _api.setInkModeEnabled(event.enabled);
        emit(
          state.copyWith(
            inkModeEnabled: event.enabled,
            status: event.enabled
                ? 'Ink mode enabled. Draw on the PDF, then commit ink.'
                : 'Read mode enabled.',
          ),
        );
      },
    );
  }

  Future<void> _onClearInkRequested(
    PdfViewerClearInkRequested event,
    Emitter<PdfViewerState> emit,
  ) async {
    await _run(emit, 'clear ink draft', _api.clearCurrentInkInput);
  }

  Future<void> _onCommitInkRequested(
    PdfViewerCommitInkRequested event,
    Emitter<PdfViewerState> emit,
  ) async {
    await _run(emit, 'commit ink', _api.commitCurrentInkToPdf);
  }

  Future<void> _onDeleteSelectedAnnotationRequested(
    PdfViewerDeleteSelectedAnnotationRequested event,
    Emitter<PdfViewerState> emit,
  ) async {
    await _run(
      emit,
      'delete selected annotation',
      _api.deleteSelectedAnnotation,
    );
  }

  Future<void> _onCaptureSignatureRequested(
    PdfViewerCaptureSignatureRequested event,
    Emitter<PdfViewerState> emit,
  ) async {
    await _run(emit, 'capture electronic signature', () async {
      logPdfEvent('capture_electronic_signature_request');
      await _api.captureElectronicSignature();
    });
  }

  Future<void> _onClearSignatureCaptureRequested(
    PdfViewerClearSignatureCaptureRequested event,
    Emitter<PdfViewerState> emit,
  ) async {
    await _run(
      emit,
      'clear electronic signature capture',
      _api.clearElectronicSignatureCapture,
    );
  }

  Future<void> _onConfirmSignatureCaptureRequested(
    PdfViewerConfirmSignatureCaptureRequested event,
    Emitter<PdfViewerState> emit,
  ) async {
    await _run(emit, 'confirm electronic signature', () async {
      await _api.confirmElectronicSignatureCapture();
      emit(
        state.copyWith(
          status:
              'Electronic signature captured. Use Place to position it on the current page.',
        ),
      );
    });
  }

  Future<void> _onBeginSignaturePlacementRequested(
    PdfViewerBeginSignaturePlacementRequested event,
    Emitter<PdfViewerState> emit,
  ) async {
    await _run(emit, 'place electronic signature', () async {
      await _api.beginSignaturePlacement();
      emit(
        state.copyWith(
          status:
              'Move and pinch the electronic signature preview, then commit placement.',
        ),
      );
    });
  }

  Future<void> _onResizeSignaturePlacementRequested(
    PdfViewerResizeSignaturePlacementRequested event,
    Emitter<PdfViewerState> emit,
  ) async {
    await _run(emit, 'resize electronic signature placement', () async {
      await _api.resizeSignaturePlacement(event.scale);
      emit(
        state.copyWith(
          status: event.scale >= 1
              ? 'Electronic signature placement enlarged.'
              : 'Electronic signature placement reduced.',
        ),
      );
    });
  }

  Future<void> _onCommitSignaturePlacementRequested(
    PdfViewerCommitSignaturePlacementRequested event,
    Emitter<PdfViewerState> emit,
  ) async {
    await _run(
      emit,
      'commit electronic signature placement',
      _api.commitSignaturePlacement,
    );
  }

  Future<void> _onCancelSignaturePlacementRequested(
    PdfViewerCancelSignaturePlacementRequested event,
    Emitter<PdfViewerState> emit,
  ) async {
    await _run(
      emit,
      'cancel electronic signature placement',
      _api.cancelSignaturePlacement,
    );
  }

  Future<void> _onDeleteSelectedSignatureRequested(
    PdfViewerDeleteSelectedSignatureRequested event,
    Emitter<PdfViewerState> emit,
  ) async {
    await _run(
      emit,
      'delete selected electronic signature',
      _api.deleteSelectedSignature,
    );
  }

  Future<void> _onExportFlattenedCopyRequested(
    PdfViewerExportFlattenedCopyRequested event,
    Emitter<PdfViewerState> emit,
  ) async {
    await _run(emit, 'export flattened copy', () async {
      final result = await _api.exportFlattenedCopy();
      logPdfEvent('export_flattened_copy_success', <String, Object?>{
        'outputPath': result.outputPath,
        'pageCount': result.pageCount,
        'fileSizeBytes': result.fileSizeBytes,
      });
      emit(
        state.copyWith(
          status:
              'Flattened copy exported: ${result.outputPath} (${result.fileSizeBytes} bytes).',
        ),
      );
    });
  }

  Future<void> _onRotateCurrentPageRequested(
    PdfViewerRotateCurrentPageRequested event,
    Emitter<PdfViewerState> emit,
  ) async {
    final pageIndex = _requireCurrentPageIndex();
    if (pageIndex == null) {
      emit(state.copyWith(status: 'Open a document before rotating pages.'));
      return;
    }
    await _run(emit, 'rotate page', () async {
      logPdfEvent('rotate_page_request', <String, Object?>{
        'pageIndex': pageIndex,
        'degrees': event.degrees,
      });
      await _api.rotatePages(<int>[pageIndex], event.degrees);
    });
  }

  Future<void> _onDeleteCurrentPageRequested(
    PdfViewerDeleteCurrentPageRequested event,
    Emitter<PdfViewerState> emit,
  ) async {
    final info = state.documentInfo;
    if (info == null) {
      emit(state.copyWith(status: 'Open a document before deleting pages.'));
      return;
    }
    if (info.pageCount <= 1) {
      emit(state.copyWith(status: 'Cannot delete the only page in the PDF.'));
      return;
    }
    await _run(emit, 'delete page', () async {
      logPdfEvent('delete_page_request', <String, Object?>{
        'pageIndex': info.currentPageIndex,
      });
      await _api.deletePages(<int>[info.currentPageIndex]);
    });
  }

  Future<void> _onDuplicateCurrentPageRequested(
    PdfViewerDuplicateCurrentPageRequested event,
    Emitter<PdfViewerState> emit,
  ) async {
    final info = state.documentInfo;
    if (info == null) {
      emit(state.copyWith(status: 'Open a document before duplicating pages.'));
      return;
    }
    final destinationIndex = info.currentPageIndex + 1;
    await _run(emit, 'duplicate page', () async {
      logPdfEvent('duplicate_page_request', <String, Object?>{
        'pageIndex': info.currentPageIndex,
        'destinationIndex': destinationIndex,
      });
      await _api.duplicatePage(info.currentPageIndex, destinationIndex);
    });
  }

  Future<void> _onMoveCurrentPageRequested(
    PdfViewerMoveCurrentPageRequested event,
    Emitter<PdfViewerState> emit,
  ) async {
    final info = state.documentInfo;
    if (info == null) {
      emit(state.copyWith(status: 'Open a document before reordering pages.'));
      return;
    }
    final destinationIndex = info.currentPageIndex + event.delta;
    if (destinationIndex < 0 || destinationIndex >= info.pageCount) {
      emit(
        state.copyWith(status: 'Page cannot move farther in that direction.'),
      );
      return;
    }
    await _run(emit, 'move page', () async {
      logPdfEvent('move_page_request', <String, Object?>{
        'fromIndex': info.currentPageIndex,
        'toIndex': destinationIndex,
      });
      await _api.movePage(info.currentPageIndex, destinationIndex);
    });
  }

  Future<void> _onCommitPendingPageReorderRequested(
    PdfViewerCommitPendingPageReorderRequested event,
    Emitter<PdfViewerState> emit,
  ) async {
    await _run(emit, 'apply page reorder', () async {
      logPdfEvent('commit_pending_page_reorder_request');
      await _api.commitPendingPageReorder();
    });
  }

  Future<void> _onCancelPendingPageReorderRequested(
    PdfViewerCancelPendingPageReorderRequested event,
    Emitter<PdfViewerState> emit,
  ) async {
    await _run(emit, 'cancel page reorder', () async {
      logPdfEvent('cancel_pending_page_reorder_request');
      await _api.cancelPendingPageReorder();
    });
  }

  Future<void> _onCropCurrentPageRequested(
    PdfViewerCropCurrentPageRequested event,
    Emitter<PdfViewerState> emit,
  ) async {
    final pageIndex = _requireCurrentPageIndex();
    if (pageIndex == null) {
      emit(state.copyWith(status: 'Open a document before cropping pages.'));
      return;
    }
    await _run(emit, 'crop page', () async {
      const insetPoints = 36.0;
      logPdfEvent('crop_page_to_inset_request', <String, Object?>{
        'pageIndex': pageIndex,
        'insetPoints': insetPoints,
      });
      await _api.cropPageToInset(pageIndex, insetPoints);
    });
  }

  Future<void> _onSavePageOperationsCopyRequested(
    PdfViewerSavePageOperationsCopyRequested event,
    Emitter<PdfViewerState> emit,
  ) async {
    await _run(emit, 'save page-operations copy', () async {
      final result = await _api.savePageOperationsCopy();
      logPdfEvent('save_page_operations_copy_success', <String, Object?>{
        'outputPath': result.outputPath,
        'pageCount': result.pageCount,
        'fileSizeBytes': result.fileSizeBytes,
      });
      emit(
        state.copyWith(
          status:
              'Page-operations copy saved and reopened: ${result.outputPath} (${result.pageCount} pages).',
        ),
      );
    });
  }

  Future<void> _onRunOcrCurrentPageRequested(
    PdfViewerRunOcrCurrentPageRequested event,
    Emitter<PdfViewerState> emit,
  ) async {
    final pageIndex = _requireCurrentPageIndex();
    if (pageIndex == null) {
      emit(state.copyWith(status: 'Open a document before running OCR.'));
      return;
    }
    await _startOcr(emit, <int>[pageIndex], 'current page');
  }

  Future<void> _onRunOcrAllPagesRequested(
    PdfViewerRunOcrAllPagesRequested event,
    Emitter<PdfViewerState> emit,
  ) async {
    final info = state.documentInfo;
    if (info == null) {
      emit(state.copyWith(status: 'Open a document before running OCR.'));
      return;
    }
    await _startOcr(
      emit,
      List<int>.generate(info.pageCount, (index) => index),
      'all pages',
    );
  }

  Future<void> _onCancelOcrRequested(
    PdfViewerCancelOcrRequested event,
    Emitter<PdfViewerState> emit,
  ) async {
    try {
      logPdfEvent('ocr_cancel_request');
      await _api.cancelOcr();
      emit(state.copyWith(status: 'Cancelling OCR...'));
    } on PlatformException catch (error) {
      _showError(
        emit,
        'cancel OCR',
        error.code,
        error.message ?? 'Operation failed.',
        error.details?.toString(),
      );
    }
  }

  Future<void> _onShowOcrResultRequested(
    PdfViewerShowOcrResultRequested event,
    Emitter<PdfViewerState> emit,
  ) async {
    await _run(emit, 'show OCR result', () async {
      logPdfEvent('show_ocr_result_request', <String, Object?>{
        'pageIndex': event.block.pageIndex,
        'confidence': event.block.confidence,
      });
      await _api.showOcrResult(event.block);
    });
  }

  void _onNativePageChanged(
    PdfViewerNativePageChanged event,
    Emitter<PdfViewerState> emit,
  ) {
    final current = state.documentInfo;
    emit(
      state.copyWith(
        documentInfo: PdfDocumentInfo(
          workingPath: current?.workingPath ?? '',
          pageCount: event.pageCount,
          currentPageIndex: event.pageIndex,
          hasSearchableText: current?.hasSearchableText ?? false,
          isDirty: current?.isDirty ?? false,
        ),
      ),
    );
  }

  void _onNativeDirtyStateChanged(
    PdfViewerNativeDirtyStateChanged event,
    Emitter<PdfViewerState> emit,
  ) {
    final current = state.documentInfo;
    if (current == null) {
      return;
    }
    emit(
      state.copyWith(
        documentInfo: PdfDocumentInfo(
          workingPath: current.workingPath,
          pageCount: current.pageCount,
          currentPageIndex: current.currentPageIndex,
          hasSearchableText: current.hasSearchableText,
          isDirty: event.isDirty,
        ),
      ),
    );
  }

  void _onNativeDocumentClosed(
    PdfViewerNativeDocumentClosed event,
    Emitter<PdfViewerState> emit,
  ) {
    emit(
      state.copyWith(
        documentInfo: null,
        searchState: null,
        selectedText: null,
        ocrRunning: false,
        ocrCompletedPages: 0,
        ocrTotalPages: 0,
        ocrResults: <PdfOcrBlock>[],
        status: 'Document closed.',
      ),
    );
  }

  void _onNativeDocumentOpened(
    PdfViewerNativeDocumentOpened event,
    Emitter<PdfViewerState> emit,
  ) {
    _applyDocumentInfo(emit, event.info);
    emit(state.copyWith(status: 'Opened writable copy.'));
  }

  void _onNativeOperationFailed(
    PdfViewerNativeOperationFailed event,
    Emitter<PdfViewerState> emit,
  ) {
    emit(state.copyWith(ocrRunning: false));
    _showError(
      emit,
      event.operationId,
      event.code,
      event.message,
      event.details,
    );
  }

  void _onNativeSearchStateChanged(
    PdfViewerNativeSearchStateChanged event,
    Emitter<PdfViewerState> emit,
  ) {
    emit(state.copyWith(searchState: event.searchState));
  }

  void _onNativeSelectionChanged(
    PdfViewerNativeSelectionChanged event,
    Emitter<PdfViewerState> emit,
  ) {
    emit(state.copyWith(selectedText: event.selectedText));
  }

  void _onNativeFreeTextAreaSelected(
    PdfViewerNativeFreeTextAreaSelected event,
    Emitter<PdfViewerState> emit,
  ) {
    emit(
      state.copyWith(
        pendingFreeTextArea: event.selection,
        status: 'Enter free text for the selected PDF area.',
      ),
    );
  }

  void _onNativeOcrProgress(
    PdfViewerNativeOcrProgress event,
    Emitter<PdfViewerState> emit,
  ) {
    emit(
      state.copyWith(
        ocrCompletedPages: event.completedPages,
        ocrTotalPages: event.totalPages,
        status:
            'OCR progress: ${event.completedPages}/${event.totalPages} pages.',
      ),
    );
  }

  void _onNativeOcrResult(
    PdfViewerNativeOcrResult event,
    Emitter<PdfViewerState> emit,
  ) {
    final results = List<PdfOcrBlock>.of(state.ocrResults)..add(event.block);
    emit(
      state.copyWith(
        ocrResults: results,
        status: 'OCR found ${results.length} text blocks.',
      ),
    );
  }

  void _onNativeOcrCompleted(
    PdfViewerNativeOcrCompleted event,
    Emitter<PdfViewerState> emit,
  ) {
    emit(
      state.copyWith(
        ocrRunning: false,
        status: event.cancelled
            ? 'OCR cancelled at ${state.ocrCompletedPages}/${state.ocrTotalPages} pages.'
            : 'OCR completed with ${state.ocrResults.length} text blocks.',
      ),
    );
  }

  Future<void> _openAsset(Emitter<PdfViewerState> emit) async {
    if (state.openedOnce) {
      logPdfEvent('open_skip_already_opened');
      return;
    }
    emit(state.copyWith(openedOnce: true));
    final bytes = await _loadAssetBytes(assetKey);
    logPdfEvent('open_asset_bytes_loaded', <String, Object?>{
      'asset': assetKey,
      'bytes': bytes.length,
    });
    final info = await _api.openAssetWorkingCopy(assetKey, bytes);
    _applyDocumentInfo(emit, info);
    emit(
      state.copyWith(
        searchState: null,
        selectedText: null,
        ocrRunning: false,
        ocrCompletedPages: 0,
        ocrTotalPages: 0,
        ocrResults: <PdfOcrBlock>[],
        status: 'Opened ${assetName(assetKey)} from a writable copy.',
      ),
    );
  }

  Future<Uint8List> _loadAssetBytes(String assetKey) async {
    final data = await rootBundle.load(assetKey);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  Future<void> _startOcr(
    Emitter<PdfViewerState> emit,
    List<int> pageIndexes,
    String label,
  ) async {
    logPdfEvent('ocr_run_request', <String, Object?>{
      'label': label,
      'pages': pageIndexes,
    });
    emit(
      state.copyWith(
        ocrRunning: true,
        ocrCompletedPages: 0,
        ocrTotalPages: pageIndexes.length,
        ocrResults: <PdfOcrBlock>[],
        status: 'Starting OCR for $label...',
      ),
    );
    try {
      await _api.runOcr(
        PdfOcrRequest(
          pageIndexes: pageIndexes,
          recognitionLanguages: const <String>['vi-VN', 'en-US'],
          accurateRecognition: true,
        ),
      );
    } on PlatformException catch (error) {
      emit(state.copyWith(ocrRunning: false));
      _showError(
        emit,
        'OCR $label',
        error.code,
        error.message ?? 'Operation failed.',
        error.details?.toString(),
      );
    }
  }

  Future<void> _run(
    Emitter<PdfViewerState> emit,
    String label,
    Future<void> Function() action,
  ) async {
    // All UI-triggered Pigeon calls go through this wrapper so busy state,
    // status text, errors, and "PDF Event" logs remain consistent.
    logPdfEvent('operation_start', <String, Object?>{'label': label});
    emit(state.copyWith(busy: true, status: 'Running $label...'));
    try {
      await action();
      if (!isClosed) {
        logPdfEvent('operation_success', <String, Object?>{'label': label});
        emit(state.copyWith(status: 'Completed $label.'));
      }
    } on PlatformException catch (error) {
      logPdfEvent('operation_failed', <String, Object?>{
        'label': label,
        'code': error.code,
        'message': error.message,
        'details': error.details,
      });
      _showError(
        emit,
        label,
        error.code,
        error.message ?? 'Operation failed.',
        error.details?.toString(),
      );
    } finally {
      if (!isClosed) {
        emit(state.copyWith(busy: false));
      }
    }
  }

  void _showError(
    Emitter<PdfViewerState> emit,
    String operationId,
    String code,
    String message,
    String? details,
  ) {
    if (isClosed) {
      return;
    }
    logPdfEvent('show_error', <String, Object?>{
      'operationId': operationId,
      'code': code,
      'message': message,
      'details': details,
    });
    emit(
      state.copyWith(
        status:
            '$operationId failed: $code - $message'
            '${details == null ? '' : ' ($details)'}',
      ),
    );
  }

  void _applyDocumentInfo(Emitter<PdfViewerState> emit, PdfDocumentInfo info) {
    logPdfEvent('apply_document_info', <String, Object?>{
      'page': info.currentPageIndex,
      'pageCount': info.pageCount,
      'dirty': info.isDirty,
      'hasSearchableText': info.hasSearchableText,
    });
    emit(state.copyWith(documentInfo: info));
  }

  int? _requireCurrentPageIndex() {
    return state.documentInfo?.currentPageIndex;
  }

  @override
  void onCurrentPageChanged(int pageIndex, int pageCount) {
    logPdfEvent('callback_page_changed', <String, Object?>{
      'pageIndex': pageIndex,
      'pageCount': pageCount,
    });
    if (!isClosed) {
      add(
        PdfViewerNativePageChanged(pageIndex: pageIndex, pageCount: pageCount),
      );
    }
  }

  @override
  void onDirtyStateChanged(bool isDirty) {
    logPdfEvent('callback_dirty_changed', <String, Object?>{
      'isDirty': isDirty,
    });
    if (!isClosed) {
      add(PdfViewerNativeDirtyStateChanged(isDirty));
    }
  }

  @override
  void onDocumentClosed() {
    logPdfEvent('callback_document_closed');
    if (!isClosed) {
      add(const PdfViewerNativeDocumentClosed());
    }
  }

  @override
  void onDocumentOpened(PdfDocumentInfo info) {
    logPdfEvent('callback_document_opened', <String, Object?>{
      'workingPath': info.workingPath,
      'pageCount': info.pageCount,
      'hasSearchableText': info.hasSearchableText,
    });
    if (!isClosed) {
      add(PdfViewerNativeDocumentOpened(info));
    }
  }

  @override
  void onOperationFailed(
    String operationId,
    String code,
    String message,
    String? details,
  ) {
    logPdfEvent('callback_operation_failed', <String, Object?>{
      'operationId': operationId,
      'code': code,
      'message': message,
      'details': details,
    });
    if (!isClosed) {
      add(
        PdfViewerNativeOperationFailed(
          operationId: operationId,
          code: code,
          message: message,
          details: details,
        ),
      );
    }
  }

  @override
  void onSearchStateChanged(PdfSearchState state) {
    logPdfEvent('callback_search_state_changed', <String, Object?>{
      'query': state.query,
      'totalResults': state.totalResults,
      'activeResultIndex': state.activeResultIndex,
    });
    if (!isClosed) {
      add(PdfViewerNativeSearchStateChanged(state));
    }
  }

  @override
  void onSelectionChanged(String? selectedText) {
    logPdfEvent('callback_selection_changed', <String, Object?>{
      'length': selectedText?.trim().length ?? 0,
    });
    if (!isClosed) {
      add(PdfViewerNativeSelectionChanged(selectedText));
    }
  }

  @override
  void onFreeTextAreaSelected(PdfFreeTextAreaSelection selection) {
    logPdfEvent('callback_free_text_area_selected', <String, Object?>{
      'pageIndex': selection.pageIndex,
      'x': selection.bounds.x,
      'y': selection.bounds.y,
      'width': selection.bounds.width,
      'height': selection.bounds.height,
    });
    if (!isClosed) {
      add(PdfViewerNativeFreeTextAreaSelected(selection));
    }
  }

  @override
  void onOcrProgress(String operationId, int completedPages, int totalPages) {
    logPdfEvent('callback_ocr_progress', <String, Object?>{
      'operationId': operationId,
      'completedPages': completedPages,
      'totalPages': totalPages,
    });
    if (!isClosed) {
      add(
        PdfViewerNativeOcrProgress(
          operationId: operationId,
          completedPages: completedPages,
          totalPages: totalPages,
        ),
      );
    }
  }

  @override
  void onOcrResult(String operationId, PdfOcrBlock block) {
    logPdfEvent('callback_ocr_result', <String, Object?>{
      'operationId': operationId,
      'pageIndex': block.pageIndex,
      'confidence': block.confidence,
      'textLength': block.text.trim().length,
    });
    if (!isClosed) {
      add(PdfViewerNativeOcrResult(operationId: operationId, block: block));
    }
  }

  @override
  void onOcrCompleted(String operationId, bool cancelled) {
    logPdfEvent('callback_ocr_completed', <String, Object?>{
      'operationId': operationId,
      'cancelled': cancelled,
    });
    if (!isClosed) {
      add(
        PdfViewerNativeOcrCompleted(
          operationId: operationId,
          cancelled: cancelled,
        ),
      );
    }
  }

  @override
  Future<void> close() async {
    logPdfEvent('viewer_bloc_dispose', <String, Object?>{'asset': assetKey});
    PdfPocFlutterApi.setUp(null);
    try {
      await _api.closeDocument();
    } on PlatformException catch (error) {
      logPdfEvent('close_document_ignored_error', <String, Object?>{
        'code': error.code,
        'message': error.message,
      });
    }
    return super.close();
  }
}
