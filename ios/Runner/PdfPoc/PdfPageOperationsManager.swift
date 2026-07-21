import Foundation
import PDFKit
import UIKit

struct PdfPageReorderPreview {
  let pageIndex: Int64
  let thumbnail: UIImage
}

/// Owns POC 3 page mutations: page rotation, deletion, duplication, reordering,
/// crop-box updates, and validation helpers around PDFKit page indexes.
final class PdfPageOperationsManager {
  func rotatePages(_ pageIndexes: [Int64], degrees: Int64, in document: PDFDocument) throws {
    let indexes = try validatedUniqueIndexes(pageIndexes, in: document)
    let normalizedDegrees = degrees % 360
    guard normalizedDegrees % 90 == 0 else {
      throw PdfPocError(
        code: "invalid_page_operation",
        message: "Page rotation must be a multiple of 90 degrees.",
        details: "degrees=\(degrees)"
      )
    }

    for index in indexes {
      guard let page = document.page(at: index) else {
        throw PdfPocError.pageOutOfRange(Int64(index))
      }
      let nextRotation = (page.rotation + Int(normalizedDegrees) + 360) % 360
      page.rotation = nextRotation
      logPdfEvent("page_rotated", "pageIndex=\(index) rotation=\(nextRotation)")
    }
  }

  func deletePages(_ pageIndexes: [Int64], in document: PDFDocument) throws -> Int {
    let indexes = try validatedUniqueIndexes(pageIndexes, in: document)
    guard indexes.count < document.pageCount else {
      throw PdfPocError(
        code: "invalid_page_operation",
        message: "POC 3 keeps at least one page in the document.",
        details: "requested=\(indexes.count), pageCount=\(document.pageCount)"
      )
    }

    for index in indexes.sorted(by: >) {
      document.removePage(at: index)
      logPdfEvent("page_deleted", "pageIndex=\(index)")
    }
    return indexes.count
  }

  func duplicatePage(
    at pageIndex: Int64,
    destinationIndex: Int64,
    in document: PDFDocument
  ) throws {
    let sourceIndex = try validatedIndex(pageIndex, in: document)
    guard destinationIndex >= 0, destinationIndex <= Int64(document.pageCount) else {
      throw PdfPocError.pageOutOfRange(destinationIndex)
    }
    guard let page = document.page(at: sourceIndex),
          let copiedPage = page.copy() as? PDFPage else {
      throw PdfPocError(
        code: "page_operation_failed",
        message: "PDFKit could not duplicate the selected page.",
        details: "pageIndex=\(pageIndex)"
      )
    }
    document.insert(copiedPage, at: Int(destinationIndex))
    logPdfEvent(
      "page_duplicated",
      "pageIndex=\(sourceIndex) destinationIndex=\(destinationIndex)"
    )
  }

  func movePage(from fromIndex: Int64, to toIndex: Int64, in document: PDFDocument) throws {
    let sourceIndex = try validatedIndex(fromIndex, in: document)
    let destinationIndex = try validatedIndex(toIndex, in: document)
    guard sourceIndex != destinationIndex else {
      logPdfEvent("page_move_noop", "pageIndex=\(sourceIndex)")
      return
    }
    guard let page = document.page(at: sourceIndex) else {
      throw PdfPocError.pageOutOfRange(fromIndex)
    }
    document.removePage(at: sourceIndex)
    document.insert(page, at: destinationIndex)
    logPdfEvent("page_moved", "fromIndex=\(sourceIndex) toIndex=\(destinationIndex)")
  }

  func reorderPages(to pageOrder: [Int64], in document: PDFDocument) throws {
    let indexes = try validatedReorderIndexes(pageOrder, in: document)
    let pages = try indexes.map { index -> PDFPage in
      guard let page = document.page(at: index) else {
        throw PdfPocError.pageOutOfRange(Int64(index))
      }
      return page
    }

    for index in stride(from: document.pageCount - 1, through: 0, by: -1) {
      document.removePage(at: index)
    }
    for (index, page) in pages.enumerated() {
      document.insert(page, at: index)
    }
    logPdfEvent("pages_reordered", "order=\(pageOrder)")
  }

