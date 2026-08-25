import Flutter
import Foundation

final class HwpRuntime {
  static let shared = HwpRuntime()

  private let fileManager = FileManager.default
  private var session: HwpDocumentSession?

  private init() {}

  func configure(binaryMessenger: FlutterBinaryMessenger) {
    HwpHostApiSetup.setUp(
      binaryMessenger: binaryMessenger,
      api: HwpHostApiImpl(runtime: self)
    )
  }

  func openAsset(assetKey: String, assetBytes: Data) throws -> HwpDocumentInfo {
    let directory = try workingDirectory()
    let fileName = URL(fileURLWithPath: assetKey).lastPathComponent
    let destination = directory.appendingPathComponent(fileName)
    try assetBytes.write(to: destination, options: [.atomic])
    return try openLocalCopy(url: destination, canOverwriteSource: false)
  }

  func openFile(path: String) throws -> HwpDocumentInfo {
    let url = URL(fileURLWithPath: path)
    return try openLocalCopy(url: url, canOverwriteSource: true)
  }

  func close() {
    if let handle = session?.rhwpHandle {
      RhwpEngineBridge.close(handle: handle)
    }
    session = nil
  }

  func currentInfo() throws -> HwpDocumentInfo {
    try refreshPageCount()
    return try requireSession().info(engineVersion: RhwpEngineBridge.version)
  }

  func extractText() throws -> String {
    let handle = try requireEngineHandle()
    return try RhwpEngineBridge.extractText(handle: handle)
  }

  func renderPageSvg(pageIndex: Int64) throws -> String {
    let currentSession = try requireSession()
    guard pageIndex >= 0, pageIndex < currentSession.pageCount else {
      throw HwpRuntimeError.invalidRequest("Page index \(pageIndex) is out of range.")
        .asPigeonError()
    }
    return try RhwpEngineBridge.renderPageSvg(
      handle: try requireEngineHandle(from: currentSession),
      pageIndex: pageIndex
    )
  }

  func hitTest(pageIndex: Int64, x: Double, y: Double) throws -> String {
    let currentSession = try requireSession()
    guard pageIndex >= 0, pageIndex < currentSession.pageCount else {
      throw HwpRuntimeError.invalidRequest("Page index \(pageIndex) is out of range.")
        .asPigeonError()
    }
    return try RhwpEngineBridge.hitTest(
      handle: try requireEngineHandle(from: currentSession),
      pageIndex: pageIndex,
      x: x,
      y: y
    )
  }

  func getCursorRect(sectionIndex: Int64, paragraphIndex: Int64, charOffset: Int64) throws
    -> String
  {
    try RhwpEngineBridge.getCursorRect(
      handle: try requireEngineHandle(),
      sectionIndex: sectionIndex,
      paragraphIndex: paragraphIndex,
      charOffset: charOffset
    )
  }

  func insertText(sectionIndex: Int64, paragraphIndex: Int64, charOffset: Int64, text: String)
    throws -> String
  {
    var currentSession = try requireSession()
    let handle = try requireEngineHandle(from: currentSession)
    let json = try RhwpEngineBridge.insertText(
      handle: handle,
      sectionIndex: sectionIndex,
      paragraphIndex: paragraphIndex,
      charOffset: charOffset,
      text: text
    )
    currentSession.isDirty = true
    currentSession.pageCount = Int64(try RhwpEngineBridge.pageCount(handle: handle))
    session = currentSession
    return json
  }

  func deleteText(sectionIndex: Int64, paragraphIndex: Int64, charOffset: Int64, count: Int64)
    throws -> String
  {
    var currentSession = try requireSession()
    let handle = try requireEngineHandle(from: currentSession)
    let json = try RhwpEngineBridge.deleteText(
      handle: handle,
      sectionIndex: sectionIndex,
      paragraphIndex: paragraphIndex,
      charOffset: charOffset,
      count: count
    )
    currentSession.isDirty = true
    currentSession.pageCount = Int64(try RhwpEngineBridge.pageCount(handle: handle))
    session = currentSession
    return json
  }

  func splitParagraph(sectionIndex: Int64, paragraphIndex: Int64, charOffset: Int64) throws
    -> String
  {
    var currentSession = try requireSession()
    let handle = try requireEngineHandle(from: currentSession)
    let json = try RhwpEngineBridge.splitParagraph(
      handle: handle,
      sectionIndex: sectionIndex,
      paragraphIndex: paragraphIndex,
      charOffset: charOffset
    )
    currentSession.isDirty = true
    currentSession.pageCount = Int64(try RhwpEngineBridge.pageCount(handle: handle))
    session = currentSession
    return json
  }

