import Foundation
import PDFKit

private struct ValidatedPageRange {
  let start: Int
  let end: Int
}

/// Owns POC 6 split/merge generation. It opens isolated PDFDocument instances
/// from local paths, writes temp files first, validates reopen, then publishes
/// final paths without mutating the active viewer document.
final class PdfSplitMergeManager {
  var onSplitProgress: ((String, Int64, Int64) -> Void)?
  var onSplitCompleted: ((String, PdfSplitResult?, Bool) -> Void)?
  var onMergeProgress: ((String, Int64, Int64) -> Void)?
  var onMergeCompleted: ((String, PdfMergeResult?, Bool) -> Void)?
  var onError: ((String, PdfPocError) -> Void)?

  private let workQueue = DispatchQueue(label: "pdf.poc.split_merge", qos: .userInitiated)
  private let stateLock = NSLock()
  private var activeSplitOperationId: String?
  private var activeMergeOperationId: String?
  private var cancelledOperationIds = Set<String>()

  func split(
    request: PdfSplitRequest,
    sourceURL: URL,
    outputDirectory: URL,
    baseFileName: String
  ) {
    let operationId = UUID().uuidString
    cancelSplit()
    setActiveSplitOperationId(operationId)
    logPdfEvent(
      "split_start",
      "operationId=\(operationId) ranges=\(request.ranges) source=\(sourceURL.path)"
    )
    workQueue.async { [weak self] in
      self?.performSplit(
        operationId: operationId,
        request: request,
        sourceURL: sourceURL,
        outputDirectory: outputDirectory,
        baseFileName: baseFileName
      )
    }
  }

  func merge(request: PdfMergeRequest, outputURL: URL) {
    let operationId = UUID().uuidString
    cancelMerge()
    setActiveMergeOperationId(operationId)
    logPdfEvent(
      "merge_start",
      "operationId=\(operationId) inputs=\(request.inputPaths) output=\(outputURL.path)"
    )
    workQueue.async { [weak self] in
      self?.performMerge(operationId: operationId, request: request, outputURL: outputURL)
    }
  }

  func cancelSplit() {
    let operationId: String?
    stateLock.lock()
    operationId = activeSplitOperationId
    if let operationId {
      cancelledOperationIds.insert(operationId)
      logPdfEvent("split_cancel_requested", "operationId=\(operationId)")
    }
    activeSplitOperationId = nil
    stateLock.unlock()
  }

  func cancelMerge() {
    let operationId: String?
    stateLock.lock()
    operationId = activeMergeOperationId
    if let operationId {
      cancelledOperationIds.insert(operationId)
      logPdfEvent("merge_cancel_requested", "operationId=\(operationId)")
    }
    activeMergeOperationId = nil
    stateLock.unlock()
  }

  /// Validates all ranges before writing any split output, including overlap.
  private func performSplit(
    operationId: String,
    request: PdfSplitRequest,
    sourceURL: URL,
    outputDirectory: URL,
    baseFileName: String
  ) {
    let startedAt = Date()
    var publishedFinalURLs: [URL] = []
    do {
      let sourceDocument = try openDocument(at: sourceURL)
      let ranges = try validatedRanges(request.ranges, pageCount: sourceDocument.pageCount)
      try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
      let totalPages = ranges.reduce(0) { $0 + ($1.end - $1.start + 1) }
      var completedPages = 0
      var outputs: [PdfSplitOutput] = []

      for (rangeIndex, range) in ranges.enumerated() {
        try throwIfCancelled(operationId, code: "split_cancelled")
        let outputDocument = PDFDocument()
        for pageIndex in range.start...range.end {
          try throwIfCancelled(operationId, code: "split_cancelled")
          guard let page = sourceDocument.page(at: pageIndex),
                let copiedPage = page.copy() as? PDFPage else {
            throw PdfPocError(
              code: "split_failed",
              message: "PDFKit could not copy a page for split output.",
              details: "pageIndex=\(pageIndex)"
            )
          }
          outputDocument.insert(copiedPage, at: outputDocument.pageCount)
          completedPages += 1
          reportSplitProgress(operationId, completedPages: completedPages, totalPages: totalPages)
        }

        let finalURL = splitOutputURL(
          outputDirectory: outputDirectory,
          baseFileName: baseFileName,
          operationId: operationId,
          rangeIndex: rangeIndex,
          range: range
        )
        try writeValidated(document: outputDocument, tempURL: tempURL(for: finalURL), finalURL: finalURL)
        publishedFinalURLs.append(finalURL)
        outputs.append(PdfSplitOutput(outputPath: finalURL.path, pageCount: Int64(outputDocument.pageCount)))
      }

      let result = PdfSplitResult(
        outputs: outputs,
        durationMilliseconds: Int64(Date().timeIntervalSince(startedAt) * 1000)
      )
      finishSplit(operationId: operationId, result: result, cancelled: false)
    } catch let error as PdfPocError {
      cleanup(publishedFinalURLs)
      if error.code == "operation_cancelled" || error.code == "split_cancelled" {
        finishSplit(operationId: operationId, result: nil, cancelled: true)
      } else {
        fail(operationId: operationId, error: error)
      }
    } catch {
      cleanup(publishedFinalURLs)
      fail(
        operationId: operationId,
        error: PdfPocError(
          code: "split_failed",
          message: "Split operation failed.",
          details: error.localizedDescription
        )
      )
    }
  }