  func cropPage(at pageIndex: Int64, to requestedBounds: CGRect, in document: PDFDocument) throws {
    let index = try validatedIndex(pageIndex, in: document)
    guard let page = document.page(at: index) else {
      throw PdfPocError.pageOutOfRange(pageIndex)
    }
    let mediaBox = page.bounds(for: .mediaBox)
    let cropBounds = requestedBounds.intersection(mediaBox)
    guard !cropBounds.isNull,
          cropBounds.width >= 36,
          cropBounds.height >= 36 else {
      throw PdfPocError(
        code: "invalid_page_operation",
        message: "Crop bounds must leave a visible page area.",
        details: "requested=\(requestedBounds), mediaBox=\(mediaBox)"
      )
    }
    page.setBounds(cropBounds, for: .cropBox)
    logPdfEvent("page_cropped", "pageIndex=\(index) cropBox=\(cropBounds)")
  }

  func cropPageToInset(
    at pageIndex: Int64,
    insetPoints: CGFloat,
    in document: PDFDocument
  ) throws {
    let index = try validatedIndex(pageIndex, in: document)
    guard let page = document.page(at: index) else {
      throw PdfPocError.pageOutOfRange(pageIndex)
    }
    let currentCropBox = page.bounds(for: .cropBox)
    let safeInset = max(insetPoints, 0)
    let cropBounds = currentCropBox.insetBy(dx: safeInset, dy: safeInset)
    try cropPage(at: pageIndex, to: cropBounds, in: document)
  }

  func reorderPreviews(in document: PDFDocument, maxPixelSize: CGSize) -> [PdfPageReorderPreview] {
    (0..<document.pageCount).compactMap { index in
      guard let page = document.page(at: index) else { return nil }
      return PdfPageReorderPreview(
        pageIndex: Int64(index),
        thumbnail: renderThumbnail(for: page, maxPixelSize: maxPixelSize)
      )
    }
  }

  private func validatedUniqueIndexes(
    _ pageIndexes: [Int64],
    in document: PDFDocument
  ) throws -> [Int] {
    guard !pageIndexes.isEmpty else {
      throw PdfPocError(
        code: "invalid_page_operation",
        message: "Select at least one page for this operation.",
        details: nil
      )
    }
    var seen = Set<Int>()
    var indexes: [Int] = []
    for pageIndex in pageIndexes {
      let index = try validatedIndex(pageIndex, in: document)
      if seen.insert(index).inserted {
        indexes.append(index)
      }
    }
    return indexes
  }

  private func validatedIndex(_ pageIndex: Int64, in document: PDFDocument) throws -> Int {
    guard pageIndex >= 0, pageIndex < Int64(document.pageCount) else {
      throw PdfPocError.pageOutOfRange(pageIndex)
    }
    return Int(pageIndex)
  }

  private func validatedReorderIndexes(
    _ pageOrder: [Int64],
    in document: PDFDocument
  ) throws -> [Int] {
    guard pageOrder.count == document.pageCount else {
      throw PdfPocError(
        code: "invalid_page_operation",
        message: "Reorder must include every page exactly once.",
        details: "orderCount=\(pageOrder.count), pageCount=\(document.pageCount)"
      )
    }
    let indexes = try pageOrder.map { try validatedIndex($0, in: document) }
    let expected = Set(0..<document.pageCount)
    guard Set(indexes) == expected else {
      throw PdfPocError(
        code: "invalid_page_operation",
        message: "Reorder must include each page exactly once.",
        details: "order=\(pageOrder)"
      )
    }
    return indexes
  }

  private func renderThumbnail(for page: PDFPage, maxPixelSize: CGSize) -> UIImage {
    let pageBounds = page.bounds(for: .cropBox)
    guard pageBounds.width > 0, pageBounds.height > 0 else {
      return UIImage()
    }
    let scale = min(
      maxPixelSize.width / pageBounds.width,
      maxPixelSize.height / pageBounds.height
    )
    let outputSize = CGSize(
      width: max(pageBounds.width * scale, 1),
      height: max(pageBounds.height * scale, 1)
    )
    let renderer = UIGraphicsImageRenderer(size: outputSize)
    return renderer.image { context in
      UIColor.white.setFill()
      context.fill(CGRect(origin: .zero, size: outputSize))
      let cgContext = context.cgContext
      cgContext.saveGState()
      cgContext.translateBy(x: 0, y: outputSize.height)
      cgContext.scaleBy(x: scale, y: -scale)
      cgContext.translateBy(x: -pageBounds.minX, y: -pageBounds.minY)
      page.draw(with: .cropBox, to: cgContext)
      cgContext.restoreGState()
    }
  }
}
