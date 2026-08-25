import Darwin
import Foundation

enum RhwpEngineBridge {
  struct OpenedDocument {
    let handle: UInt64
    let pageCount: UInt32
  }

  struct EditOutcome {
    let replacementCount: Int64
  }

  struct SaveOutcome {
    let outputPath: String
    let fileSizeBytes: Int64
    let validated: Bool
  }

  static var isLinked: Bool {
    symbol("rhwp_bridge_version", as: VersionFunction.self) != nil
  }

  static var version: String {
    guard let versionFunction = symbol("rhwp_bridge_version", as: VersionFunction.self) else {
      return "rhwp-unlinked"
    }
    return stringResult(versionFunction()) ?? "rhwp-linked"
  }

  static func openDocument(path: String) throws -> OpenedDocument {
    let response: OpenResponse = try callStringFunction(
      "rhwp_bridge_open_path",
      OpenPathFunction.self
    ) { function in
      path.withCString { function($0) }
    }
    return OpenedDocument(handle: response.handle, pageCount: response.pageCount)
  }

  static func close(handle: UInt64) {
    guard let closeFunction = symbol("rhwp_bridge_close", as: CloseFunction.self) else {
      return
    }
    _ = stringResult(closeFunction(handle))
  }

  static func pageCount(handle: UInt64) throws -> UInt32 {
    let response: PageCountResponse = try callStringFunction(
      "rhwp_bridge_page_count",
      PageCountFunction.self
    ) { function in
      function(handle)
    }
    return response.pageCount
  }

  static func extractText(handle: UInt64) throws -> String {
    let response: TextResponse = try callStringFunction(
      "rhwp_bridge_extract_text",
      ExtractTextFunction.self
    ) { function in
      function(handle)
    }
    return response.text
  }

  static func renderPageSvg(handle: UInt64, pageIndex: Int64) throws -> String {
    guard pageIndex >= 0, pageIndex <= Int64(UInt32.max) else {
      throw HwpRuntimeError.invalidRequest("Page index is out of range.").asPigeonError()
    }
    let response: RenderPageResponse = try callStringFunction(
      "rhwp_bridge_render_page_svg",
      RenderPageSvgFunction.self
    ) { function in
      function(handle, UInt32(pageIndex))
    }
    return response.svg
  }

  static func hitTest(handle: UInt64, pageIndex: Int64, x: Double, y: Double) throws -> String {
    guard pageIndex >= 0, pageIndex <= Int64(UInt32.max) else {
      throw HwpRuntimeError.invalidRequest("Page index is out of range.").asPigeonError()
    }
    let response: JsonResponse = try callStringFunction(
      "rhwp_bridge_hit_test",
      HitTestFunction.self
    ) { function in
      function(handle, UInt32(pageIndex), x, y)
    }
    return response.json
  }

  static func getCursorRect(
    handle: UInt64,
    sectionIndex: Int64,
    paragraphIndex: Int64,
    charOffset: Int64
  ) throws -> String {
    let section = try uint32(sectionIndex, name: "sectionIndex")
    let paragraph = try uint32(paragraphIndex, name: "paragraphIndex")
    let offset = try uint32(charOffset, name: "charOffset")
    let response: JsonResponse = try callStringFunction(
      "rhwp_bridge_get_cursor_rect",
      CursorRectFunction.self
    ) { function in
      function(handle, section, paragraph, offset)
    }
    return response.json
  }

  static func insertText(
    handle: UInt64,
    sectionIndex: Int64,
    paragraphIndex: Int64,
    charOffset: Int64,
    text: String
  ) throws -> String {
    let section = try uint32(sectionIndex, name: "sectionIndex")
    let paragraph = try uint32(paragraphIndex, name: "paragraphIndex")
    let offset = try uint32(charOffset, name: "charOffset")
    let response: JsonResponse = try callStringFunction(
      "rhwp_bridge_insert_text",
      InsertTextFunction.self
    ) { function in
      text.withCString { textPointer in
        function(handle, section, paragraph, offset, textPointer)
      }
    }
    return response.json
  }

