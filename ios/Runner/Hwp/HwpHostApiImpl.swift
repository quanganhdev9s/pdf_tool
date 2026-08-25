import Flutter
import Foundation

final class HwpHostApiImpl: HwpHostApi {
  private let runtime: HwpRuntime

  init(runtime: HwpRuntime) {
    self.runtime = runtime
  }

  func openHwpAsset(
    assetKey: String,
    assetBytes: FlutterStandardTypedData
  ) throws -> HwpDocumentInfo {
    try runtime.openAsset(assetKey: assetKey, assetBytes: assetBytes.data)
  }

  func openHwpFile(path: String) throws -> HwpDocumentInfo {
    try runtime.openFile(path: path)
  }

  func currentHwpDocumentInfo() throws -> HwpDocumentInfo {
    try runtime.currentInfo()
  }

  func closeHwpDocument() throws {
    runtime.close()
  }

  func extractHwpText() throws -> String {
    try runtime.extractText()
  }

  func renderHwpPageSvg(pageIndex: Int64) throws -> String {
    try runtime.renderPageSvg(pageIndex: pageIndex)
  }

  func hitTestHwpPage(pageIndex: Int64, x: Double, y: Double) throws -> String {
    try runtime.hitTest(pageIndex: pageIndex, x: x, y: y)
  }

  func getHwpCursorRect(
    sectionIndex: Int64,
    paragraphIndex: Int64,
    charOffset: Int64
  ) throws -> String {
    try runtime.getCursorRect(
      sectionIndex: sectionIndex,
      paragraphIndex: paragraphIndex,
      charOffset: charOffset
    )
  }

  func insertHwpText(
    sectionIndex: Int64,
    paragraphIndex: Int64,
    charOffset: Int64,
    text: String
  ) throws -> String {
    try runtime.insertText(
      sectionIndex: sectionIndex,
      paragraphIndex: paragraphIndex,
      charOffset: charOffset,
      text: text
    )
  }

  func deleteHwpText(
    sectionIndex: Int64,
    paragraphIndex: Int64,
    charOffset: Int64,
    count: Int64
  ) throws -> String {
    try runtime.deleteText(
      sectionIndex: sectionIndex,
      paragraphIndex: paragraphIndex,
      charOffset: charOffset,
      count: count
    )
  }

  func splitHwpParagraph(
    sectionIndex: Int64,
    paragraphIndex: Int64,
    charOffset: Int64
  ) throws -> String {
    try runtime.splitParagraph(
      sectionIndex: sectionIndex,
      paragraphIndex: paragraphIndex,
      charOffset: charOffset
    )
  }

  func mergeHwpParagraph(sectionIndex: Int64, paragraphIndex: Int64) throws -> String {
    try runtime.mergeParagraph(
      sectionIndex: sectionIndex,
      paragraphIndex: paragraphIndex
    )
  }

  func replaceHwpText(request: HwpReplaceTextRequest) throws -> HwpEditResult {
    try runtime.replaceText(request)
  }

  func hwpEditHistoryState() throws -> HwpEditHistoryState {
    try runtime.editHistoryState()
  }

  func undoHwpEdit() throws -> HwpEditHistoryState {
    try runtime.undoEdit()
  }

  func redoHwpEdit() throws -> HwpEditHistoryState {
    try runtime.redoEdit()
  }

  func saveHwp() throws -> HwpSaveResult {
    try runtime.save()
  }

  func exportHwpCopy(outputPath: String) throws -> HwpSaveResult {
    try runtime.exportCopy(outputPath: outputPath)
  }
}
