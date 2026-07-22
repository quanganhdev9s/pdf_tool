import Flutter
import Foundation
import PDFKit
import UIKit

final class PdfPocRuntime {
  static let shared = PdfPocRuntime()

  private var workspaceView: PdfWorkspaceView?
  private var flutterApi: PdfPocFlutterApi?
  private var pendingPageReorder: [Int64]?

  private init() {}

  func configure(binaryMessenger: FlutterBinaryMessenger) {
    logPdfEvent("runtime_configure")
    flutterApi = PdfPocFlutterApi(binaryMessenger: binaryMessenger)
    PdfPocHostApiSetup.setUp(
      binaryMessenger: binaryMessenger,
      api: PdfPocHostApiImpl(runtime: self)
    )
  }

  func attach(workspaceView: PdfWorkspaceView) {
    logPdfEvent("runtime_attach_workspace")
    self.workspaceView = workspaceView
    workspaceView.delegate = self
  }

  func detach(workspaceView: PdfWorkspaceView) {
    if self.workspaceView === workspaceView {
      logPdfEvent("runtime_detach_workspace")
      workspaceView.close()
      self.workspaceView = nil
    }
  }

  func requireWorkspace() throws -> PdfWorkspaceView {
    guard let workspaceView else {
      throw PdfPocError(
        code: "document_not_open",
        message: "The native PDF workspace is not available.",
        details: nil
      )
    }
    return workspaceView
  }

  func setPendingPageReorder(_ pageOrder: [Int64]) {
    pendingPageReorder = pageOrder
    logPdfEvent("runtime_pending_page_reorder_changed", "order=\(pageOrder)")
  }

  func clearPendingPageReorder() {
    pendingPageReorder = nil
    logPdfEvent("runtime_pending_page_reorder_cleared")
  }

  func commitPendingPageReorder() throws {
    guard let pendingPageReorder else {
      throw PdfPocError(
        code: "invalid_page_operation",
        message: "Reorder pages before applying the new order.",
        details: nil
      )
    }
    try requireWorkspace().applyPageOrder(pendingPageReorder)
    clearPendingPageReorder()
  }
}

extension PdfPocRuntime: PdfWorkspaceViewDelegate {
  func workspaceView(_ view: PdfWorkspaceView, didOpen info: PdfDocumentInfo) {
    logPdfEvent("callback_to_flutter_document_opened", "pages=\(info.pageCount)")
    flutterApi?.onDocumentOpened(info: info) { _ in }
  }

  func workspaceViewDidClose(_ view: PdfWorkspaceView) {
    logPdfEvent("callback_to_flutter_document_closed")
    flutterApi?.onDocumentClosed { _ in }
  }

  func workspaceView(_ view: PdfWorkspaceView, didChangePage pageIndex: Int64, pageCount: Int64) {
    logPdfEvent(
      "callback_to_flutter_page_changed",
      "pageIndex=\(pageIndex) pageCount=\(pageCount)"
    )
    flutterApi?.onCurrentPageChanged(pageIndex: pageIndex, pageCount: pageCount) { _ in }
  }

  func workspaceView(_ view: PdfWorkspaceView, didChangeDirtyState isDirty: Bool) {
    logPdfEvent("callback_to_flutter_dirty_changed", "isDirty=\(isDirty)")
    flutterApi?.onDirtyStateChanged(isDirty: isDirty) { _ in }
  }

  func workspaceView(_ view: PdfWorkspaceView, didChangeSearchState state: PdfSearchState) {
    logPdfEvent(
      "callback_to_flutter_search_state",
      "query=\(state.query) total=\(state.totalResults) active=\(state.activeResultIndex)"
    )
    flutterApi?.onSearchStateChanged(state: state) { _ in }
  }

  func workspaceView(_ view: PdfWorkspaceView, didChangeSelection selectedText: String?) {
    logPdfEvent("callback_to_flutter_selection", "length=\(selectedText?.count ?? 0)")
    flutterApi?.onSelectionChanged(selectedText: selectedText) { _ in }
  }

  func workspaceView(_ view: PdfWorkspaceView, didSelectFreeTextArea selection: PdfFreeTextAreaSelection) {
    logPdfEvent(
      "callback_to_flutter_free_text_area",
      "pageIndex=\(selection.pageIndex) bounds=\(selection.bounds)"
    )
    flutterApi?.onFreeTextAreaSelected(selection: selection) { _ in }
  }

  func workspaceView(
    _ view: PdfWorkspaceView,
    didUpdateOcrProgress operationId: String,
    completedPages: Int64,
    totalPages: Int64
  ) {
    logPdfEvent(
      "callback_to_flutter_ocr_progress",
      "operationId=\(operationId) completed=\(completedPages) total=\(totalPages)"
    )
    flutterApi?.onOcrProgress(
      operationId: operationId,
      completedPages: completedPages,
      totalPages: totalPages
    ) { _ in }
  }

  func workspaceView(_ view: PdfWorkspaceView, didFindOcrResult operationId: String, block: PdfOcrBlock) {
    logPdfEvent(
      "callback_to_flutter_ocr_result",
      "operationId=\(operationId) pageIndex=\(block.pageIndex) confidence=\(block.confidence)"
    )
    flutterApi?.onOcrResult(operationId: operationId, block: block) { _ in }
  }

