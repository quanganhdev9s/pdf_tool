import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let applicationRegistrar = engineBridge.applicationRegistrar
    PdfPocRuntime.shared.configure(binaryMessenger: applicationRegistrar.messenger())
    PdfScanCoordinator.shared.configure(binaryMessenger: applicationRegistrar.messenger())
    applicationRegistrar.register(
      PdfPlatformViewFactory(),
      withId: "pdf_poc_view"
    )
    applicationRegistrar.register(
      PdfPageReorderPlatformViewFactory(runtime: PdfPocRuntime.shared),
      withId: "pdf_poc_page_reorder_view"
    )
    applicationRegistrar.register(
      PdfDocumentViewerPlatformViewFactory(),
      withId: "pdf_poc_document_viewer_view"
    )
    applicationRegistrar.register(
      PdfScanReviewPlatformViewFactory(coordinator: PdfScanCoordinator.shared),
      withId: "pdf_scan_review_view"
    )

    // Hâm nóng trình xem ngay từ lúc khởi động: WebKit spawn process ở tiến
    // trình khác nên nó chạy song song với phần còn lại. `async` để việc dựng
    // `WKWebView` không chen trước khung hình đầu tiên của Flutter.
    DispatchQueue.main.async {
      PdfDocumentViewerViewPool.shared.prewarm()
    }
  }
}
