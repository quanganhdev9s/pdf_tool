import Foundation
import UIKit
import UniformTypeIdentifiers
import WebKit

/// Owns "convert any supported file to PDF": document-picker presentation,
/// source-format routing, WebKit rendering for document sources, cancellation,
/// and handoff to the writers. Picked files never travel over Pigeon; only the
/// generated PDF path is published back to Flutter.
final class PdfFileConversionManager: NSObject {
  var onProgress: ((String, Int64, Int64) -> Void)?
  var onCompleted: ((String, PdfConvertToPdfResult?, Bool) -> Void)?
  var onError: ((String, PdfPocError) -> Void)?
  var onGeneratedDocumentReady: ((URL) -> Void)?

  /// Formats WebKit can render on iOS, plus images handled by the scanned-PDF
  /// writer. PDF inputs are intentionally excluded: converting them is a no-op.
  static var supportedContentTypes: [UTType] {
    var types: [UTType] = [.plainText, .rtf, .html, .commaSeparatedText, .image]
    let identifiers = [
      "org.openxmlformats.wordprocessingml.document",
      "com.microsoft.word.doc",
      "org.openxmlformats.spreadsheetml.sheet",
      "com.microsoft.excel.xls",
      "org.openxmlformats.presentationml.presentation",
      "com.microsoft.powerpoint.ppt",
      "com.apple.iwork.pages.pages",
      "com.apple.iwork.numbers.numbers",
      "com.apple.iwork.keynote.key",
    ]
    types.append(contentsOf: identifiers.compactMap(UTType.init))
    return types
  }

  private let workQueue = DispatchQueue(label: "pdf.poc.file_conversion", qos: .userInitiated)
  private let convertedWriter = PdfConvertedDocumentWriter()
  private let imageWriter = PdfImageDocumentWriter()
  private let stateLock = NSLock()
  private let renderTimeout: TimeInterval = 60
  private var activeOperationId: String?
  private var activeRequest: PdfConvertToPdfRequest?
  private var activeOutputDirectory: URL?
  private var activeStartedAt: Date?
  /// Resolved once per operation so the render callback never has to recompute
  /// it, and so URL sources (which have no picked file) work the same way.
  private var activeOutputURL: URL?
  private var activePageSize: PdfConvertPageSize = .a4
  private var activeSourceName: String?
  private var activeSourceFormat: String?
  private weak var activePresenter: UIViewController?
  private weak var activeController: UIViewController?
  private var cancelledOperationIds = Set<String>()
  private var renderWebView: WKWebView?
  private var renderTimeoutWorkItem: DispatchWorkItem?

  func pickFile(
    request: PdfConvertToPdfRequest,
    outputDirectory: URL,
    presenter: UIViewController
  ) throws {
    guard Thread.isMainThread else {
      throw PdfPocError(
        code: "internal_error",
        message: "Document picker presentation must run on the main thread.",
        details: nil
      )
    }
    guard activeOperationId == nil else {
      throw PdfPocError(
        code: "operation_in_progress",
        message: "A PDF conversion is already running.",
        details: nil
      )
    }

    let operationId = UUID().uuidString
    setActive(
      operationId: operationId,
      request: request,
      outputDirectory: outputDirectory,
      presenter: presenter
    )
    let picker = UIDocumentPickerViewController(
      forOpeningContentTypes: Self.supportedContentTypes,
      asCopy: true
    )
    picker.delegate = self
    picker.allowsMultipleSelection = false
    activeController = picker
    logPdfEvent(
      "convert_pick_present",
      "operationId=\(operationId) outputDir=\(outputDirectory.path) pageSize=\(request.pageSize)"
    )
    presenter.present(picker, animated: true)
  }

