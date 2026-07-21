import PDFKit
import PencilKit
import UIKit

private let electronicSignatureAnnotationContents = "PDF POC electronic signature"

/// Owns POC 2 electronic signature state: PencilKit capture, placement overlay,
/// captured-stroke conversion, signature annotation selection, and deletion.
final class PdfSignatureManager {
  let captureView = PdfSignatureCaptureView(frame: .zero)
  let placementView = PdfSignaturePlacementView(frame: .zero)

  private weak var pdfView: PDFView?
  private var capturedDrawing: PKDrawing?
  private var capturedImage: UIImage?
  private weak var placementPage: PDFPage?
  private weak var selectedAnnotation: PDFAnnotation?
  private weak var selectedPage: PDFPage?

  init(pdfView: PDFView) {
    self.pdfView = pdfView
  }

  func layout(pdfFrame: CGRect) {
    captureView.frame = pdfFrame.insetBy(dx: 16, dy: 16)
  }

  func close() {
    cancelCapture()
    cancelPlacementOverlay()
    clearSelection()
    capturedDrawing = nil
    capturedImage = nil
  }

  func capture(in workspaceView: UIView) {
    logPdfEvent("capture_electronic_signature_start")
    captureView.show(drawing: capturedDrawing)
    workspaceView.bringSubviewToFront(captureView)
  }

  func clearCapture() {
    logPdfEvent(
      "clear_electronic_signature_capture",
      "strokes=\(captureView.canvasView.drawing.strokes.count)"
    )
    captureView.clear()
  }

  func confirmCapture() throws {
    let drawing = captureView.canvasView.drawing
    logPdfEvent("confirm_electronic_signature_capture", "strokes=\(drawing.strokes.count)")
    guard !drawing.strokes.isEmpty, !drawing.bounds.isEmpty else {
      throw PdfPocError(
        code: "no_signature_input",
        message: "Draw an electronic signature before confirming capture.",
        details: nil
      )
    }
    capturedDrawing = drawing
    capturedImage = signatureImage(from: drawing)
    captureView.hideCapture()
    logPdfEvent("confirm_electronic_signature_success", "bounds=\(drawing.bounds)")
  }

  func beginPlacement(in workspaceView: UIView, currentPageIndex: Int64) throws {
    guard let pdfView else {
      throw PdfPocError.documentNotOpen()
    }
    guard let image = capturedImage else {
      throw PdfPocError(
        code: "no_signature_capture",
        message: "Capture and confirm an electronic signature before placement.",
        details: nil
      )
    }
    guard let page = pdfView.currentPage else {
      throw PdfPocError.pageOutOfRange(currentPageIndex)
    }
    logPdfEvent("begin_signature_placement", "pageIndex=\(currentPageIndex)")
    clearSelection()
    placementPage = page
    placementView.begin(
      image: image,
      frame: defaultPlacementFrame(imageSize: image.size, page: page, workspaceView: workspaceView)
    )
    workspaceView.bringSubviewToFront(placementView)
  }

  func resizePlacement(_ scale: CGFloat, containerBounds: CGRect) throws {
    guard placementView.isActive else {
      throw PdfPocError(
        code: "no_signature_placement",
        message: "Place the electronic signature before resizing it.",
        details: nil
      )
    }
    placementView.resize(by: scale, containerBounds: containerBounds)
    logPdfEvent("resize_signature_placement", "scale=\(scale) frame=\(placementView.frame)")
  }

  func commitPlacement(in workspaceView: UIView) throws {
    guard let drawing = capturedDrawing,
          let page = placementPage,
          placementView.isActive else {
      throw PdfPocError(
        code: "no_signature_placement",
        message: "Place the electronic signature before committing it.",
        details: nil
      )
    }
    let pageRect = placementPageRect(page: page, workspaceView: workspaceView)
    guard pageRect.width >= 16, pageRect.height >= 8 else {
      throw PdfPocError(
        code: "invalid_annotation_bounds",
        message: "Electronic signature placement is too small.",
        details: "bounds=\(pageRect)"
      )
    }
    let paths = signaturePaths(from: drawing, in: pageRect)
    guard !paths.isEmpty else {
      throw PdfPocError(
        code: "annotation_creation_failed",
        message: "The captured electronic signature could not be converted to PDF paths.",
        details: nil
      )
    }
    let annotation = PDFAnnotation(
      bounds: page.bounds(for: .cropBox),
      forType: .ink,
      withProperties: nil
    )
    annotation.contents = electronicSignatureAnnotationContents
    annotation.color = UIColor.black.withAlphaComponent(0.95)
    let border = PDFBorder()
    border.lineWidth = 2
    annotation.border = border
    for path in paths {
      annotation.add(path)
    }
    page.addAnnotation(annotation)
    selectedAnnotation = annotation
    selectedPage = page
    cancelPlacementOverlay()
    logPdfEvent("commit_electronic_signature_success", "bounds=\(pageRect)")
  }

