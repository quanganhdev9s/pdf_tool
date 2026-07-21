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
    on<PdfViewerNativePageChanged>(_onNativePageChanged);
    on<PdfViewerNativeDirtyStateChanged>(_onNativeDirtyStateChanged);
    on<PdfViewerNativeDocumentClosed>(_onNativeDocumentClosed);
    on<PdfViewerNativeDocumentOpened>(_onNativeDocumentOpened);
    on<PdfViewerNativeOperationFailed>(_onNativeOperationFailed);
    on<PdfViewerNativeSearchStateChanged>(_onNativeSearchStateChanged);
    on<PdfViewerNativeSelectionChanged>(_onNativeSelectionChanged);
    on<PdfViewerNativeFreeTextAreaSelected>(_onNativeFreeTextAreaSelected);
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
        status: 'Opened ${assetName(assetKey)} from a writable copy.',
      ),
    );
  }

  Future<Uint8List> _loadAssetBytes(String assetKey) async {
    final data = await rootBundle.load(assetKey);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
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
