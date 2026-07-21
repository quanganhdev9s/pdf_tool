import Foundation
import PDFKit
import PencilKit
import UIKit

let pdfEventTag = "PDF Event"

func logPdfEvent(_ event: String, _ details: String? = nil) {
  let suffix = details.map { " | \($0)" } ?? ""
  print("\(pdfEventTag) | native | \(event)\(suffix)")
}

protocol PdfWorkspaceViewDelegate: AnyObject {
  func workspaceView(_ view: PdfWorkspaceView, didOpen info: PdfDocumentInfo)
  func workspaceViewDidClose(_ view: PdfWorkspaceView)
  func workspaceView(_ view: PdfWorkspaceView, didChangePage pageIndex: Int64, pageCount: Int64)
  func workspaceView(_ view: PdfWorkspaceView, didChangeDirtyState isDirty: Bool)
  func workspaceView(_ view: PdfWorkspaceView, didChangeSearchState state: PdfSearchState)
  func workspaceView(_ view: PdfWorkspaceView, didChangeSelection selectedText: String?)
  func workspaceView(_ view: PdfWorkspaceView, didSelectFreeTextArea selection: PdfFreeTextAreaSelection)
  func workspaceView(_ view: PdfWorkspaceView, didFailOperation operationId: String, error: PdfPocError)
}

final class PdfWorkspaceView: UIView {
  weak var delegate: PdfWorkspaceViewDelegate?

  private let pdfView = PocPdfView()
  private let inkCanvasView = PKCanvasView()
  private let selectionToolbar = PdfSelectionToolbar()
  private let freeTextAreaCaptureView = UIView()
  private let freeTextAreaOverlay = UIView()
  private lazy var freeTextAreaPanGesture = UIPanGestureRecognizer(
    target: self,
    action: #selector(handleFreeTextAreaPan(_:))
  )
  private var session: PdfDocumentSession?
  private var pageChangedObserver: NSObjectProtocol?
  private var selectionChangedObserver: NSObjectProtocol?
  private var searchSelections: [PDFSelection] = []
  private var searchQuery = ""
  private var activeSearchIndex = -1
  private var selectionToolbarTargetRect: CGRect?
  private var isSelectingFreeTextArea = false
  private var freeTextDragStartPoint: CGPoint?
  private weak var freeTextDragPage: PDFPage?
  private var isInkModeEnabled = false
  private weak var selectedInkAnnotation: PDFAnnotation?
  private weak var selectedInkPage: PDFPage?
  private lazy var annotationTapGesture = UITapGestureRecognizer(
    target: self,
    action: #selector(handleAnnotationTap(_:))
  )

  override init(frame: CGRect) {
    super.init(frame: frame)
    configureView()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configureView()
  }

  deinit {
    close()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    inkCanvasView.frame = pdfView.frame
    inkCanvasView.contentSize = pdfView.bounds.size
    freeTextAreaCaptureView.frame = pdfView.frame
    layoutSelectionToolbar()
  }

