import Foundation

enum HwpRuntimeError: Error {
  case documentNotOpen
  case fileNotFound(String)
  case invalidRequest(String)
  case readOnlySource(String)
  case rhwpUnavailable
  case unsupportedFormat(String)

  func asPigeonError() -> HwpPigeonError {
    switch self {
    case .documentNotOpen:
      return HwpPigeonError(
        code: "hwp_document_not_open",
        message: "No HWP document is open.",
        details: nil
      )
    case .fileNotFound(let path):
      return HwpPigeonError(
        code: "hwp_file_not_found",
        message: "The HWP file could not be found.",
        details: path
      )
    case .invalidRequest(let message):
      return HwpPigeonError(
        code: "hwp_invalid_request",
        message: message,
        details: nil
      )
    case .readOnlySource(let message):
      return HwpPigeonError(
        code: "hwp_read_only_source",
        message: message,
        details: nil
      )
    case .rhwpUnavailable:
      return HwpPigeonError(
        code: "rhwp_core_unavailable",
        message: "The rhwp Rust engine is not linked into this iOS build yet.",
        details: "Build packages/rhwp_bridge and link RhwpBridge.xcframework."
      )
    case .unsupportedFormat(let fileName):
      return HwpPigeonError(
        code: "hwp_unsupported_format",
        message: "Only .hwp and .hwpx documents are supported.",
        details: fileName
      )
    }
  }
}
