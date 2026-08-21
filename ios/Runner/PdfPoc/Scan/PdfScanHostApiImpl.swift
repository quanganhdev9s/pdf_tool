import Flutter
import Foundation

/// Thin translation layer: converts Pigeon's types into coordinator calls and
/// `PdfPocError` into the error shape Flutter expects. Holds no state.
final class PdfScanHostApiImpl: PdfScanHostApi {
  private unowned let coordinator: PdfScanCoordinator

  init(coordinator: PdfScanCoordinator) {
    self.coordinator = coordinator
  }

  func startDocumentCapture() throws {
    try call { try $0.startDocumentCapture() }
  }

  func getScanPages(sessionId: String) throws -> [PdfScanPageInfo] {
    do {
      return try coordinator.pages(inSession: sessionId)
    } catch let error as PdfPocError {
      throw error.asPigeonError()
    }
  }

  func rotateScanPage(sessionId: String, pageId: String, degrees: Int64) throws {
    try call { try $0.rotatePage(sessionId: sessionId, pageId: pageId, degrees: Int(degrees)) }
  }

  func deleteScanPage(sessionId: String, pageId: String) throws {
    try call { try $0.deletePage(sessionId: sessionId, pageId: pageId) }
  }

  func reorderScanPages(sessionId: String, pageIds: [String]) throws {
    try call { try $0.reorderPages(sessionId: sessionId, pageIds: pageIds) }
  }

  func applyPreset(sessionId: String, pageId: String, preset: PdfScanPreset) throws {
    try call { try $0.applyPreset(sessionId: sessionId, pageId: pageId, preset: preset) }
  }

  func applyPresetToAll(sessionId: String, preset: PdfScanPreset) throws {
    try call { try $0.applyPresetToAll(sessionId: sessionId, preset: preset) }
  }

  func setComparingOriginal(sessionId: String, comparing: Bool) throws {
    try call { try $0.setComparingOriginal(sessionId: sessionId, comparing: comparing) }
  }

  func showScanPage(sessionId: String, pageId: String) throws {
    try call { try $0.showPage(sessionId: sessionId, pageId: pageId) }
  }

  func exportScanSessionToPdf(request: PdfScanExportRequest) throws {
    try call { try $0.exportSession(request: request) }
  }

  func cancelScanOperation(operationId: String) throws {
    coordinator.cancelOperation(operationId: operationId)
  }

  func discardScanSession(sessionId: String) throws {
    coordinator.discardSession(sessionId: sessionId)
  }

  func listExportedScans() throws -> [PdfScanExportedDocument] {
    coordinator.listExportedScans()
  }

  func openExportedScan(path: String) throws {
    try call { try $0.openExportedScan(path: path) }
  }

  func shareExportedScan(path: String) throws {
    try call { try $0.shareExportedScan(path: path) }
  }

  func deleteExportedScan(path: String) throws {
    try call { try $0.deleteExportedScan(path: path) }
  }

  private func call(_ body: (PdfScanCoordinator) throws -> Void) throws {
    do {
      try body(coordinator)
    } catch let error as PdfPocError {
      throw error.asPigeonError()
    }
  }
}
