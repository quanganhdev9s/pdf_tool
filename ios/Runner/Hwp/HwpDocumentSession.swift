import Foundation

enum HwpDocumentFormat: String {
  case hwp
  case hwpx
  case unsupported

  static func from(fileName: String) -> HwpDocumentFormat {
    switch URL(fileURLWithPath: fileName).pathExtension.lowercased() {
    case "hwp":
      return .hwp
    case "hwpx":
      return .hwpx
    default:
      return .unsupported
    }
  }
}

struct HwpDocumentSession {
  let id: String
  let sourceURL: URL
  let format: HwpDocumentFormat
  let fileSizeBytes: Int64
  var pageCount: Int64
  let canOverwriteSource: Bool
  let rhwpHandle: UInt64?
  var isDirty = false

  func info(engineVersion: String) -> HwpDocumentInfo {
    HwpDocumentInfo(
      sessionId: id,
      sourcePath: sourceURL.path,
      fileName: sourceURL.lastPathComponent,
      fileFormat: format.rawValue,
      fileSizeBytes: fileSizeBytes,
      pageCount: pageCount,
      isDirty: isDirty,
      canOverwriteSource: canOverwriteSource,
      engineVersion: engineVersion
    )
  }
}