  func cancelPlacement() {
    logPdfEvent("cancel_signature_placement")
    cancelPlacementOverlay()
  }

  func deleteSelectedSignature() throws {
    guard let annotation = selectedAnnotation,
          let page = selectedPage else {
      throw PdfPocError(
        code: "no_annotation_selection",
        message: "Tap an electronic signature annotation before deleting.",
        details: nil
      )
    }
    guard isElectronicSignatureAnnotation(annotation) else {
      throw PdfPocError(
        code: "unsupported_annotation_type",
        message: "POC 2 only deletes selected electronic signature annotations.",
        details: annotation.type
      )
    }
    page.removeAnnotation(annotation)
    clearSelection()
    logPdfEvent("delete_selected_signature_success")
  }

  func isElectronicSignatureAnnotation(_ annotation: PDFAnnotation) -> Bool {
    annotation.contents == electronicSignatureAnnotationContents
  }

  func select(annotation: PDFAnnotation, page: PDFPage) {
    selectedAnnotation = annotation
    selectedPage = page
    logPdfEvent("electronic_signature_selected", "bounds=\(annotation.bounds)")
  }

  func clearSelection() {
    selectedAnnotation = nil
    selectedPage = nil
  }

  private func cancelCapture() {
    captureView.hideCapture()
  }

  private func cancelPlacementOverlay() {
    placementView.cancel()
    placementPage = nil
  }

  private func signatureImage(from drawing: PKDrawing) -> UIImage {
    let drawingBounds = drawing.bounds.insetBy(dx: -12, dy: -12)
    let bounds = drawingBounds.isEmpty
      ? CGRect(x: 0, y: 0, width: 320, height: 120)
      : drawingBounds
    return drawing.image(from: bounds, scale: UIScreen.main.scale)
      .withRenderingMode(.alwaysTemplate)
  }

  private func defaultPlacementFrame(
    imageSize: CGSize,
    page: PDFPage,
    workspaceView: UIView
  ) -> CGRect {
    guard let pdfView else {
      return .zero
    }
    let pageViewRect = pdfView.convert(page.bounds(for: .cropBox), from: page)
    let workspacePageRect = pdfView.convert(pageViewRect, to: workspaceView)
    let targetWidth = min(max(workspacePageRect.width * 0.45, 140), 260)
    let aspect = imageSize.width > 0 ? imageSize.height / imageSize.width : 0.35
    let targetHeight = max(targetWidth * aspect, 56)
    return CGRect(
      x: workspacePageRect.midX - targetWidth / 2,
      y: workspacePageRect.midY - targetHeight / 2,
      width: targetWidth,
      height: targetHeight
    )
  }

  private func placementPageRect(page: PDFPage, workspaceView: UIView) -> CGRect {
    guard let pdfView else {
      return .zero
    }
    let viewRect = pdfView.convert(placementView.frame, from: workspaceView)
    let pagePointA = pdfView.convert(viewRect.origin, to: page)
    let pagePointB = pdfView.convert(
      CGPoint(x: viewRect.maxX, y: viewRect.maxY),
      to: page
    )
    return normalizedRect(from: pagePointA, to: pagePointB)
  }

  private func signaturePaths(from drawing: PKDrawing, in pageRect: CGRect) -> [UIBezierPath] {
    let sourceBounds = drawing.bounds
    guard sourceBounds.width > 0, sourceBounds.height > 0 else {
      return []
    }
    var paths: [UIBezierPath] = []
    for stroke in drawing.strokes {
      var activePath: UIBezierPath?
      var pointCount = 0
      for strokePoint in stroke.path {
        let location = strokePoint.location
        let normalizedX = (location.x - sourceBounds.minX) / sourceBounds.width
        let normalizedY = (location.y - sourceBounds.minY) / sourceBounds.height
        let pagePoint = CGPoint(
          x: pageRect.minX + normalizedX * pageRect.width,
          y: pageRect.maxY - normalizedY * pageRect.height
        )
        if activePath == nil {
          activePath = UIBezierPath()
          activePath?.move(to: pagePoint)
          pointCount = 1
        } else {
          activePath?.addLine(to: pagePoint)
          pointCount += 1
        }
      }
      if pointCount > 1, let activePath {
        paths.append(activePath)
      }
    }
    logPdfEvent("signature_paths_collected", "paths=\(paths.count)")
    return paths
  }

  private func normalizedRect(from firstPoint: CGPoint, to secondPoint: CGPoint) -> CGRect {
    CGRect(
      x: min(firstPoint.x, secondPoint.x),
      y: min(firstPoint.y, secondPoint.y),
      width: abs(firstPoint.x - secondPoint.x),
      height: abs(firstPoint.y - secondPoint.y)
    )
  }
}
