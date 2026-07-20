import Flutter
import Foundation
import PDFKit
import UIKit

final class PdfPocRuntime {
  static let shared = PdfPocRuntime()

  private var workspaceView: PdfWorkspaceView?
  private var flutterApi: PdfPocFlutterApi?

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