  /// Opens merge inputs exactly in request order and appends every page from
  /// each input before writing one validated output PDF.
  private func performMerge(operationId: String, request: PdfMergeRequest, outputURL: URL) {
    let startedAt = Date()
    do {
      let inputURLs = try validatedMergeInputURLs(request.inputPaths)
      let inputDocuments = try inputURLs.map { try openDocument(at: $0) }
      let totalPages = inputDocuments.reduce(0) { $0 + $1.pageCount }
      let outputDocument = PDFDocument()
      var completedPages = 0

      for document in inputDocuments {
        try throwIfCancelled(operationId, code: "merge_cancelled")
        for pageIndex in 0..<document.pageCount {
          try throwIfCancelled(operationId, code: "merge_cancelled")
          guard let page = document.page(at: pageIndex),
                let copiedPage = page.copy() as? PDFPage else {
            throw PdfPocError(
              code: "merge_failed",
              message: "PDFKit could not copy a page for merge output.",
              details: "pageIndex=\(pageIndex)"
            )
          }
          outputDocument.insert(copiedPage, at: outputDocument.pageCount)
          completedPages += 1
          reportMergeProgress(operationId, completedPages: completedPages, totalPages: totalPages)
        }
      }

      try writeValidated(document: outputDocument, tempURL: tempURL(for: outputURL), finalURL: outputURL)
      let result = PdfMergeResult(
        outputPath: outputURL.path,
        inputDocumentCount: Int64(inputDocuments.count),
        pageCount: Int64(outputDocument.pageCount),
        durationMilliseconds: Int64(Date().timeIntervalSince(startedAt) * 1000)
      )
      finishMerge(operationId: operationId, result: result, cancelled: false)
    } catch let error as PdfPocError {
      try? FileManager.default.removeItem(at: outputURL)
      if error.code == "operation_cancelled" || error.code == "merge_cancelled" {
        finishMerge(operationId: operationId, result: nil, cancelled: true)
      } else {
        fail(operationId: operationId, error: error)
      }
    } catch {
      try? FileManager.default.removeItem(at: outputURL)
      fail(
        operationId: operationId,
        error: PdfPocError(
          code: "merge_failed",
          message: "Merge operation failed.",
          details: error.localizedDescription
        )
      )
    }
  }