  /// Renders a web page into a PDF through the same WebKit print pipeline used
  /// for document files. Only http and https are accepted.
  func convertUrl(
    request: PdfConvertUrlRequest,
    outputDirectory: URL,
    presenter: UIViewController
  ) throws {
    guard Thread.isMainThread else {
      throw PdfPocError(
        code: "internal_error",
        message: "URL conversion must start on the main thread.",
        details: nil
      )
    }
    guard activeOperationId == nil else {
      throw PdfPocError(
        code: "operation_in_progress",
        message: "A PDF conversion is already running.",
        details: nil
      )
    }
    let sourceURL = try normalizedWebURL(request.url)

    let operationId = UUID().uuidString
    setActive(
      operationId: operationId,
      request: PdfConvertToPdfRequest(
        outputPath: request.outputPath,
        pageSize: request.pageSize,
        imageQuality: .standard
      ),
      outputDirectory: outputDirectory,
      presenter: presenter
    )
    activePageSize = request.pageSize
    activeSourceName = sourceURL.host ?? sourceURL.absoluteString
    activeSourceFormat = "url"
    activeOutputURL = webOutputURL(
      for: sourceURL,
      requestedPath: request.outputPath,
      outputDirectory: outputDirectory
    )

    logPdfEvent(
      "convert_url_request",
      "operationId=\(operationId) url=\(sourceURL.absoluteString) pageSize=\(request.pageSize)"
    )
    startWebRender(operationId: operationId, presenter: presenter) { webView in
      webView.load(URLRequest(url: sourceURL))
    }
  }

  func cancel() {
    stateLock.lock()
    let operationId = activeOperationId
    if let operationId {
      cancelledOperationIds.insert(operationId)
      logPdfEvent("convert_cancel_requested", "operationId=\(operationId)")
    }
    stateLock.unlock()
    DispatchQueue.main.async { [weak self] in
      self?.activeController?.dismiss(animated: true)
      self?.teardownRenderWebView()
    }
  }

  private func handlePickedFile(_ sourceURL: URL) {
    guard let operationId = activeOperationId,
          let request = activeRequest,
          let outputDirectory = activeOutputDirectory else {
      return
    }
    let outputURL = outputURL(for: sourceURL, request: request, outputDirectory: outputDirectory)
    activeOutputURL = outputURL
    activePageSize = request.pageSize
    activeSourceName = sourceURL.lastPathComponent
    activeSourceFormat = sourceURL.pathExtension.lowercased()
    logPdfEvent(
      "convert_pick_finished",
      "operationId=\(operationId) source=\(sourceURL.lastPathComponent) output=\(outputURL.path)"
    )
    // `UIDocumentPickerViewController` dismisses itself once a file is picked,
    // so conversion only has to wait for that transition to settle.
    DispatchQueue.main.async { [weak self] in
      self?.convert(sourceURL: sourceURL, operationId: operationId, request: request, outputURL: outputURL)
    }
  }

  private func convert(
    sourceURL: URL,
    operationId: String,
    request: PdfConvertToPdfRequest,
    outputURL: URL
  ) {
    if isImage(sourceURL) {
      convertImage(sourceURL: sourceURL, operationId: operationId, request: request, outputURL: outputURL)
    } else {
      convertDocument(sourceURL: sourceURL, operationId: operationId, request: request, outputURL: outputURL)
    }
  }

  private func convertImage(
    sourceURL: URL,
    operationId: String,
    request: PdfConvertToPdfRequest,
    outputURL: URL
  ) {
    workQueue.async { [weak self] in
      guard let self else { return }
      do {
        let pageCount = try self.imageWriter.write(
          imageFileURLs: [sourceURL],
          quality: request.imageQuality,
          outputURL: outputURL,
          operationId: operationId,
          isCancelled: { self.isCancelled(operationId) },
          onProgress: { completedPages, totalPages in
            DispatchQueue.main.async {
              self.onProgress?(operationId, completedPages, totalPages)
            }
          }
        )
        self.publish(operationId: operationId, outputURL: outputURL, pageCount: pageCount)
      } catch let error as PdfPocError {
        try? FileManager.default.removeItem(at: outputURL)
        if error.code == "image_pdf_cancelled" {
          DispatchQueue.main.async {
            self.finish(operationId: operationId, result: nil, cancelled: true)
          }
        } else {
          self.fail(operationId: operationId, error: error)
        }
      } catch {
        try? FileManager.default.removeItem(at: outputURL)
        self.fail(
          operationId: operationId,
          error: PdfPocError(
            code: "conversion_failed",
            message: "Image to PDF conversion failed.",
            details: error.localizedDescription
          )
        )
      }
    }
  }

  /// Document sources (Office, iWork, RTF, HTML, text) are rendered by WebKit,
  /// which is the only iOS-native renderer that understands those formats. The
  /// web view must live in the hierarchy and finish loading before its print
  /// formatter can paginate the content.
  private func convertDocument(
    sourceURL: URL,
    operationId: String,
    request: PdfConvertToPdfRequest,
    outputURL: URL
  ) {
    guard let presenter = activePresenter else {
      fail(
        operationId: operationId,
        error: PdfPocError(
          code: "internal_error",
          message: "Could not find a UIKit host for the conversion renderer.",
          details: nil
        )
      )
      return
    }
    logPdfEvent(
      "convert_render_start",
      "operationId=\(operationId) source=\(sourceURL.lastPathComponent)"
    )
    startWebRender(operationId: operationId, presenter: presenter) { webView in
      webView.loadFileURL(
        sourceURL,
        allowingReadAccessTo: sourceURL.deletingLastPathComponent()
      )
    }
  }