  static func deleteText(
    handle: UInt64,
    sectionIndex: Int64,
    paragraphIndex: Int64,
    charOffset: Int64,
    count: Int64
  ) throws -> String {
    let section = try uint32(sectionIndex, name: "sectionIndex")
    let paragraph = try uint32(paragraphIndex, name: "paragraphIndex")
    let offset = try uint32(charOffset, name: "charOffset")
    let deleteCount = try uint32(count, name: "count")
    let response: JsonResponse = try callStringFunction(
      "rhwp_bridge_delete_text",
      DeleteTextFunction.self
    ) { function in
      function(handle, section, paragraph, offset, deleteCount)
    }
    return response.json
  }

  static func splitParagraph(
    handle: UInt64,
    sectionIndex: Int64,
    paragraphIndex: Int64,
    charOffset: Int64
  ) throws -> String {
    let section = try uint32(sectionIndex, name: "sectionIndex")
    let paragraph = try uint32(paragraphIndex, name: "paragraphIndex")
    let offset = try uint32(charOffset, name: "charOffset")
    let response: JsonResponse = try callStringFunction(
      "rhwp_bridge_split_paragraph",
      SplitParagraphFunction.self
    ) { function in
      function(handle, section, paragraph, offset)
    }
    return response.json
  }

  static func mergeParagraph(
    handle: UInt64,
    sectionIndex: Int64,
    paragraphIndex: Int64
  ) throws -> String {
    let section = try uint32(sectionIndex, name: "sectionIndex")
    let paragraph = try uint32(paragraphIndex, name: "paragraphIndex")
    let response: JsonResponse = try callStringFunction(
      "rhwp_bridge_merge_paragraph",
      MergeParagraphFunction.self
    ) { function in
      function(handle, section, paragraph)
    }
    return response.json
  }

  static func replaceText(
    handle: UInt64,
    find: String,
    replacement: String,
    caseSensitive: Bool,
    replaceAll: Bool
  ) throws -> EditOutcome {
    let response: EditResponse = try callStringFunction(
      "rhwp_bridge_replace_text",
      ReplaceTextFunction.self
    ) { function in
      find.withCString { findPointer in
        replacement.withCString { replacementPointer in
          function(handle, findPointer, replacementPointer, caseSensitive, replaceAll)
        }
      }
    }
    return EditOutcome(replacementCount: Int64(response.replacementCount))
  }

  static func export(handle: UInt64, outputPath: String) throws -> SaveOutcome {
    let response: SaveResponse = try callStringFunction(
      "rhwp_bridge_export",
      ExportFunction.self
    ) { function in
      outputPath.withCString { function(handle, $0) }
    }
    return SaveOutcome(
      outputPath: response.outputPath,
      fileSizeBytes: Int64(response.fileSizeBytes),
      validated: response.validated
    )
  }