  func mergeParagraph(sectionIndex: Int64, paragraphIndex: Int64) throws -> String {
    var currentSession = try requireSession()
    let handle = try requireEngineHandle(from: currentSession)
    let json = try RhwpEngineBridge.mergeParagraph(
      handle: handle,
      sectionIndex: sectionIndex,
      paragraphIndex: paragraphIndex
    )
    currentSession.isDirty = true
    currentSession.pageCount = Int64(try RhwpEngineBridge.pageCount(handle: handle))
    session = currentSession
    return json
  }

  func replaceText(_ request: HwpReplaceTextRequest) throws -> HwpEditResult {
    var currentSession = try requireSession()
    guard !request.find.isEmpty else {
      throw HwpRuntimeError.invalidRequest("Find text must not be empty.").asPigeonError()
    }
    let handle = try requireEngineHandle(from: currentSession)
    let outcome = try RhwpEngineBridge.replaceText(
      handle: handle,
      find: request.find,
      replacement: request.replacement,
      caseSensitive: request.caseSensitive,
      replaceAll: request.replaceAll
    )
    currentSession.isDirty = currentSession.isDirty || outcome.replacementCount > 0
    currentSession.pageCount = Int64(try RhwpEngineBridge.pageCount(handle: handle))
    session = currentSession
    return HwpEditResult(replacementCount: outcome.replacementCount, isDirty: currentSession.isDirty)
  }

  func save() throws -> HwpSaveResult {
    var currentSession = try requireSession()
    guard currentSession.canOverwriteSource else {
      throw HwpRuntimeError.readOnlySource(
        "The current HWP document is an app-owned asset copy. Use a picked file "
          + "opened in place before overwriting the user's original."
      ).asPigeonError()
    }
    let outcome = try RhwpEngineBridge.export(
      handle: try requireEngineHandle(from: currentSession),
      outputPath: currentSession.sourceURL.path
    )
    currentSession.isDirty = false
    session = currentSession
    return HwpSaveResult(
      outputPath: outcome.outputPath,
      fileSizeBytes: outcome.fileSizeBytes,
      overwroteSource: true,
      validated: outcome.validated
    )
  }

  func exportCopy(outputPath: String) throws -> HwpSaveResult {
    let currentSession = try requireSession()
    guard !outputPath.isEmpty else {
      throw HwpRuntimeError.invalidRequest("Output path must not be empty.").asPigeonError()
    }
    let outcome = try RhwpEngineBridge.export(
      handle: try requireEngineHandle(from: currentSession),
      outputPath: outputPath
    )
    return HwpSaveResult(
      outputPath: outcome.outputPath,
      fileSizeBytes: outcome.fileSizeBytes,
      overwroteSource: outputPath == currentSession.sourceURL.path,
      validated: outcome.validated
    )
  }

  private func openLocalCopy(url: URL, canOverwriteSource: Bool) throws -> HwpDocumentInfo {
    guard fileManager.fileExists(atPath: url.path) else {
      throw HwpRuntimeError.fileNotFound(url.path).asPigeonError()
    }

    let format = HwpDocumentFormat.from(fileName: url.lastPathComponent)
    guard format != .unsupported else {
      throw HwpRuntimeError.unsupportedFormat(url.lastPathComponent).asPigeonError()
    }

    let fileSize = try fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber
    let openedDocument = RhwpEngineBridge.isLinked
      ? try RhwpEngineBridge.openDocument(path: url.path)
      : nil
    if let handle = session?.rhwpHandle {
      RhwpEngineBridge.close(handle: handle)
    }

    let newSession = HwpDocumentSession(
      id: UUID().uuidString,
      sourceURL: url,
      format: format,
      fileSizeBytes: fileSize?.int64Value ?? 0,
      pageCount: Int64(openedDocument?.pageCount ?? 0),
      canOverwriteSource: canOverwriteSource,
      rhwpHandle: openedDocument?.handle
    )
    session = newSession
    return newSession.info(engineVersion: RhwpEngineBridge.version)
  }

  private func requireSession() throws -> HwpDocumentSession {
    guard let session else {
      throw HwpRuntimeError.documentNotOpen.asPigeonError()
    }
    return session
  }

  private func requireEngineHandle() throws -> UInt64 {
    try requireEngineHandle(from: try requireSession())
  }

  private func requireEngineHandle(from session: HwpDocumentSession) throws -> UInt64 {
    guard let handle = session.rhwpHandle else {
      throw HwpRuntimeError.rhwpUnavailable.asPigeonError()
    }
    return handle
  }

  private func refreshPageCount() throws {
    var currentSession = try requireSession()
    guard let handle = currentSession.rhwpHandle else {
      return
    }
    currentSession.pageCount = Int64(try RhwpEngineBridge.pageCount(handle: handle))
    session = currentSession
  }

  private func workingDirectory() throws -> URL {
    let appSupport = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let directory = appSupport.appendingPathComponent("HwpWorkingCopies", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
