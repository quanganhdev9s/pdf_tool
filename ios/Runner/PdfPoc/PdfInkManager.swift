import PDFKit
import PencilKit
import UIKit

/// Owns POC 1 ink mode: the PencilKit canvas overlay, stroke-to-PDF conversion,
/// selected ink annotation state, and deletion of selected ink annotations.
final class PdfInkManager {
  let canvasView = PKCanvasView()

  private weak var pdfView: PDFView?
  private var isModeEnabled = false
  private weak var selectedAnnotation: PDFAnnotation?
  private weak var selectedPage: PDFPage?

  init(pdfView: PDFView) {
    self.pdfView = pdfView
    configureCanvasView()
  }

  var isEnabled: Bool {
    isModeEnabled
  }

  func layout(frame: CGRect, contentSize: CGSize) {
    canvasView.frame = frame
    canvasView.contentSize = contentSize
  }

  func close() {
    clearSelection()
    canvasView.drawing = PKDrawing()
    setModeVisualState(enabled: false)
  }

  func setModeEnabled(_ enabled: Bool) {
    isModeEnabled = enabled
    if enabled {
      clearSelection()
    }
    setModeVisualState(enabled: enabled)
  }

  func clearCurrentInput() {
    logPdfEvent("clear_current_ink_input", "strokes=\(canvasView.drawing.strokes.count)")
    canvasView.drawing = PKDrawing()
    setModeVisualState(enabled: isModeEnabled)
  }

  func commitCurrentInkToPdf() throws -> Int {
    logPdfEvent("commit_ink_request", "strokes=\(canvasView.drawing.strokes.count)")
    guard !canvasView.drawing.strokes.isEmpty else {
      throw PdfPocError(
        code: "no_ink_input",
        message: "Draw ink before committing it to the PDF.",
        details: nil
      )
    }

    let pagePaths = collectInkPathsByPage(from: canvasView.drawing)
    guard !pagePaths.isEmpty else {
      throw PdfPocError(
        code: "annotation_creation_failed",
        message: "No drawn ink points were inside a PDF page.",
        details: nil
      )
    }

    var added = 0
    for (page, paths) in pagePaths {
      guard !paths.isEmpty else { continue }
      let annotation = PDFAnnotation(
        bounds: page.bounds(for: .cropBox),
        forType: .ink,
        withProperties: nil
      )
      annotation.color = UIColor.systemBlue.withAlphaComponent(0.95)
      let border = PDFBorder()
      border.lineWidth = 2
      annotation.border = border
      for path in paths {
        annotation.add(path)
      }
      page.addAnnotation(annotation)
      added += 1
    }

    guard added > 0 else {
      throw PdfPocError(
        code: "annotation_creation_failed",
        message: "PDFKit did not accept the captured ink paths.",
        details: nil
      )
    }

    canvasView.drawing = PKDrawing()
    clearSelection()
    logPdfEvent("commit_ink_success", "annotations=\(added)")
    return added
  }

  func selectInkAnnotation(_ annotation: PDFAnnotation, page: PDFPage) {
    selectedAnnotation = annotation
    selectedPage = page
    logPdfEvent("ink_annotation_selected", "bounds=\(annotation.bounds)")
  }

  func deleteSelectedAnnotation() throws {
    guard let annotation = selectedAnnotation,
          let page = selectedPage else {
      throw PdfPocError(
        code: "no_annotation_selection",
        message: "Tap an ink annotation in read mode before deleting.",
        details: nil
      )
    }
    guard annotation.type == PDFAnnotationSubtype.ink.rawValue else {
      throw PdfPocError(
        code: "unsupported_annotation_type",
        message: "POC 1 only deletes selected ink annotations.",
        details: annotation.type
      )
    }
    page.removeAnnotation(annotation)
    clearSelection()
    logPdfEvent("delete_selected_annotation_success")
  }

  func clearSelection() {
    selectedAnnotation = nil
    selectedPage = nil
  }

  private func configureCanvasView() {
    canvasView.backgroundColor = .clear
    canvasView.isOpaque = false
    canvasView.drawingPolicy = .anyInput
    canvasView.minimumZoomScale = 1
    canvasView.maximumZoomScale = 1
    canvasView.isScrollEnabled = false
    canvasView.contentInset = .zero
    canvasView.tool = PKInkingTool(.pen, color: .systemBlue, width: 3)
    setModeVisualState(enabled: false)
  }

  private func setModeVisualState(enabled: Bool) {
    canvasView.isUserInteractionEnabled = enabled
    canvasView.isHidden = !enabled && canvasView.drawing.strokes.isEmpty
    if enabled {
      canvasView.becomeFirstResponder()
    } else {
      canvasView.resignFirstResponder()
    }
  }

  private func collectInkPathsByPage(from drawing: PKDrawing) -> [(PDFPage, [UIBezierPath])] {
    guard let pdfView else {
      return []
    }
    var pagePaths: [(PDFPage, [UIBezierPath])] = []

    func append(_ path: UIBezierPath, to page: PDFPage?) {
      guard let page else { return }
      if let index = pagePaths.firstIndex(where: { $0.0 === page }) {
        pagePaths[index].1.append(path)
      } else {
        pagePaths.append((page, [path]))
      }
    }

    for stroke in drawing.strokes {
      var activePage: PDFPage?
      var activePath: UIBezierPath?
      var activePointCount = 0

      // PencilKit strokes can cross pages in continuous scroll mode, while
      // PDF ink annotations belong to exactly one PDFPage.
      func finishActivePath() {
        guard activePointCount > 1, let path = activePath else {
          activePage = nil
          activePath = nil
          activePointCount = 0
          return
        }
        append(path, to: activePage)
        activePage = nil
        activePath = nil
        activePointCount = 0
      }

      for strokePoint in stroke.path {
        let canvasPoint = strokePoint.location
        guard let page = pdfView.page(for: canvasPoint, nearest: false) else {
          finishActivePath()
          continue
        }
        let pagePoint = pdfView.convert(canvasPoint, to: page)
        if activePage !== page {
          finishActivePath()
          activePage = page
          activePath = UIBezierPath()
          activePath?.move(to: pagePoint)
          activePointCount = 1
        } else {
          activePath?.addLine(to: pagePoint)
          activePointCount += 1
        }
      }
      finishActivePath()
    }

    logPdfEvent("ink_paths_collected", "pages=\(pagePaths.count)")
    return pagePaths
  }
}
