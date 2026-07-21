import Foundation
import PDFKit
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
  private let selectionToolbar = PdfSelectionToolbar()
  private lazy var searchManager = PdfSearchManager(pdfView: pdfView)
  private lazy var inkManager = PdfInkManager(pdfView: pdfView)
  private lazy var freeTextManager = PdfFreeTextManager(pdfView: pdfView)
  private lazy var signatureManager = PdfSignatureManager(pdfView: pdfView)
  private var session: PdfDocumentSession?
  private var pageChangedObserver: NSObjectProtocol?
  private var selectionChangedObserver: NSObjectProtocol?
  private var selectionToolbarTargetRect: CGRect?
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
    inkManager.layout(frame: pdfView.frame, contentSize: pdfView.bounds.size)
    signatureManager.layout(pdfFrame: pdfView.frame)
    freeTextManager.layout(frame: pdfView.frame)
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
    searchManager.clear()

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
    searchManager.clear()
    hideSelectionToolbar()
    freeTextManager.cancelSelection()
    inkManager.close()
    annotationTapGesture.isEnabled = true
    signatureManager.close()
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
    let state = try searchManager.search(request, in: document)
    if state.activeResultIndex >= 0 {
      notifyPageChanged()
    }
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
    let state = searchManager.goToNextResult()
    if state.activeResultIndex >= 0 {
      notifyPageChanged()
    }
    delegate?.workspaceView(self, didChangeSearchState: state)
    return state
  }

  func goToPreviousSearchResult() throws -> PdfSearchState {
    try ensureMainThread()
    logPdfEvent("go_to_previous_search_result_request")
    let state = searchManager.goToPreviousResult()
    if state.activeResultIndex >= 0 {
      notifyPageChanged()
    }
    delegate?.workspaceView(self, didChangeSearchState: state)
    return state
  }

  func clearSearch() throws {
    try ensureMainThread()
    logPdfEvent("clear_search")
    searchManager.clear()
    delegate?.workspaceView(self, didChangeSearchState: searchManager.state())
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
    hideSelectionToolbar()
    hideSystemSelectionMenu()
    // This only captures the target rect. Flutter owns the keyboard/text input
    // and will call addFreeText after the user submits text.
    freeTextManager.beginSelection(in: self)
  }

  func setInkModeEnabled(_ enabled: Bool) throws {
    try ensureMainThread()
    _ = try requireDocument()
    logPdfEvent("set_ink_mode", "enabled=\(enabled)")
    if enabled {
      freeTextManager.cancelSelection()
      hideSelectionToolbar()
      hideSystemSelectionMenu()
    }
    inkManager.setModeEnabled(enabled)
    annotationTapGesture.isEnabled = !enabled
    if enabled {
      bringSubviewToFront(inkManager.canvasView)
    }
  }

  func clearCurrentInkInput() throws {
    try ensureMainThread()
    _ = try requireDocument()
    inkManager.clearCurrentInput()
  }

  func commitCurrentInkToPdf() throws {
    try ensureMainThread()
    _ = try requireDocument()
    _ = try inkManager.commitCurrentInkToPdf()
    markDirty()
  }

  func deleteSelectedAnnotation() throws {
    try ensureMainThread()
    _ = try requireDocument()
    try inkManager.deleteSelectedAnnotation()
    markDirty()
  }

  func captureElectronicSignature() throws {
    try ensureMainThread()
    _ = try requireDocument()
    freeTextManager.cancelSelection()
    hideSelectionToolbar()
    hideSystemSelectionMenu()
    inkManager.setModeEnabled(false)
    annotationTapGesture.isEnabled = true
    signatureManager.capture(in: self)
  }

  func clearElectronicSignatureCapture() throws {
    try ensureMainThread()
    _ = try requireDocument()
    signatureManager.clearCapture()
  }

  func confirmElectronicSignatureCapture() throws {
    try ensureMainThread()
    _ = try requireDocument()
    try signatureManager.confirmCapture()
  }

  func beginSignaturePlacement() throws {
    try ensureMainThread()
    _ = try requireDocument()
    freeTextManager.cancelSelection()
    hideSelectionToolbar()
    hideSystemSelectionMenu()
    inkManager.setModeEnabled(false)
    annotationTapGesture.isEnabled = true
    try signatureManager.beginPlacement(in: self, currentPageIndex: currentPageIndex())
  }

  func resizeSignaturePlacement(_ scale: CGFloat) throws {
    try ensureMainThread()
    _ = try requireDocument()
    try signatureManager.resizePlacement(scale, containerBounds: bounds)
  }

  func commitSignaturePlacement() throws {
    try ensureMainThread()
    _ = try requireDocument()
    try signatureManager.commitPlacement(in: self)
    markDirty()
  }

  func cancelSignaturePlacement() throws {
    try ensureMainThread()
    _ = try requireDocument()
    signatureManager.cancelPlacement()
  }

  func deleteSelectedSignature() throws {
    try ensureMainThread()
    _ = try requireDocument()
    try signatureManager.deleteSelectedSignature()
    markDirty()
  }

  func exportFlattenedCopy() throws -> PdfExportResult {
    try ensureMainThread()
    guard let session else {
      throw PdfPocError.documentNotOpen()
    }
    let outputURL = flattenedOutputURL(for: session.workingURL)
    logPdfEvent("export_flattened_start", "path=\(outputURL.path)")
    let result = try PdfFlattenedExporter().export(document: session.document, to: outputURL)
    logPdfEvent(
      "export_flattened_success",
      "path=\(result.outputPath) pages=\(result.pageCount) bytes=\(result.fileSizeBytes)"
    )
    return result
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
    configureSelectionToolbar()
    configureFreeTextAreaSelection()
    pdfView.addGestureRecognizer(annotationTapGesture)
    addSubview(inkManager.canvasView)
    addSubview(signatureManager.captureView)
    addSubview(signatureManager.placementView)
    addSubview(selectionToolbar)
    NSLayoutConstraint.activate([
      pdfView.leadingAnchor.constraint(equalTo: leadingAnchor),
      pdfView.trailingAnchor.constraint(equalTo: trailingAnchor),
      pdfView.topAnchor.constraint(equalTo: topAnchor),
      pdfView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  private func configureFreeTextAreaSelection() {
    addSubview(freeTextManager.captureView)
    addSubview(freeTextManager.overlayView)
    freeTextManager.onSelection = { [weak self] selection in
      guard let self else { return }
      self.delegate?.workspaceView(self, didSelectFreeTextArea: selection)
    }
    freeTextManager.onError = { [weak self] error in
      guard let self else { return }
      self.delegate?.workspaceView(self, didFailOperation: "free-text area", error: error)
    }
  }

  @objc private func handleAnnotationTap(_ recognizer: UITapGestureRecognizer) {
    guard !inkManager.isEnabled, recognizer.state == .ended else { return }
    let point = recognizer.location(in: pdfView)
    guard let page = pdfView.page(for: point, nearest: false) else {
      inkManager.clearSelection()
      logPdfEvent("annotation_tap_no_page", "point=\(point)")
      return
    }
    let pagePoint = pdfView.convert(point, to: page)
    guard let annotation = page.annotation(at: pagePoint) else {
      inkManager.clearSelection()
      signatureManager.clearSelection()
      logPdfEvent("annotation_tap_no_annotation", "point=\(pagePoint)")
      return
    }
    if signatureManager.isElectronicSignatureAnnotation(annotation) {
      inkManager.clearSelection()
      signatureManager.select(annotation: annotation, page: page)
      return
    }
    guard annotation.type == PDFAnnotationSubtype.ink.rawValue else {
      inkManager.clearSelection()
      signatureManager.clearSelection()
      logPdfEvent("annotation_tap_unsupported", "type=\(annotation.type ?? "nil")")
      return
    }
    signatureManager.clearSelection()
    inkManager.selectInkAnnotation(annotation, page: page)
  }

  private func flattenedOutputURL(for workingURL: URL) -> URL {
    let baseName = workingURL.deletingPathExtension().lastPathComponent
    return workingURL.deletingLastPathComponent()
      .appendingPathComponent("\(baseName)_flattened.pdf")
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
      hasSearchableText: PdfSearchManager.hasSearchableText(session.document),
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
    guard let selection = pdfView.currentSelection,
          let text = selection.string,
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let targetRect = selectionRectInWorkspace(for: selection) else {
      hideSelectionToolbar()
      return
    }
    selectionToolbarTargetRect = targetRect
    selectionToolbar.isHidden = false
    bringSubviewToFront(selectionToolbar)
    layoutSelectionToolbar()
    logPdfEvent("selection_toolbar_show", "target=\(targetRect)")
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