  /// Creates the hidden render web view, arms the timeout, then hands the view
  /// to the caller-supplied load step.
  private func startWebRender(
    operationId: String,
    presenter: UIViewController,
    load: (WKWebView) -> Void
  ) {
    let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 612, height: 792))
    webView.navigationDelegate = self
    webView.isUserInteractionEnabled = false
    webView.alpha = 0
    presenter.view.insertSubview(webView, at: 0)
    renderWebView = webView

    let timeoutWorkItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.teardownRenderWebView()
      self.fail(
        operationId: operationId,
        error: PdfPocError(
          code: "conversion_timeout",
          message: "The source took too long to render.",
          details: "timeoutSeconds=\(Int(self.renderTimeout))"
        )
      )
    }
    renderTimeoutWorkItem = timeoutWorkItem
    DispatchQueue.main.asyncAfter(deadline: .now() + renderTimeout, execute: timeoutWorkItem)

    load(webView)
  }

  private func renderLoadedDocument(_ webView: WKWebView) {
    guard let operationId = activeOperationId,
          let outputURL = activeOutputURL else {
      teardownRenderWebView()
      return
    }
    if isCancelled(operationId) {
      teardownRenderWebView()
      finish(operationId: operationId, result: nil, cancelled: true)
      return
    }

    let printFormatter = webView.viewPrintFormatter()
    do {
      let pageCount = try convertedWriter.write(
        printFormatter: printFormatter,
        pageSize: activePageSize,
        outputURL: outputURL,
        operationId: operationId,
        isCancelled: { self.isCancelled(operationId) },
        onProgress: { [weak self] completedPages, totalPages in
          self?.onProgress?(operationId, completedPages, totalPages)
        }
      )
      teardownRenderWebView()
      publish(
        operationId: operationId,
        outputURL: outputURL,
        pageCount: pageCount
      )
    } catch let error as PdfPocError {
      teardownRenderWebView()
      try? FileManager.default.removeItem(at: outputURL)
      if error.code == "conversion_cancelled" {
        finish(operationId: operationId, result: nil, cancelled: true)
      } else {
        fail(operationId: operationId, error: error)
      }
    } catch {
      teardownRenderWebView()
      try? FileManager.default.removeItem(at: outputURL)
      fail(
        operationId: operationId,
        error: PdfPocError(
          code: "conversion_failed",
          message: "Converted PDF generation failed.",
          details: error.localizedDescription
        )
      )
    }
  }

  private func publish(
    operationId: String,
    outputURL: URL,
    pageCount: Int
  ) {
    let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
    let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    let startedAt = activeStartedAt ?? Date()
    let result = PdfConvertToPdfResult(
      outputPath: outputURL.path,
      sourceFileName: activeSourceName ?? outputURL.lastPathComponent,
      sourceFormat: activeSourceFormat ?? outputURL.pathExtension.lowercased(),
      pageCount: Int64(pageCount),
      fileSizeBytes: fileSize,
      durationMilliseconds: Int64(Date().timeIntervalSince(startedAt) * 1000)
    )
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.onGeneratedDocumentReady?(outputURL)
      self.finish(operationId: operationId, result: result, cancelled: false)
    }
  }

  private func userCancelled() {
    guard let operationId = activeOperationId else {
      return
    }
    logPdfEvent("convert_pick_user_cancelled", "operationId=\(operationId)")
    finish(operationId: operationId, result: nil, cancelled: true)
  }

  private func outputURL(
    for sourceURL: URL,
    request: PdfConvertToPdfRequest,
    outputDirectory: URL
  ) -> URL {
    let requestedPath = request.outputPath.trimmingCharacters(in: .whitespacesAndNewlines)
    if !requestedPath.isEmpty {
      return URL(fileURLWithPath: requestedPath)
    }
    let baseName = sourceURL.deletingPathExtension().lastPathComponent
    let stamp = Int(Date().timeIntervalSince1970)
    return outputDirectory.appendingPathComponent("\(baseName)_converted_\(stamp).pdf")
  }

  private func normalizedWebURL(_ raw: String) throws -> URL {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw PdfPocError(
        code: "invalid_url",
        message: "Enter a web address before converting.",
        details: nil
      )
    }
    let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard let url = URL(string: candidate),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          url.host?.isEmpty == false else {
      throw PdfPocError(
        code: "invalid_url",
        message: "Only http and https web addresses can be converted.",
        details: trimmed
      )
    }
    return url
  }

  private func webOutputURL(
    for sourceURL: URL,
    requestedPath: String,
    outputDirectory: URL
  ) -> URL {
    let trimmed = requestedPath.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
      return URL(fileURLWithPath: trimmed)
    }
    let host = (sourceURL.host ?? "web")
      .replacingOccurrences(of: ".", with: "_")
    let stamp = Int(Date().timeIntervalSince1970)
    return outputDirectory.appendingPathComponent("\(host)_web_\(stamp).pdf")
  }

  private func isImage(_ sourceURL: URL) -> Bool {
    guard let type = UTType(filenameExtension: sourceURL.pathExtension) else {
      return false
    }
    return type.conforms(to: .image)
  }

  private func teardownRenderWebView() {
    renderTimeoutWorkItem?.cancel()
    renderTimeoutWorkItem = nil
    renderWebView?.navigationDelegate = nil
    renderWebView?.stopLoading()
    renderWebView?.removeFromSuperview()
    renderWebView = nil
  }

  private func setActive(
    operationId: String,
    request: PdfConvertToPdfRequest,
    outputDirectory: URL,
    presenter: UIViewController
  ) {
    stateLock.lock()
    activeOperationId = operationId
    activeRequest = request
    activeOutputDirectory = outputDirectory
    activeStartedAt = Date()
    activePresenter = presenter
    cancelledOperationIds.remove(operationId)
    stateLock.unlock()
  }

  private func clearActive(_ operationId: String) {
    if activeOperationId == operationId {
      activeOperationId = nil
      activeRequest = nil
      activeOutputDirectory = nil
      activeStartedAt = nil
      activeOutputURL = nil
      activeSourceName = nil
      activeSourceFormat = nil
      activePresenter = nil
      activeController = nil
    }
    cancelledOperationIds.remove(operationId)
  }

  private func isCancelled(_ operationId: String) -> Bool {
    stateLock.lock()
    let cancelled = cancelledOperationIds.contains(operationId) || activeOperationId != operationId
    stateLock.unlock()
    return cancelled
  }

  private func finish(operationId: String, result: PdfConvertToPdfResult?, cancelled: Bool) {
    stateLock.lock()
    guard activeOperationId == operationId || cancelled else {
      stateLock.unlock()
      return
    }
    clearActive(operationId)
    stateLock.unlock()
    logPdfEvent(
      "convert_completed",
      "operationId=\(operationId) cancelled=\(cancelled) output=\(result?.outputPath ?? "")"
    )
    onCompleted?(operationId, result, cancelled)
  }

  private func fail(operationId: String, error: PdfPocError) {
    stateLock.lock()
    clearActive(operationId)
    stateLock.unlock()
    logPdfEvent(
      "convert_failed",
      "operationId=\(operationId) code=\(error.code) message=\(error.message)"
    )
    DispatchQueue.main.async {
      self.onError?(operationId, error)
    }
  }
}

extension PdfFileConversionManager: UIDocumentPickerDelegate {
  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    guard let sourceURL = urls.first else {
      userCancelled()
      return
    }
    handlePickedFile(sourceURL)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    userCancelled()
  }
}

extension PdfFileConversionManager: WKNavigationDelegate {
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    renderTimeoutWorkItem?.cancel()
    // WebKit reports `didFinish` before Office/iWork previews have laid out, so
    // the print formatter needs one more runloop turn to see the full content.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
      guard let self, self.renderWebView === webView else { return }
      self.renderLoadedDocument(webView)
    }
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    handleRenderFailure(error)
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    handleRenderFailure(error)
  }

  private func handleRenderFailure(_ error: Error) {
    guard let operationId = activeOperationId else {
      teardownRenderWebView()
      return
    }
    teardownRenderWebView()
    fail(
      operationId: operationId,
      error: PdfPocError(
        code: "unsupported_source_format",
        message: "The selected file could not be rendered for PDF conversion.",
        details: error.localizedDescription
      )
    )
  }
}