  private func openDocument(at url: URL) throws -> PDFDocument {
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw PdfPocError(
        code: "input_pdf_missing",
        message: "A requested PDF input path does not exist.",
        details: url.path
      )
    }
    guard let document = PDFDocument(url: url) else {
      throw PdfPocError(
        code: "invalid_pdf",
        message: "PDFKit could not open one of the requested PDF inputs.",
        details: url.path
      )
    }
    if document.isLocked {
      throw PdfPocError(
        code: "password_required",
        message: "A requested PDF input is password protected.",
        details: url.path
      )
    }
    guard document.pageCount > 0 else {
      throw PdfPocError(
        code: "invalid_pdf",
        message: "A requested PDF input has no pages.",
        details: url.path
      )
    }
    return document
  }

  private func validatedRanges(
    _ rawRanges: [PdfPageRange],
    pageCount: Int
  ) throws -> [ValidatedPageRange] {
    guard !rawRanges.isEmpty else {
      throw PdfPocError(
        code: "invalid_page_range",
        message: "Enter at least one split page range.",
        details: nil
      )
    }
    let ranges = try rawRanges.map { rawRange -> ValidatedPageRange in
      let start = Int(rawRange.startPageIndex)
      let end = Int(rawRange.endPageIndex)
      guard start >= 0, end >= 0, start <= end, end < pageCount else {
        throw PdfPocError(
          code: "invalid_page_range",
          message: "Split ranges must be zero-based, inclusive, and inside the document.",
          details: "range=\(rawRange), pageCount=\(pageCount)"
        )
      }
      return ValidatedPageRange(start: start, end: end)
    }
    let sortedRanges = ranges.sorted { $0.start < $1.start }
    for index in 1..<sortedRanges.count {
      if sortedRanges[index].start <= sortedRanges[index - 1].end {
        throw PdfPocError(
          code: "invalid_page_range",
          message: "Split ranges must not overlap.",
          details: "ranges=\(rawRanges)"
        )
      }
    }
    return ranges
  }

  private func validatedMergeInputURLs(_ inputPaths: [String]) throws -> [URL] {
    let cleanedPaths = inputPaths
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard cleanedPaths.count >= 2 else {
      throw PdfPocError(
        code: "invalid_merge_inputs",
        message: "Merge requires two or more local PDF paths.",
        details: nil
      )
    }
    return cleanedPaths.map { URL(fileURLWithPath: $0) }
  }

  private func writeValidated(document: PDFDocument, tempURL: URL, finalURL: URL) throws {
    try FileManager.default.createDirectory(
      at: finalURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try? FileManager.default.removeItem(at: tempURL)
    guard document.write(to: tempURL) else {
      throw PdfPocError(
        code: "pdf_write_failed",
        message: "PDFKit could not write the temporary output.",
        details: tempURL.path
      )
    }
    guard let reopened = PDFDocument(url: tempURL),
          !reopened.isLocked,
          reopened.pageCount == document.pageCount else {
      try? FileManager.default.removeItem(at: tempURL)
      throw PdfPocError(
        code: "pdf_validation_failed",
        message: "PDFKit could not reopen the temporary output for validation.",
        details: tempURL.path
      )
    }
    try? FileManager.default.removeItem(at: finalURL)
    try FileManager.default.moveItem(at: tempURL, to: finalURL)
  }

  private func splitOutputURL(
    outputDirectory: URL,
    baseFileName: String,
    operationId: String,
    rangeIndex: Int,
    range: ValidatedPageRange
  ) -> URL {
    outputDirectory.appendingPathComponent(
      "\(baseFileName)_split_\(shortId(operationId))_\(rangeIndex + 1)_\(range.start)-\(range.end).pdf"
    )
  }

  private func tempURL(for finalURL: URL) -> URL {
    finalURL.deletingLastPathComponent()
      .appendingPathComponent(".\(finalURL.lastPathComponent).tmp")
  }

  private func shortId(_ operationId: String) -> String {
    String(operationId.replacingOccurrences(of: "-", with: "").prefix(8))
  }

  private func throwIfCancelled(_ operationId: String, code: String) throws {
    if isCancelled(operationId) {
      throw PdfPocError(code: code, message: "Operation was cancelled.", details: operationId)
    }
  }

  private func reportSplitProgress(
    _ operationId: String,
    completedPages: Int,
    totalPages: Int
  ) {
    DispatchQueue.main.async {
      self.onSplitProgress?(operationId, Int64(completedPages), Int64(totalPages))
    }
  }

  private func reportMergeProgress(
    _ operationId: String,
    completedPages: Int,
    totalPages: Int
  ) {
    DispatchQueue.main.async {
      self.onMergeProgress?(operationId, Int64(completedPages), Int64(totalPages))
    }
  }

  private func setActiveSplitOperationId(_ operationId: String) {
    stateLock.lock()
    activeSplitOperationId = operationId
    cancelledOperationIds.remove(operationId)
    stateLock.unlock()
  }

  private func setActiveMergeOperationId(_ operationId: String) {
    stateLock.lock()
    activeMergeOperationId = operationId
    cancelledOperationIds.remove(operationId)
    stateLock.unlock()
  }

  private func isCancelled(_ operationId: String) -> Bool {
    stateLock.lock()
    let cancelled = cancelledOperationIds.contains(operationId)
      || (activeSplitOperationId != operationId && activeMergeOperationId != operationId)
    stateLock.unlock()
    return cancelled
  }

  private func finishSplit(operationId: String, result: PdfSplitResult?, cancelled: Bool) {
    stateLock.lock()
    guard cancelled || activeSplitOperationId == operationId else {
      stateLock.unlock()
      return
    }
    if activeSplitOperationId == operationId {
      activeSplitOperationId = nil
    }
    cancelledOperationIds.remove(operationId)
    stateLock.unlock()
    logPdfEvent("split_completed", "operationId=\(operationId) cancelled=\(cancelled)")
    DispatchQueue.main.async {
      self.onSplitCompleted?(operationId, result, cancelled)
    }
  }

  private func finishMerge(operationId: String, result: PdfMergeResult?, cancelled: Bool) {
    stateLock.lock()
    guard cancelled || activeMergeOperationId == operationId else {
      stateLock.unlock()
      return
    }
    if activeMergeOperationId == operationId {
      activeMergeOperationId = nil
    }
    cancelledOperationIds.remove(operationId)
    stateLock.unlock()
    logPdfEvent("merge_completed", "operationId=\(operationId) cancelled=\(cancelled)")
    DispatchQueue.main.async {
      self.onMergeCompleted?(operationId, result, cancelled)
    }
  }

  private func fail(operationId: String, error: PdfPocError) {
    stateLock.lock()
    if activeSplitOperationId == operationId {
      activeSplitOperationId = nil
    }
    if activeMergeOperationId == operationId {
      activeMergeOperationId = nil
    }
    cancelledOperationIds.remove(operationId)
    stateLock.unlock()
    logPdfEvent(
      "split_merge_failed",
      "operationId=\(operationId) code=\(error.code) message=\(error.message)"
    )
    DispatchQueue.main.async {
      self.onError?(operationId, error)
    }
  }

  private func cleanup(_ urls: [URL]) {
    for url in urls {
      try? FileManager.default.removeItem(at: url)
    }
  }
}
