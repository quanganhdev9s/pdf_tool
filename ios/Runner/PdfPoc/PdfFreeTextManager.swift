import PDFKit
import UIKit

/// Owns free-text area selection: the transparent drag capture view, visible
/// overlay rectangle, PDFView-to-PDFPage coordinate conversion, and callbacks.
final class PdfFreeTextManager: NSObject, UIGestureRecognizerDelegate {
  let captureView = UIView()
  let overlayView = UIView()

  var onSelection: ((PdfFreeTextAreaSelection) -> Void)?
  var onError: ((PdfPocError) -> Void)?

  private weak var pdfView: PDFView?
  private var isSelectingArea = false
  private var dragStartPoint: CGPoint?
  private weak var dragPage: PDFPage?
  private lazy var panGesture = UIPanGestureRecognizer(
    target: self,
    action: #selector(handlePan(_:))
  )

  init(pdfView: PDFView) {
    self.pdfView = pdfView
    super.init()
    configureViews()
  }

  func layout(frame: CGRect) {
    captureView.frame = frame
  }

  func beginSelection(in workspaceView: UIView) {
    logPdfEvent("begin_free_text_area_selection")
    isSelectingArea = true
    captureView.frame = pdfView?.frame ?? workspaceView.bounds
    captureView.isHidden = false
    overlayView.isHidden = true
    workspaceView.bringSubviewToFront(captureView)
    workspaceView.bringSubviewToFront(overlayView)
    panGesture.isEnabled = true
  }

  func cancelSelection() {
    logPdfEvent("free_text_area_selection_reset")
    isSelectingArea = false
    dragStartPoint = nil
    dragPage = nil
    captureView.isHidden = true
    overlayView.isHidden = true
    overlayView.frame = .zero
    panGesture.isEnabled = false
  }

  private func configureViews() {
    captureView.isHidden = true
    captureView.backgroundColor = .clear
    captureView.isUserInteractionEnabled = true

    overlayView.isHidden = true
    overlayView.isUserInteractionEnabled = false
    overlayView.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
    overlayView.layer.borderColor = UIColor.systemBlue.cgColor
    overlayView.layer.borderWidth = 2
    overlayView.layer.cornerRadius = 4

    panGesture.isEnabled = false
    panGesture.cancelsTouchesInView = true
    panGesture.delegate = self
    captureView.addGestureRecognizer(panGesture)
  }

  @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
    guard isSelectingArea, let pdfView, let workspaceView = captureView.superview else {
      recognizer.isEnabled = false
      return
    }

    let point = recognizer.location(in: pdfView)
    switch recognizer.state {
    case .began:
      guard let page = pdfView.page(for: point, nearest: false) else {
        logPdfEvent("free_text_area_drag_begin_failed", "point=\(point)")
        onError?(
          PdfPocError(
            code: "invalid_annotation_bounds",
            message: "Start the free-text area inside a PDF page.",
            details: nil
          )
        )
        cancelSelection()
        return
      }
      dragStartPoint = point
      dragPage = page
      logPdfEvent("free_text_area_drag_begin", "point=\(point)")
      overlayView.frame = CGRect(origin: pdfView.convert(point, to: workspaceView), size: .zero)
      overlayView.isHidden = false
      workspaceView.bringSubviewToFront(overlayView)

    case .changed:
      guard let startPoint = dragStartPoint else {
        return
      }
      overlayView.frame = normalizedRect(
        from: pdfView.convert(startPoint, to: workspaceView),
        to: pdfView.convert(point, to: workspaceView)
      )
      logPdfEvent("free_text_area_drag_change", "rect=\(overlayView.frame)")

    case .ended:
      defer {
        cancelSelection()
      }
      guard let startPoint = dragStartPoint,
            let page = dragPage else {
        return
      }
      do {
        let pageRect = try selectedPageRect(
          page: page,
          startPointInPdfView: startPoint,
          endPointInPdfView: point
        )
        let pageIndex = try pageIndex(for: page)
        logPdfEvent(
          "free_text_area_drag_end",
          "pageIndex=\(pageIndex) pageRect=\(pageRect)"
        )
        onSelection?(
          PdfFreeTextAreaSelection(
            pageIndex: pageIndex,
            bounds: PdfRect(
              x: pageRect.origin.x,
              y: pageRect.origin.y,
              width: pageRect.width,
              height: pageRect.height
            )
          )
        )
      } catch let error as PdfPocError {
        onError?(error)
      } catch {
        onError?(
          PdfPocError(
            code: "internal_error",
            message: "Could not create the selected free-text area.",
            details: error.localizedDescription
          )
        )
      }

    case .cancelled, .failed:
      logPdfEvent("free_text_area_drag_cancelled", "state=\(recognizer.state.rawValue)")
      cancelSelection()

    default:
      break
    }
  }

  private func selectedPageRect(
    page: PDFPage,
    startPointInPdfView: CGPoint,
    endPointInPdfView: CGPoint
  ) throws -> CGRect {
    guard let pdfView else {
      throw PdfPocError.documentNotOpen()
    }
    let rawViewRect = normalizedRect(from: startPointInPdfView, to: endPointInPdfView)
    let pageViewRect = pdfView.convert(page.bounds(for: .cropBox), from: page)
    let clippedViewRect = rawViewRect.intersection(pageViewRect)
    guard !clippedViewRect.isNull,
          clippedViewRect.width >= 16,
          clippedViewRect.height >= 16 else {
      throw PdfPocError(
        code: "invalid_annotation_bounds",
        message: "Drag a larger free-text area inside one PDF page.",
        details: "viewRect=\(rawViewRect)"
      )
    }

    let pagePointA = pdfView.convert(clippedViewRect.origin, to: page)
    let pagePointB = pdfView.convert(
      CGPoint(x: clippedViewRect.maxX, y: clippedViewRect.maxY),
      to: page
    )
    let pageRect = normalizedRect(from: pagePointA, to: pagePointB)
    guard pageRect.width >= 8, pageRect.height >= 8 else {
      throw PdfPocError(
        code: "invalid_annotation_bounds",
        message: "The selected PDF area is too small for free text.",
        details: "pageRect=\(pageRect)"
      )
    }
    logPdfEvent(
      "free_text_area_rect_converted",
      "viewRect=\(rawViewRect) clippedViewRect=\(clippedViewRect) pageRect=\(pageRect)"
    )
    return pageRect
  }

  private func pageIndex(for page: PDFPage) throws -> Int64 {
    guard let document = pdfView?.document else {
      throw PdfPocError.documentNotOpen()
    }
    let index = document.index(for: page)
    guard index != NSNotFound else {
      throw PdfPocError(
        code: "page_out_of_range",
        message: "The selected page is not part of the open document.",
        details: nil
      )
    }
    return Int64(index)
  }

  private func normalizedRect(from firstPoint: CGPoint, to secondPoint: CGPoint) -> CGRect {
    CGRect(
      x: min(firstPoint.x, secondPoint.x),
      y: min(firstPoint.y, secondPoint.y),
      width: abs(firstPoint.x - secondPoint.x),
      height: abs(firstPoint.y - secondPoint.y)
    )
  }

  func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    gestureRecognizer === panGesture ? isSelectingArea : true
  }
}