  func workspaceView(_ view: PdfWorkspaceView, didCompleteOcr operationId: String, cancelled: Bool) {
    logPdfEvent(
      "callback_to_flutter_ocr_completed",
      "operationId=\(operationId) cancelled=\(cancelled)"
    )
    flutterApi?.onOcrCompleted(operationId: operationId, cancelled: cancelled) { _ in }
  }

  func workspaceView(
    _ view: PdfWorkspaceView,
    didUpdateCompressionProgress operationId: String,
    completedPages: Int64,
    totalPages: Int64
  ) {
    logPdfEvent(
      "callback_to_flutter_compression_progress",
      "operationId=\(operationId) completed=\(completedPages) total=\(totalPages)"
    )
    flutterApi?.onCompressionProgress(
      operationId: operationId,
      completedPages: completedPages,
      totalPages: totalPages
    ) { _ in }
  }

  func workspaceView(
    _ view: PdfWorkspaceView,
    didCompleteCompression operationId: String,
    result: PdfCompressionResult?,
    cancelled: Bool
  ) {
    logPdfEvent(
      "callback_to_flutter_compression_completed",
      "operationId=\(operationId) cancelled=\(cancelled) output=\(result?.outputPath ?? "")"
    )
    flutterApi?.onCompressionCompleted(
      operationId: operationId,
      result: result,
      cancelled: cancelled
    ) { _ in }
  }

  func workspaceView(
    _ view: PdfWorkspaceView,
    didUpdateSplitProgress operationId: String,
    completedPages: Int64,
    totalPages: Int64
  ) {
    logPdfEvent(
      "callback_to_flutter_split_progress",
      "operationId=\(operationId) completed=\(completedPages) total=\(totalPages)"
    )
    flutterApi?.onSplitProgress(
      operationId: operationId,
      completedPages: completedPages,
      totalPages: totalPages
    ) { _ in }
  }

  func workspaceView(
    _ view: PdfWorkspaceView,
    didCompleteSplit operationId: String,
    result: PdfSplitResult?,
    cancelled: Bool
  ) {
    logPdfEvent(
      "callback_to_flutter_split_completed",
      "operationId=\(operationId) cancelled=\(cancelled) outputs=\(result?.outputs.count ?? 0)"
    )
    flutterApi?.onSplitCompleted(
      operationId: operationId,
      result: result,
      cancelled: cancelled
    ) { _ in }
  }

  func workspaceView(
    _ view: PdfWorkspaceView,
    didUpdateMergeProgress operationId: String,
    completedPages: Int64,
    totalPages: Int64
  ) {
    logPdfEvent(
      "callback_to_flutter_merge_progress",
      "operationId=\(operationId) completed=\(completedPages) total=\(totalPages)"
    )
    flutterApi?.onMergeProgress(
      operationId: operationId,
      completedPages: completedPages,
      totalPages: totalPages
    ) { _ in }
  }

  func workspaceView(
    _ view: PdfWorkspaceView,
    didCompleteMerge operationId: String,
    result: PdfMergeResult?,
    cancelled: Bool
  ) {
    logPdfEvent(
      "callback_to_flutter_merge_completed",
      "operationId=\(operationId) cancelled=\(cancelled) output=\(result?.outputPath ?? "")"
    )
    flutterApi?.onMergeCompleted(
      operationId: operationId,
      result: result,
      cancelled: cancelled
    ) { _ in }
  }

  func workspaceView(
    _ view: PdfWorkspaceView,
    didUpdateDocumentScanProgress operationId: String,
    completedPages: Int64,
    totalPages: Int64
  ) {
    logPdfEvent(
      "callback_to_flutter_document_scan_progress",
      "operationId=\(operationId) completed=\(completedPages) total=\(totalPages)"
    )
    flutterApi?.onDocumentScanProgress(
      operationId: operationId,
      completedPages: completedPages,
      totalPages: totalPages
    ) { _ in }
  }

  func workspaceView(
    _ view: PdfWorkspaceView,
    didCompleteDocumentScan operationId: String,
    result: PdfDocumentScanResult?,
    cancelled: Bool
  ) {
    logPdfEvent(
      "callback_to_flutter_document_scan_completed",
      "operationId=\(operationId) cancelled=\(cancelled) output=\(result?.outputPath ?? "")"
    )
    flutterApi?.onDocumentScanCompleted(
      operationId: operationId,
      result: result,
      cancelled: cancelled
    ) { _ in }
  }

  func workspaceView(
    _ view: PdfWorkspaceView,
    didFailOperation operationId: String,
    error: PdfPocError
  ) {
    logPdfEvent(
      "callback_to_flutter_operation_failed",
      "operationId=\(operationId) code=\(error.code) message=\(error.message)"
    )
    flutterApi?.onOperationFailed(
      operationId: operationId,
      code: error.code,
      message: error.message,
      details: error.details
    ) { _ in }
  }
}

struct PdfPocError: Error {
  let code: String
  let message: String
  let details: String?

  var pigeonError: PigeonError {
    PigeonError(code: code, message: message, details: details)
  }
}

extension PdfPocError {
  static func documentNotOpen() -> PdfPocError {
    PdfPocError(
      code: "document_not_open",
      message: "Open a document before running this operation.",
      details: nil
    )
  }

  static func pageOutOfRange(_ pageIndex: Int64) -> PdfPocError {
    PdfPocError(
      code: "page_out_of_range",
      message: "The requested page index is outside the open document.",
      details: "pageIndex=\(pageIndex)"
    )
  }
}

extension PdfPocError {
  func asPigeonError() -> PigeonError {
    pigeonError
  }
}
