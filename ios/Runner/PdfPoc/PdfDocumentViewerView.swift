import Flutter
import Foundation
import UIKit
import WebKit

final class PdfDocumentViewerPlatformViewFactory: NSObject, FlutterPlatformViewFactory {
  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    PdfDocumentViewerPlatformView(frame: frame)
  }
}

final class PdfDocumentViewerPlatformView: NSObject, FlutterPlatformView {
  private let viewerView: PdfDocumentViewerView

  init(frame: CGRect) {
    viewerView = PdfDocumentViewerView(frame: frame)
    super.init()
    PdfPocRuntime.shared.attach(documentViewerView: viewerView)
  }

  deinit {
    PdfPocRuntime.shared.detach(documentViewerView: viewerView)
  }

  func view() -> UIView {
    viewerView
  }
}

/// Renders a picked Office, iWork, or PDF file inside the Flutter layout with
/// `WKWebView`, the only native iOS renderer that understands those formats.
///
/// Unlike `QLPreviewController` this brings no system chrome, so Flutter owns
/// the whole screen: app bar, toolbars, and any controls around the document.
final class PdfDocumentViewerView: UIView {
  private let webView: WKWebView
  private let activityIndicator = UIActivityIndicatorView(style: .large)
  private let messageLabel = UILabel()
  private var loadedURL: URL?

  override init(frame: CGRect) {
    let configuration = WKWebViewConfiguration()
    webView = WKWebView(frame: frame, configuration: configuration)
    super.init(frame: frame)
    configureSubviews()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    webView.frame = bounds
    activityIndicator.center = CGPoint(x: bounds.midX, y: bounds.midY)
    messageLabel.frame = bounds.insetBy(dx: 24, dy: 24)
  }

  func load(path: String) throws {
    let sourceURL = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: sourceURL.path) else {
      throw PdfPocError(
        code: "asset_not_found",
        message: "The document to view no longer exists.",
        details: path
      )
    }
    loadedURL = sourceURL
    showMessage(nil)
    activityIndicator.startAnimating()
    logPdfEvent("document_viewer_load", "file=\(sourceURL.lastPathComponent)")
    webView.loadFileURL(
      sourceURL,
      allowingReadAccessTo: sourceURL.deletingLastPathComponent()
    )
  }

  /// Removes the local copy taken by the picker. The viewer owns that copy, so
  /// nothing of the user's original file is touched.
  func close() {
    logPdfEvent("document_viewer_close", "file=\(loadedURL?.lastPathComponent ?? "")")
    webView.stopLoading()
    webView.loadHTMLString("", baseURL: nil)
    activityIndicator.stopAnimating()
    if let loadedURL {
      try? FileManager.default.removeItem(at: loadedURL)
    }
    loadedURL = nil
  }

  private func configureSubviews() {
    backgroundColor = .systemBackground
    webView.navigationDelegate = self
    webView.backgroundColor = .systemBackground
    addSubview(webView)

    activityIndicator.hidesWhenStopped = true
    addSubview(activityIndicator)

    messageLabel.numberOfLines = 0
    messageLabel.textAlignment = .center
    messageLabel.textColor = .secondaryLabel
    messageLabel.isHidden = true
    addSubview(messageLabel)
  }

  private func showMessage(_ text: String?) {
    messageLabel.text = text
    messageLabel.isHidden = text == nil
    webView.isHidden = text != nil
  }
}

extension PdfDocumentViewerView: WKNavigationDelegate {
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    activityIndicator.stopAnimating()
    logPdfEvent("document_viewer_loaded", "file=\(loadedURL?.lastPathComponent ?? "")")
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    handleFailure(error)
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    handleFailure(error)
  }

  private func handleFailure(_ error: Error) {
    activityIndicator.stopAnimating()
    logPdfEvent("document_viewer_failed", "error=\(error.localizedDescription)")
    showMessage("This file could not be displayed.\n\(error.localizedDescription)")
  }
}
