import Foundation
import PDFKit
import QuickLook
import UIKit

/// Read-side of the exports directory: enumerating finished PDFs, previewing
/// one, sharing it, deleting it.
///
/// Deliberately independent of `PdfWorkspaceView` and `PdfViewerBloc`. Opening a
/// scan the user just made should not require the whole PDF editing stack to be
/// on screen, so this presents Quick Look directly.
final class PdfScanLibrary: NSObject {
  private let store: PdfScanSessionStore
  private var previewURL: URL?

  init(store: PdfScanSessionStore) {
    self.store = store
    super.init()
  }

  // MARK: - Listing

  func exportedDocuments() -> [PdfScanExportedDocument] {
    store.exportedDocumentURLs().map { url in
      let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
      let modified = values?.contentModificationDate ?? Date()
      let size = Int64(values?.fileSize ?? 0)

      // Opening the document just to count pages is the expensive part of this
      // listing; it is still cheaper than rendering a thumbnail, and the count
      // is the one thing the filesystem cannot answer.
      let pageCount = PDFDocument(url: url)?.pageCount ?? 0

      return PdfScanExportedDocument(
        path: url.path,
        fileName: url.deletingPathExtension().lastPathComponent,
        pageCount: Int64(pageCount),
        fileSizeBytes: size,
        createdAtEpochMs: Int64(modified.timeIntervalSince1970 * 1000)
      )
    }
  }

  // MARK: - Actions

  func open(path: String, presenter: UIViewController) throws {
    let url = try existingURL(for: path)
    previewURL = url

    let controller = QLPreviewController()
    controller.dataSource = self
    controller.delegate = self
    logPdfEvent("scan_library_preview", "file=\(url.lastPathComponent)")
    presenter.present(controller, animated: true)
  }

  func share(path: String, presenter: UIViewController) throws {
    let url = try existingURL(for: path)
    let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    // Required on iPad, where a share sheet without an anchor traps the app in
    // an unpresentable state.
    controller.popoverPresentationController?.sourceView = presenter.view
    controller.popoverPresentationController?.sourceRect = CGRect(
      x: presenter.view.bounds.midX,
      y: presenter.view.bounds.midY,
      width: 0,
      height: 0
    )
    controller.popoverPresentationController?.permittedArrowDirections = []
    presenter.present(controller, animated: true)
  }

  func delete(path: String) throws {
    let url = try existingURL(for: path)
    do {
      try FileManager.default.removeItem(at: url)
      logPdfEvent("scan_library_deleted", "file=\(url.lastPathComponent)")
    } catch {
      throw PdfPocError(
        code: "scan_delete_failed",
        message: "Could not delete that PDF.",
        details: error.localizedDescription
      )
    }
  }

  /// Guards against a path that was listed earlier and has since been deleted —
  /// by this app, by the Files app, or by the system.
  private func existingURL(for path: String) throws -> URL {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw PdfPocError(
        code: "scan_document_not_found",
        message: "That PDF is no longer on this device.",
        details: path
      )
    }
    return url
  }
}

extension PdfScanLibrary: QLPreviewControllerDataSource, QLPreviewControllerDelegate {
  func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
    previewURL == nil ? 0 : 1
  }

  func previewController(
    _ controller: QLPreviewController,
    previewItemAt index: Int
  ) -> QLPreviewItem {
    (previewURL ?? URL(fileURLWithPath: "")) as NSURL
  }

  func previewControllerDidDismiss(_ controller: QLPreviewController) {
    previewURL = nil
  }
}