  private typealias VersionFunction = @convention(c) () -> UnsafeMutablePointer<CChar>?
  private typealias StringFreeFunction = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
  private typealias OpenPathFunction =
    @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
  private typealias CloseFunction = @convention(c) (UInt64) -> UnsafeMutablePointer<CChar>?
  private typealias PageCountFunction = @convention(c) (UInt64) -> UnsafeMutablePointer<CChar>?
  private typealias ExtractTextFunction = @convention(c) (UInt64) -> UnsafeMutablePointer<CChar>?
  private typealias RenderPageSvgFunction =
    @convention(c) (UInt64, UInt32) -> UnsafeMutablePointer<CChar>?
  private typealias HitTestFunction =
    @convention(c) (UInt64, UInt32, Double, Double) -> UnsafeMutablePointer<CChar>?
  private typealias CursorRectFunction =
    @convention(c) (UInt64, UInt32, UInt32, UInt32) -> UnsafeMutablePointer<CChar>?
  private typealias InsertTextFunction =
    @convention(c) (UInt64, UInt32, UInt32, UInt32, UnsafePointer<CChar>?)
      -> UnsafeMutablePointer<CChar>?
  private typealias DeleteTextFunction =
    @convention(c) (UInt64, UInt32, UInt32, UInt32, UInt32) -> UnsafeMutablePointer<CChar>?
  private typealias SplitParagraphFunction =
    @convention(c) (UInt64, UInt32, UInt32, UInt32) -> UnsafeMutablePointer<CChar>?
  private typealias MergeParagraphFunction =
    @convention(c) (UInt64, UInt32, UInt32) -> UnsafeMutablePointer<CChar>?
  private typealias ReplaceTextFunction =
    @convention(c) (
      UInt64,
      UnsafePointer<CChar>?,
      UnsafePointer<CChar>?,
      Bool,
      Bool
    ) -> UnsafeMutablePointer<CChar>?
  private typealias ExportFunction =
    @convention(c) (UInt64, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?

  private struct BridgeEnvelope: Decodable {
    let ok: Bool
    let error: String?
  }

  private struct OpenResponse: Decodable {
    let ok: Bool
    let error: String?
    let handle: UInt64
    let pageCount: UInt32
  }

  private struct PageCountResponse: Decodable {
    let ok: Bool
    let error: String?
    let pageCount: UInt32
  }

  private struct TextResponse: Decodable {
    let ok: Bool
    let error: String?
    let text: String
  }

  private struct RenderPageResponse: Decodable {
    let ok: Bool
    let error: String?
    let pageIndex: UInt32
    let svg: String
  }

  private struct JsonResponse: Decodable {
    let ok: Bool
    let error: String?
    let json: String
  }

  private struct EditResponse: Decodable {
    let ok: Bool
    let error: String?
    let replacementCount: UInt64
  }

  private struct SaveResponse: Decodable {
    let ok: Bool
    let error: String?
    let outputPath: String
    let fileSizeBytes: UInt64
    let validated: Bool
  }

  private static func callStringFunction<T: Decodable, Function>(
    _ name: String,
    _ functionType: Function.Type,
    invoke: (Function) -> UnsafeMutablePointer<CChar>?
  ) throws -> T {
    guard let function = symbol(name, as: functionType) else {
      throw HwpRuntimeError.rhwpUnavailable.asPigeonError()
    }
    guard let json = stringResult(invoke(function)) else {
      throw HwpRuntimeError.invalidRequest("\(name) returned a null response.").asPigeonError()
    }
    let data = Data(json.utf8)
    let envelope = try JSONDecoder().decode(BridgeEnvelope.self, from: data)
    guard envelope.ok else {
      throw HwpRuntimeError.invalidRequest(envelope.error ?? "rhwp bridge call failed.")
        .asPigeonError()
    }
    return try JSONDecoder().decode(T.self, from: data)
  }

  private static func stringResult(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
    guard let pointer else {
      return nil
    }
    defer {
      if let freeFunction = symbol("rhwp_bridge_string_free", as: StringFreeFunction.self) {
        freeFunction(pointer)
      }
    }
    return String(cString: pointer)
  }

  private static func uint32(_ value: Int64, name: String) throws -> UInt32 {
    guard value >= 0, value <= Int64(UInt32.max) else {
      throw HwpRuntimeError.invalidRequest("\(name) is out of range.").asPigeonError()
    }
    return UInt32(value)
  }

  private static func symbol<T>(_ name: String, as _: T.Type) -> T? {
    let defaultScope = UnsafeMutableRawPointer(bitPattern: -2)
    if let pointer = dlsym(defaultScope, name) {
      return unsafeBitCast(pointer, to: T.self)
    }
    guard let handle = dlopen(nil, RTLD_NOW), let pointer = dlsym(handle, name) else {
      return nil
    }
    return unsafeBitCast(pointer, to: T.self)
  }
}
