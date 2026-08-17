import Foundation
import UIKit
import UniformTypeIdentifiers

/// Picks a document for view-only display. Nothing is converted and no output
/// is produced; the picked file is copied locally and its path is handed to
/// Flutter, which then hosts `PdfDocumentViewerView`.
final class PdfOfficePreviewManager: NSObject {
  var onPicked: ((PdfViewableDocument) -> Void)?
  var onCancelled: (() -> Void)?
  var onError: ((PdfPocError) -> Void)?

  /// Everything the conversion picker accepts, plus PDFs, which conversion
  /// deliberately excludes.
  private static var viewableContentTypes: [UTType] {
    PdfFileConversionManager.supportedContentTypes + [.pdf]
  }

  func pickDocument(presenter: UIViewController) throws {
    guard Thread.isMainThread else {
      throw PdfPocError(
        code: "internal_error",
        message: "The document picker must be presented on the main thread.",
        details: nil
      )
    }
    let picker = UIDocumentPickerViewController(
      forOpeningContentTypes: Self.viewableContentTypes,
      asCopy: true
    )
    picker.delegate = self
    picker.allowsMultipleSelection = false
    logPdfEvent("document_view_pick_present")
    presenter.present(picker, animated: true)
  }
}

extension PdfOfficePreviewManager: UIDocumentPickerDelegate {
  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    guard let sourceURL = urls.first else {
      onCancelled?()
      return
    }
    let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
    let document = PdfViewableDocument(
      path: sourceURL.path,
      fileName: sourceURL.lastPathComponent,
      fileFormat: sourceURL.pathExtension.lowercased(),
      fileSizeBytes: (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    )
    logPdfEvent(
      "document_view_picked",
      "file=\(document.fileName) bytes=\(document.fileSizeBytes)"
    )
    onPicked?(document)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    logPdfEvent("document_view_pick_cancelled")
    onCancelled?()
  }
}