  func open(assetKey: String, assetBytes: Data, reset: Bool) throws -> PdfDocumentInfo {
    try ensureMainThread()
    logPdfEvent("open_start", "asset=\(assetKey) reset=\(reset) bytes=\(assetBytes.count)")
    let workingURL = try workingCopyURL(for: assetKey)

    // Assets are read-only in Flutter. PDFKit always works on this writable
    // copy so annotation/save tests cannot mutate the bundled source PDF.
    if reset || !FileManager.default.fileExists(atPath: workingURL.path) {
      do {
        try FileManager.default.createDirectory(
          at: workingURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try assetBytes.write(to: workingURL, options: [.atomic])
      } catch {
        throw PdfPocError(
          code: "asset_copy_failed",
          message: "Could not create a writable copy of the selected PDF asset.",
          details: error.localizedDescription
        )
      }
    }

    let document = try openDocument(at: workingURL)
    detachObservers()
    clearSearchOnly()

    session = PdfDocumentSession(assetKey: assetKey, workingURL: workingURL, document: document)
    pdfView.document = document
    pdfView.autoScales = true
    pdfView.goToFirstPage(nil)
    attachObservers()

    let info = documentInfo()
    logPdfEvent(
      "open_success",
      "asset=\(assetKey) pages=\(info.pageCount) searchable=\(info.hasSearchableText)"
    )
    delegate?.workspaceView(self, didOpen: info)
    notifyPageChanged()
    delegate?.workspaceView(self, didChangeDirtyState: false)
    return info
  }

  func close() {
    logPdfEvent("close")
    detachObservers()
    clearSearchOnly()
    hideSelectionToolbar()
    cancelFreeTextAreaSelection()
    clearInkSelection()
    inkCanvasView.drawing = PKDrawing()
    setInkModeVisualState(enabled: false)
    pdfView.document = nil
    session = nil
    delegate?.workspaceViewDidClose(self)
  }

  func goToPage(_ pageIndex: Int64) throws {
    try ensureMainThread()
    logPdfEvent("go_to_page_request", "pageIndex=\(pageIndex)")
    let document = try requireDocument()
    guard pageIndex >= 0, pageIndex < document.pageCount else {
      throw PdfPocError.pageOutOfRange(pageIndex)
    }
    guard let page = document.page(at: Int(pageIndex)) else {
      throw PdfPocError.pageOutOfRange(pageIndex)
    }
    pdfView.go(to: page)
    notifyPageChanged()
  }

  func goToNextPage() throws {
    try ensureMainThread()
    logPdfEvent("go_to_next_page_request")
    _ = try requireDocument()
    pdfView.goToNextPage(nil)
    notifyPageChanged()
  }

  func goToPreviousPage() throws {
    try ensureMainThread()
    logPdfEvent("go_to_previous_page_request")
    _ = try requireDocument()
    pdfView.goToPreviousPage(nil)
    notifyPageChanged()
  }

  func search(_ request: PdfSearchRequest) throws -> PdfSearchState {
    try ensureMainThread()
    let document = try requireDocument()
    let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
    logPdfEvent(
      "search_request",
      "query=\(query) caseSensitive=\(request.caseSensitive) wholeWord=\(request.wholeWord)"
    )
    clearSearchOnly()
    searchQuery = query

    guard !query.isEmpty else {
      let state = searchState()
      delegate?.workspaceView(self, didChangeSearchState: state)
      return state
    }

    guard hasSearchableText(document) else {
      throw PdfPocError(
        code: "no_searchable_text",
        message: "This PDF does not expose a searchable text layer.",
        details: nil
      )
    }

    var options: NSString.CompareOptions = []
    if !request.caseSensitive {
      options.insert(.caseInsensitive)
    }
    searchSelections = document.findString(query, withOptions: options)
      .filter { selection in
        if request.wholeWord {
          return selection.string?.range(
            of: query,
            options: request.caseSensitive ? [] : [.caseInsensitive]
          ) != nil
        }
        return true
      }

    if !searchSelections.isEmpty {
      activeSearchIndex = 0
      showActiveSearchResult()
    }

    let state = searchState()
    logPdfEvent(
      "search_result",
      "query=\(state.query) total=\(state.totalResults) active=\(state.activeResultIndex)"
    )
    delegate?.workspaceView(self, didChangeSearchState: state)
    return state
  }

  func goToNextSearchResult() throws -> PdfSearchState {
    try ensureMainThread()
    logPdfEvent("go_to_next_search_result_request")
    guard !searchSelections.isEmpty else {
      let state = searchState()
      delegate?.workspaceView(self, didChangeSearchState: state)
      return state
    }
    activeSearchIndex = (activeSearchIndex + 1) % searchSelections.count
    showActiveSearchResult()
    let state = searchState()
    delegate?.workspaceView(self, didChangeSearchState: state)
    return state
  }

  func goToPreviousSearchResult() throws -> PdfSearchState {
    try ensureMainThread()
    logPdfEvent("go_to_previous_search_result_request")
    guard !searchSelections.isEmpty else {
      let state = searchState()
      delegate?.workspaceView(self, didChangeSearchState: state)
      return state
    }
    activeSearchIndex = (activeSearchIndex - 1 + searchSelections.count) % searchSelections.count
    showActiveSearchResult()
    let state = searchState()
    delegate?.workspaceView(self, didChangeSearchState: state)
    return state
  }

  func clearSearch() throws {
    try ensureMainThread()
    logPdfEvent("clear_search")
    clearSearchOnly()
    delegate?.workspaceView(self, didChangeSearchState: searchState())
  }

  func selectedText() throws -> String? {
    try ensureMainThread()
    _ = try requireDocument()
    let text = currentSelectionText()
    logPdfEvent("get_selected_text", "length=\(text?.count ?? 0)")
    return text
  }

  func copySelectedText() throws {
    try ensureMainThread()
    guard let text = currentSelectionText(), !text.isEmpty else {
      throw PdfPocError(
        code: "no_text_selection",
        message: "Select PDF text before copying.",
        details: nil
      )
    }
    logPdfEvent("copy_selected_text", "length=\(text.count)")
    UIPasteboard.general.string = text
  }

  func addMarkupFromCurrentSelection(_ type: PdfMarkupType) throws {
    try ensureMainThread()
    logPdfEvent("add_markup_request", "type=\(type)")
    let selection = try requireSelection()
    // PDFKit returns better annotation bounds per line than as one large union,
    // especially for multi-line selections.
    let lineSelections = selection.selectionsByLine()
    let selections = lineSelections.isEmpty ? [selection] : lineSelections
    var added = 0

    for lineSelection in selections {
      for page in lineSelection.pages {
        let bounds = lineSelection.bounds(for: page)
        guard bounds.width > 0, bounds.height > 0 else {
          continue
        }
        let annotation = PDFAnnotation(
          bounds: bounds.insetBy(dx: -1, dy: -1),
          forType: annotationSubtype(for: type),
          withProperties: nil
        )
        annotation.color = annotationColor(for: type)
        page.addAnnotation(annotation)
        added += 1
      }
    }

    guard added > 0 else {
      throw PdfPocError(
        code: "annotation_creation_failed",
        message: "PDFKit did not provide valid selection bounds for annotation.",
        details: nil
      )
    }
    markDirty()
    logPdfEvent("add_markup_success", "type=\(type) annotations=\(added)")
    updateSelectionToolbar()
  }

  func addFreeText(_ request: PdfFreeTextRequest) throws {
    try ensureMainThread()
    logPdfEvent(
      "add_free_text_request",
      "pageIndex=\(request.pageIndex) textLength=\(request.text.count) bounds=\(request.bounds)"
    )
    let document = try requireDocument()
    guard request.pageIndex >= 0, request.pageIndex < document.pageCount,
          let page = document.page(at: Int(request.pageIndex)) else {
      throw PdfPocError.pageOutOfRange(request.pageIndex)
    }
    let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      throw PdfPocError(
        code: "invalid_annotation_bounds",
        message: "Free-text annotation text cannot be empty.",
        details: nil
      )
    }

    let requestedBounds = CGRect(
      x: request.bounds.x,
      y: request.bounds.y,
      width: request.bounds.width,
      height: request.bounds.height
    )
    guard requestedBounds.width > 0, requestedBounds.height > 0 else {
      throw PdfPocError(
        code: "invalid_annotation_bounds",
        message: "Free-text annotation bounds must have positive width and height.",
        details: "\(requestedBounds)"
      )
    }

    let pageBounds = page.bounds(for: .cropBox)
    // Clamp to cropBox because every rect crossing the Dart/Swift boundary uses
    // visible page coordinates for POC 0.
    let bounds = requestedBounds.intersection(pageBounds)
    guard !bounds.isNull, bounds.width >= 8, bounds.height >= 8 else {
      throw PdfPocError(
        code: "invalid_annotation_bounds",
        message: "Free-text annotation bounds must intersect the page crop box.",
        details: "bounds=\(requestedBounds), cropBox=\(pageBounds)"
      )
    }

    let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
    annotation.contents = text
    annotation.font = UIFont.systemFont(ofSize: request.fontSize)
    annotation.fontColor = UIColor(argb: request.textColor.argb)
    annotation.color = UIColor.clear
    annotation.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.18)
    page.addAnnotation(annotation)
    markDirty()
    logPdfEvent("add_free_text_success", "pageIndex=\(request.pageIndex) bounds=\(bounds)")
  }

  func beginFreeTextAreaSelection() throws {
    try ensureMainThread()
    _ = try requireDocument()
    logPdfEvent("begin_free_text_area_selection")
    // This only captures the target rect. Flutter owns the keyboard/text input
    // and will call addFreeText after the user submits text.
    isSelectingFreeTextArea = true
    hideSelectionToolbar()
    hideSystemSelectionMenu()
    freeTextAreaCaptureView.frame = pdfView.frame
    freeTextAreaCaptureView.isHidden = false
    freeTextAreaOverlay.isHidden = true
    bringSubviewToFront(freeTextAreaCaptureView)
    bringSubviewToFront(freeTextAreaOverlay)
    freeTextAreaPanGesture.isEnabled = true
  }

  func setInkModeEnabled(_ enabled: Bool) throws {
    try ensureMainThread()
    _ = try requireDocument()
    logPdfEvent("set_ink_mode", "enabled=\(enabled)")
    isInkModeEnabled = enabled
    if enabled {
      cancelFreeTextAreaSelection()
      hideSelectionToolbar()
      hideSystemSelectionMenu()
      clearInkSelection()
    }
    setInkModeVisualState(enabled: enabled)
  }

  func clearCurrentInkInput() throws {
    try ensureMainThread()
    _ = try requireDocument()
    logPdfEvent("clear_current_ink_input", "strokes=\(inkCanvasView.drawing.strokes.count)")
    inkCanvasView.drawing = PKDrawing()
    setInkModeVisualState(enabled: isInkModeEnabled)
  }

  func commitCurrentInkToPdf() throws {
    try ensureMainThread()
    _ = try requireDocument()
    logPdfEvent("commit_ink_request", "strokes=\(inkCanvasView.drawing.strokes.count)")
    guard !inkCanvasView.drawing.strokes.isEmpty else {
      throw PdfPocError(
        code: "no_ink_input",
        message: "Draw ink before committing it to the PDF.",
        details: nil
      )
    }

    let pagePaths = collectInkPathsByPage(from: inkCanvasView.drawing)
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
      // Keep the output editable by storing real PDF ink annotations instead of
      // rasterizing the PencilKit overlay into page pixels.
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

    inkCanvasView.drawing = PKDrawing()
    clearInkSelection()
    markDirty()
    logPdfEvent("commit_ink_success", "annotations=\(added)")
  }

  func deleteSelectedAnnotation() throws {
    try ensureMainThread()
    _ = try requireDocument()
    guard let annotation = selectedInkAnnotation,
          let page = selectedInkPage else {
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
    clearInkSelection()
    markDirty()
    logPdfEvent("delete_selected_annotation_success")
  }

  func save() throws -> PdfDocumentInfo {
    try ensureMainThread()
    guard let session else {
      throw PdfPocError.documentNotOpen()
    }
    logPdfEvent("save_start", "path=\(session.workingURL.path)")
    guard session.document.write(to: session.workingURL) else {
      throw PdfPocError(
        code: "save_failed",
        message: "PDFKit could not save the writable PDF copy.",
        details: session.workingURL.path
      )
    }

    let reopened = try openDocument(at: session.workingURL)
    self.session = PdfDocumentSession(
      assetKey: session.assetKey,
      workingURL: session.workingURL,
      document: reopened
    )
    pdfView.document = reopened
    pdfView.autoScales = true
    notifyPageChanged()
    delegate?.workspaceView(self, didChangeDirtyState: false)
    let info = documentInfo()
    logPdfEvent("save_success", "path=\(info.workingPath) pages=\(info.pageCount)")
    return info
  }

  private func configureView() {
    backgroundColor = .secondarySystemBackground
    pdfView.translatesAutoresizingMaskIntoConstraints = false
    pdfView.displayMode = .singlePageContinuous
    pdfView.displayDirection = .vertical
    pdfView.autoScales = true
    pdfView.backgroundColor = .secondarySystemBackground
    addSubview(pdfView)
    configureInkCanvasView()
    configureSelectionToolbar()
    configureFreeTextAreaSelection()
    pdfView.addGestureRecognizer(annotationTapGesture)
    annotationTapGesture.delegate = self
    addSubview(inkCanvasView)
    addSubview(selectionToolbar)
    NSLayoutConstraint.activate([
      pdfView.leadingAnchor.constraint(equalTo: leadingAnchor),
      pdfView.trailingAnchor.constraint(equalTo: trailingAnchor),
      pdfView.topAnchor.constraint(equalTo: topAnchor),
      pdfView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  private func configureInkCanvasView() {
    inkCanvasView.frame = pdfView.frame
    inkCanvasView.backgroundColor = .clear
    inkCanvasView.isOpaque = false
    inkCanvasView.drawingPolicy = .anyInput
    inkCanvasView.minimumZoomScale = 1
    inkCanvasView.maximumZoomScale = 1
    inkCanvasView.isScrollEnabled = false
    inkCanvasView.contentInset = .zero
    inkCanvasView.tool = PKInkingTool(.pen, color: .systemBlue, width: 3)
    setInkModeVisualState(enabled: false)
  }

  private func setInkModeVisualState(enabled: Bool) {
    inkCanvasView.isUserInteractionEnabled = enabled
    inkCanvasView.isHidden = !enabled && inkCanvasView.drawing.strokes.isEmpty
    annotationTapGesture.isEnabled = !enabled
    if enabled {
      bringSubviewToFront(inkCanvasView)
      inkCanvasView.becomeFirstResponder()
    } else {
      inkCanvasView.resignFirstResponder()
    }
  }

  private func configureFreeTextAreaSelection() {
    freeTextAreaCaptureView.isHidden = true
    freeTextAreaCaptureView.backgroundColor = .clear
    freeTextAreaCaptureView.isUserInteractionEnabled = true
    addSubview(freeTextAreaCaptureView)

    freeTextAreaOverlay.isHidden = true
    freeTextAreaOverlay.isUserInteractionEnabled = false
    freeTextAreaOverlay.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
    freeTextAreaOverlay.layer.borderColor = UIColor.systemBlue.cgColor
    freeTextAreaOverlay.layer.borderWidth = 2
    freeTextAreaOverlay.layer.cornerRadius = 4
    addSubview(freeTextAreaOverlay)

    freeTextAreaPanGesture.isEnabled = false
    freeTextAreaPanGesture.cancelsTouchesInView = true
    freeTextAreaPanGesture.delegate = self
    freeTextAreaCaptureView.addGestureRecognizer(freeTextAreaPanGesture)
  }

  @objc private func handleFreeTextAreaPan(_ recognizer: UIPanGestureRecognizer) {
    // The transparent capture view owns this gesture while area selection is
    // active, preventing PDFKit scroll/text gestures from consuming the drag.
    guard isSelectingFreeTextArea else {
      recognizer.isEnabled = false
      return
    }

    let point = recognizer.location(in: pdfView)
    switch recognizer.state {
    case .began:
      guard let page = pdfView.page(for: point, nearest: false) else {
        logPdfEvent("free_text_area_drag_begin_failed", "point=\(point)")
        reportFreeTextAreaError(
          PdfPocError(
            code: "invalid_annotation_bounds",
            message: "Start the free-text area inside a PDF page.",
            details: nil
          )
        )
        cancelFreeTextAreaSelection()
        return
      }
      freeTextDragStartPoint = point
      freeTextDragPage = page
      logPdfEvent("free_text_area_drag_begin", "point=\(point)")
      freeTextAreaOverlay.frame = CGRect(origin: pdfView.convert(point, to: self), size: .zero)
      freeTextAreaOverlay.isHidden = false
      bringSubviewToFront(freeTextAreaOverlay)

    case .changed:
      guard let startPoint = freeTextDragStartPoint else {
        return
      }
      let rect = normalizedRect(from: pdfView.convert(startPoint, to: self),
                                to: pdfView.convert(point, to: self))
      freeTextAreaOverlay.frame = rect
      logPdfEvent("free_text_area_drag_change", "rect=\(rect)")

    case .ended:
      defer {
        cancelFreeTextAreaSelection()
      }
      guard let startPoint = freeTextDragStartPoint,
            let page = freeTextDragPage else {
        return
      }
      do {
        let pageRect = try selectedFreeTextPageRect(
          page: page,
          startPointInPdfView: startPoint,
          endPointInPdfView: point
        )
        let pageIndex = try pageIndex(for: page)
        logPdfEvent(
          "free_text_area_drag_end",
          "pageIndex=\(pageIndex) pageRect=\(pageRect)"
        )
        delegate?.workspaceView(
          self,
          didSelectFreeTextArea: PdfFreeTextAreaSelection(
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
        reportFreeTextAreaError(error)
      } catch {
        reportFreeTextAreaError(
          PdfPocError(
            code: "internal_error",
            message: "Could not create the selected free-text area.",
            details: error.localizedDescription
          )
        )
      }

    case .cancelled, .failed:
      logPdfEvent("free_text_area_drag_cancelled", "state=\(recognizer.state.rawValue)")
      cancelFreeTextAreaSelection()

    default:
      break
    }
  }

  private func selectedFreeTextPageRect(
    page: PDFPage,
    startPointInPdfView: CGPoint,
    endPointInPdfView: CGPoint
  ) throws -> CGRect {
    // Convert the user's drag from PDFView screen space into PDF page space.
    // This keeps zoom, scroll offset, page crop box, and rotation on the Swift
    // side where PDFKit can provide the correct transforms.
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
    let document = try requireDocument()
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

  private func cancelFreeTextAreaSelection() {
    logPdfEvent("free_text_area_selection_reset")
    isSelectingFreeTextArea = false
    freeTextDragStartPoint = nil
    freeTextDragPage = nil
    freeTextAreaCaptureView.isHidden = true
    freeTextAreaOverlay.isHidden = true
    freeTextAreaOverlay.frame = .zero
    freeTextAreaPanGesture.isEnabled = false
  }

  private func reportFreeTextAreaError(_ error: PdfPocError) {
    delegate?.workspaceView(self, didFailOperation: "free-text area", error: error)
  }

  private func normalizedRect(from firstPoint: CGPoint, to secondPoint: CGPoint) -> CGRect {
    CGRect(
      x: min(firstPoint.x, secondPoint.x),
      y: min(firstPoint.y, secondPoint.y),
      width: abs(firstPoint.x - secondPoint.x),
      height: abs(firstPoint.y - secondPoint.y)
    )
  }

  private func collectInkPathsByPage(from drawing: PKDrawing) -> [(PDFPage, [UIBezierPath])] {
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

      // A PencilKit stroke can cross a page boundary in continuous scroll mode.
      // PDF ink annotations are page-owned, so split each stroke whenever the
      // containing PDFPage changes or the stroke leaves all pages.
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

  @objc private func handleAnnotationTap(_ recognizer: UITapGestureRecognizer) {
    guard !isInkModeEnabled, recognizer.state == .ended else { return }
    let point = recognizer.location(in: pdfView)
    guard let page = pdfView.page(for: point, nearest: false) else {
      clearInkSelection()
      logPdfEvent("annotation_tap_no_page", "point=\(point)")
      return
    }
    let pagePoint = pdfView.convert(point, to: page)
    guard let annotation = page.annotation(at: pagePoint),
          annotation.type == PDFAnnotationSubtype.ink.rawValue else {
      clearInkSelection()
      logPdfEvent("annotation_tap_no_ink", "point=\(pagePoint)")
      return
    }
    selectedInkAnnotation = annotation
    selectedInkPage = page
    logPdfEvent("ink_annotation_selected", "bounds=\(annotation.bounds)")
  }

  private func clearInkSelection() {
    selectedInkAnnotation = nil
    selectedInkPage = nil
  }

  private func openDocument(at url: URL) throws -> PDFDocument {
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw PdfPocError(
        code: "asset_not_found",
        message: "The writable PDF copy does not exist.",
        details: url.path
      )
    }
    guard let document = PDFDocument(url: url) else {
      throw PdfPocError(
        code: "invalid_pdf",
        message: "PDFKit could not parse the selected file as a PDF.",
        details: url.lastPathComponent
      )
    }
    if document.isLocked {
      throw PdfPocError(
        code: "password_required",
        message: "This PDF is password protected.",
        details: url.lastPathComponent
      )
    }
    guard document.pageCount > 0 else {
      throw PdfPocError(
        code: "invalid_pdf",
        message: "The PDF has no pages.",
        details: url.lastPathComponent
      )
    }
    return document
  }

  private func workingCopyURL(for assetKey: String) throws -> URL {
    guard !assetKey.isEmpty else {
      throw PdfPocError(
        code: "asset_not_found",
        message: "No PDF asset was selected.",
        details: nil
      )
    }
    let supportURL = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let fileName = assetKey
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: ":", with: "_")
    return supportURL.appendingPathComponent("PdfPocWorkingCopies", isDirectory: true)
      .appendingPathComponent(fileName)
  }

  private func attachObservers() {
    pageChangedObserver = NotificationCenter.default.addObserver(
      forName: Notification.Name.PDFViewPageChanged,
      object: pdfView,
      queue: .main
    ) { [weak self] _ in
      self?.logPageChangedFromObserver()
    }
    selectionChangedObserver = NotificationCenter.default.addObserver(
      forName: Notification.Name.PDFViewSelectionChanged,
      object: pdfView,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      self.updateSelectionToolbar()
      let text = self.currentSelectionText()
      let length = text?.trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0
      logPdfEvent("selection_changed", "length=\(length)")
      self.delegate?.workspaceView(self, didChangeSelection: text)
    }
  }

  private func detachObservers() {
    if let pageChangedObserver {
      NotificationCenter.default.removeObserver(pageChangedObserver)
    }
    if let selectionChangedObserver {
      NotificationCenter.default.removeObserver(selectionChangedObserver)
    }
    pageChangedObserver = nil
    selectionChangedObserver = nil
  }

  private func requireDocument() throws -> PDFDocument {
    guard let document = session?.document else {
      throw PdfPocError.documentNotOpen()
    }
    return document
  }

  private func requireSelection() throws -> PDFSelection {
    guard let selection = pdfView.currentSelection,
          let text = selection.string,
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PdfPocError(
        code: "no_text_selection",
        message: "Select PDF text before annotating.",
        details: nil
      )
    }
    return selection
  }

  private func documentInfo() -> PdfDocumentInfo {
    guard let session else {
      return PdfDocumentInfo(
        workingPath: "",
        pageCount: 0,
        currentPageIndex: 0,
        hasSearchableText: false,
        isDirty: false
      )
    }
    return PdfDocumentInfo(
      workingPath: session.workingURL.path,
      pageCount: Int64(session.document.pageCount),
      currentPageIndex: currentPageIndex(),
      hasSearchableText: hasSearchableText(session.document),
      isDirty: session.isDirty
    )
  }

  private func currentPageIndex() -> Int64 {
    guard let document = session?.document,
          let page = pdfView.currentPage else {
      return 0
    }
    return Int64(document.index(for: page))
  }

  private func notifyPageChanged() {
    guard let document = session?.document else { return }
    logPdfEvent(
      "page_changed",
      "pageIndex=\(currentPageIndex()) pageCount=\(document.pageCount)"
    )
    delegate?.workspaceView(
      self,
      didChangePage: currentPageIndex(),
      pageCount: Int64(document.pageCount)
    )
  }

  private func markDirty() {
    session?.isDirty = true
    logPdfEvent("dirty_state_changed", "isDirty=true")
    delegate?.workspaceView(self, didChangeDirtyState: true)
  }

  private func logPageChangedFromObserver() {
    logPdfEvent("page_changed_notification")
    notifyPageChanged()
  }

  private func configureSelectionToolbar() {
    selectionToolbar.isHidden = true
    selectionToolbar.onCopy = { [weak self] in
      guard let self else { return }
      do {
        try self.copySelectedText()
      } catch let error as PdfPocError {
        self.delegate?.workspaceView(self, didFailOperation: "selection toolbar", error: error)
      } catch {
        self.reportSelectionToolbarError(error)
      }
    }
    selectionToolbar.onMarkup = { [weak self] type in
      guard let self else { return }
      do {
        try self.addMarkupFromCurrentSelection(type)
      } catch let error as PdfPocError {
        self.delegate?.workspaceView(self, didFailOperation: "selection toolbar", error: error)
      } catch {
        self.reportSelectionToolbarError(error)
      }
    }
  }

  private func reportSelectionToolbarError(_ error: Error) {
    delegate?.workspaceView(
      self,
      didFailOperation: "selection toolbar",
      error: PdfPocError(
        code: "internal_error",
        message: "Selection toolbar operation failed.",
        details: error.localizedDescription
      )
    )
  }

  private func updateSelectionToolbar() {
    hideSystemSelectionMenu()
    hideSelectionToolbar()
  }

  private func hideSelectionToolbar() {
    selectionToolbarTargetRect = nil
    selectionToolbar.isHidden = true
  }

  private func hideSystemSelectionMenu() {
    pdfView.suppressSystemSelectionMenu()
    UIMenuController.shared.hideMenu()
    DispatchQueue.main.async {
      UIMenuController.shared.hideMenu()
    }
  }

  private func selectionRectInWorkspace(for selection: PDFSelection) -> CGRect? {
    var unionRect = CGRect.null
    for page in selection.pages {
      let pageBounds = selection.bounds(for: page)
      guard pageBounds.width > 0, pageBounds.height > 0 else {
        continue
      }
      let pdfViewRect = pdfView.convert(pageBounds, from: page)
      let workspaceRect = pdfView.convert(pdfViewRect, to: self)
      unionRect = unionRect.union(workspaceRect)
    }
    return unionRect.isNull ? nil : unionRect
  }

  private func layoutSelectionToolbar() {
    guard !selectionToolbar.isHidden,
          let targetRect = selectionToolbarTargetRect else {
      return
    }

    let margin: CGFloat = 8
    let gap: CGFloat = 8
    let desiredSize = selectionToolbar.systemLayoutSizeFitting(
      UIView.layoutFittingCompressedSize
    )
    let toolbarWidth = min(desiredSize.width, max(bounds.width - margin * 2, 0))
    let toolbarHeight = desiredSize.height
    let minX = margin
    let maxX = max(bounds.width - toolbarWidth - margin, minX)
    let x = clamp(targetRect.midX - toolbarWidth / 2, minX, maxX)

    let topY = targetRect.minY - toolbarHeight - gap
    let bottomY = targetRect.maxY + gap
    let minY = margin
    let maxY = max(bounds.height - toolbarHeight - margin, minY)
    let y: CGFloat
    if topY >= minY {
      y = topY
    } else if bottomY <= maxY {
      y = bottomY
    } else {
      y = clamp(topY, minY, maxY)
    }

    selectionToolbar.frame = CGRect(
      x: x,
      y: y,
      width: toolbarWidth,
      height: toolbarHeight
    )
  }

  private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
    min(max(value, lower), upper)
  }

  private func annotationSubtype(for type: PdfMarkupType) -> PDFAnnotationSubtype {
    switch type {
    case .highlight:
      return .highlight
    case .underline:
      return .underline
    case .strikeout:
      return .strikeOut
    }
  }

  private func annotationColor(for type: PdfMarkupType) -> UIColor {
    switch type {
    case .highlight:
      return UIColor.systemYellow.withAlphaComponent(0.5)
    case .underline:
      return UIColor.systemBlue.withAlphaComponent(0.9)
    case .strikeout:
      return UIColor.systemRed.withAlphaComponent(0.9)
    }
  }

  private func hasSearchableText(_ document: PDFDocument) -> Bool {
    for index in 0..<document.pageCount {
      if let text = document.page(at: index)?.string,
         !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return true
      }
    }
    return false
  }

  private func showActiveSearchResult() {
    guard activeSearchIndex >= 0, activeSearchIndex < searchSelections.count else {
      return
    }
    let selection = searchSelections[activeSearchIndex]
    pdfView.setCurrentSelection(selection, animate: true)
    pdfView.go(to: selection)
    notifyPageChanged()
  }

  private func clearSearchOnly() {
    searchSelections = []
    searchQuery = ""
    activeSearchIndex = -1
    pdfView.setCurrentSelection(nil, animate: false)
  }

  private func searchState() -> PdfSearchState {
    let activeText: String?
    if activeSearchIndex >= 0, activeSearchIndex < searchSelections.count {
      activeText = searchSelections[activeSearchIndex].string
    } else {
      activeText = nil
    }
    return PdfSearchState(
      query: searchQuery,
      totalResults: Int64(searchSelections.count),
      activeResultIndex: Int64(activeSearchIndex),
      activeResultText: activeText
    )
  }

  private func currentSelectionText() -> String? {
    pdfView.currentSelection?.string
  }

  private func ensureMainThread() throws {
    guard Thread.isMainThread else {
      throw PdfPocError(
        code: "internal_error",
        message: "PDFKit and UIKit operations must run on the main thread.",
        details: nil
      )
    }
  }
}

private final class PocPdfView: PDFView {
  override var canBecomeFirstResponder: Bool {
    true
  }

  override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
    if hasTextSelection {
      return false
    }
    return super.canPerformAction(action, withSender: sender)
  }

  func suppressSystemSelectionMenu() {
    _ = becomeFirstResponder()
    UIMenuController.shared.hideMenu()
    UIMenuSystem.main.setNeedsRebuild()
  }

  private var hasTextSelection: Bool {
    guard let text = currentSelection?.string else {
      return false
    }
    return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

private final class PdfSelectionToolbar: UIView {
  var onCopy: (() -> Void)?
  var onMarkup: ((PdfMarkupType) -> Void)?

  private let stackView = UIStackView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    configure()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configure()
  }

  private func configure() {
    backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.98)
    layer.cornerRadius = 12
    layer.borderColor = UIColor.separator.cgColor
    layer.borderWidth = 1
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = 0.18
    layer.shadowRadius = 10
    layer.shadowOffset = CGSize(width: 0, height: 4)

    stackView.axis = .horizontal
    stackView.alignment = .center
    stackView.distribution = .fill
    stackView.spacing = 4
    stackView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stackView)

    NSLayoutConstraint.activate([
      stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
      stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      stackView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
      stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
    ])

    addButton(title: "Copy", action: #selector(copyTapped))
    addDivider()
    addButton(title: "Highlight", action: #selector(highlightTapped))
    addButton(title: "Underline", action: #selector(underlineTapped))
    addButton(title: "Strikeout", action: #selector(strikeoutTapped))
  }

  private func addButton(title: String, action: Selector) {
    let button = UIButton(type: .system)
    button.setTitle(title, for: .normal)
    button.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
    button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
    button.addTarget(self, action: action, for: .touchUpInside)
    stackView.addArrangedSubview(button)
  }

  private func addDivider() {
    let divider = UIView()
    divider.backgroundColor = .separator
    divider.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      divider.widthAnchor.constraint(equalToConstant: 1),
      divider.heightAnchor.constraint(equalToConstant: 22),
    ])
    stackView.addArrangedSubview(divider)
  }

  @objc private func copyTapped() {
    onCopy?()
  }

  @objc private func highlightTapped() {
    onMarkup?(.highlight)
  }

  @objc private func underlineTapped() {
    onMarkup?(.underline)
  }

  @objc private func strikeoutTapped() {
    onMarkup?(.strikeout)
  }
}

extension PdfWorkspaceView: UIGestureRecognizerDelegate {
  override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    if gestureRecognizer === freeTextAreaPanGesture {
      return isSelectingFreeTextArea
    }
    return true
  }
}

private final class PdfDocumentSession {
  let assetKey: String
  let workingURL: URL
  let document: PDFDocument
  var isDirty: Bool

  init(assetKey: String, workingURL: URL, document: PDFDocument, isDirty: Bool = false) {
    self.assetKey = assetKey
    self.workingURL = workingURL
    self.document = document
    self.isDirty = isDirty
  }
}

private extension UIColor {
  convenience init(argb: Int64) {
    let alpha = CGFloat((argb >> 24) & 0xFF) / 255.0
    let red = CGFloat((argb >> 16) & 0xFF) / 255.0
    let green = CGFloat((argb >> 8) & 0xFF) / 255.0
    let blue = CGFloat(argb & 0xFF) / 255.0
    self.init(red: red, green: green, blue: blue, alpha: alpha)
  }
}
