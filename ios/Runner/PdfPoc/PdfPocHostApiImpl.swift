import Flutter
import Foundation

final class PdfPocHostApiImpl: PdfPocHostApi {
  private let runtime: PdfPocRuntime

  init(runtime: PdfPocRuntime) {
    self.runtime = runtime
  }

  func openAssetWorkingCopy(
    assetKey: String,
    assetBytes: FlutterStandardTypedData
  ) throws -> PdfDocumentInfo {
    do {
      return try runtime.requireWorkspace().open(
        assetKey: assetKey,
        assetBytes: assetBytes.data,
        reset: false
      )
    } catch let error as PdfPocError {
      throw error.asPigeonError()
    }
  }

  func closeDocument() throws {
    do {
      try runtime.requireWorkspace().close()
    } catch let error as PdfPocError {
      throw error.asPigeonError()
    }
  }

  func resetWorkingCopy(
    assetKey: String,
    assetBytes: FlutterStandardTypedData
  ) throws -> PdfDocumentInfo {
    do {
      return try runtime.requireWorkspace().open(
        assetKey: assetKey,
        assetBytes: assetBytes.data,
        reset: true
      )
    } catch let error as PdfPocError {
      throw error.asPigeonError()
    }
  }

  func goToPage(pageIndex: Int64) throws {
    try call { try $0.goToPage(pageIndex) }
  }

  func goToNextPage() throws {
    try call { try $0.goToNextPage() }
  }

  func goToPreviousPage() throws {
    try call { try $0.goToPreviousPage() }
  }

  func search(request: PdfSearchRequest) throws -> PdfSearchState {
    try callWithResult { try $0.search(request) }
  }

  func goToNextSearchResult() throws -> PdfSearchState {
    try callWithResult { try $0.goToNextSearchResult() }
  }

  func goToPreviousSearchResult() throws -> PdfSearchState {
    try callWithResult { try $0.goToPreviousSearchResult() }
  }

  func clearSearch() throws {
    try call { try $0.clearSearch() }
  }

  func getSelectedText() throws -> String? {
    try callWithResult { try $0.selectedText() }
  }

  func copySelectedText() throws {
    try call { try $0.copySelectedText() }
  }

  func addMarkupFromCurrentSelection(type: PdfMarkupType) throws {
    try call { try $0.addMarkupFromCurrentSelection(type) }
  }

  func addFreeText(request: PdfFreeTextRequest) throws {
    try call { try $0.addFreeText(request) }
  }

  func beginFreeTextAreaSelection() throws {
    try call { try $0.beginFreeTextAreaSelection() }
  }

  func save() throws -> PdfDocumentInfo {
    try callWithResult { try $0.save() }
  }

  private func call(_ body: (PdfWorkspaceView) throws -> Void) throws {
    do {
      try body(runtime.requireWorkspace())
    } catch let error as PdfPocError {
      throw error.asPigeonError()
    }
  }

  private func callWithResult<T>(_ body: (PdfWorkspaceView) throws -> T) throws -> T {
    do {
      return try body(runtime.requireWorkspace())
    } catch let error as PdfPocError {
      throw error.asPigeonError()
    }
  }
}
