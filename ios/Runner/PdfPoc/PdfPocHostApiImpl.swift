import Flutter
import Foundation
import UIKit

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

  func setInkModeEnabled(enabled: Bool) throws {
    try call { try $0.setInkModeEnabled(enabled) }
  }

  func clearCurrentInkInput() throws {
    try call { try $0.clearCurrentInkInput() }
  }

  func commitCurrentInkToPdf() throws {
    try call { try $0.commitCurrentInkToPdf() }
  }

  func deleteSelectedAnnotation() throws {
    try call { try $0.deleteSelectedAnnotation() }
  }

  func captureElectronicSignature() throws {
    try call { try $0.captureElectronicSignature() }
  }

  func clearElectronicSignatureCapture() throws {
    try call { try $0.clearElectronicSignatureCapture() }
  }

  func confirmElectronicSignatureCapture() throws {
    try call { try $0.confirmElectronicSignatureCapture() }
  }

  func beginSignaturePlacement() throws {
    try call { try $0.beginSignaturePlacement() }
  }

  func resizeSignaturePlacement(scale: Double) throws {
    try call { try $0.resizeSignaturePlacement(CGFloat(scale)) }
  }

  func commitSignaturePlacement() throws {
    try call { try $0.commitSignaturePlacement() }
  }

  func cancelSignaturePlacement() throws {
    try call { try $0.cancelSignaturePlacement() }
  }

  func deleteSelectedSignature() throws {
    try call { try $0.deleteSelectedSignature() }
  }

  func exportFlattenedCopy() throws -> PdfExportResult {
    try callWithResult { try $0.exportFlattenedCopy() }
  }

  func rotatePages(pageIndexes: [Int64], degrees: Int64) throws {
    try call { try $0.rotatePages(pageIndexes, degrees: degrees) }
  }

  func deletePages(pageIndexes: [Int64]) throws {
    try call { try $0.deletePages(pageIndexes) }
  }

  func duplicatePage(pageIndex: Int64, destinationIndex: Int64) throws {
    try call { try $0.duplicatePage(pageIndex, destinationIndex: destinationIndex) }
  }

  func movePage(fromIndex: Int64, toIndex: Int64) throws {
    try call { try $0.movePage(from: fromIndex, to: toIndex) }
  }

  func cropPage(pageIndex: Int64, pageBounds: PdfRect) throws {
    try call { try $0.cropPage(pageIndex, bounds: pageBounds) }
  }

  func cropPageToInset(pageIndex: Int64, insetPoints: Double) throws {
    try call { try $0.cropPageToInset(pageIndex, insetPoints: CGFloat(insetPoints)) }
  }

  func commitPendingPageReorder() throws {
    do {
      try runtime.commitPendingPageReorder()
    } catch let error as PdfPocError {
      throw error.asPigeonError()
    }
  }

  func cancelPendingPageReorder() throws {
    runtime.clearPendingPageReorder()
  }

  func savePageOperationsCopy() throws -> PdfExportResult {
    try callWithResult { try $0.savePageOperationsCopy() }
  }

  func runOcr(request: PdfOcrRequest) throws {
    try call { try $0.runOcr(request) }
  }

  func cancelOcr() throws {
    try call { try $0.cancelOcr() }
  }

  func showOcrResult(block: PdfOcrBlock) throws {
    try call { try $0.showOcrResult(block) }
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
