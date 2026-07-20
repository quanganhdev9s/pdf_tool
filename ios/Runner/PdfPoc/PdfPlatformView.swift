import Flutter
import Foundation
import UIKit

final class PdfPlatformViewFactory: NSObject, FlutterPlatformViewFactory {
  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    PdfPlatformView(frame: frame)
  }
}

final class PdfPlatformView: NSObject, FlutterPlatformView {
  private let workspaceView: PdfWorkspaceView

  init(frame: CGRect) {
    workspaceView = PdfWorkspaceView(frame: frame)
    super.init()
    PdfPocRuntime.shared.attach(workspaceView: workspaceView)
  }

  deinit {
    PdfPocRuntime.shared.detach(workspaceView: workspaceView)
  }

  func view() -> UIView {
    workspaceView
  }
}
