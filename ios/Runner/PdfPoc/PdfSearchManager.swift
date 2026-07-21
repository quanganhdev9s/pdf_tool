import Foundation
import PDFKit

/// Owns PDFKit search state for the open document, including result selection,
/// active-result navigation, and embedded text-layer detection.
final class PdfSearchManager {
  private weak var pdfView: PDFView?
  private var selections: [PDFSelection] = []
  private var query = ""
  private var activeIndex = -1

  init(pdfView: PDFView) {
    self.pdfView = pdfView
  }

  func search(_ request: PdfSearchRequest, in document: PDFDocument) throws -> PdfSearchState {
    clear()
    let trimmedQuery = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
    query = trimmedQuery

    guard !trimmedQuery.isEmpty else {
      return state()
    }

    guard Self.hasSearchableText(document) else {
      throw PdfPocError(
        code: "no_searchable_text",
        message: "This PDF does not expose a searchable text layer.",
        details: nil
      )
    }

    var options: NSString.CompareOptions = []
    if !request.caseSensitive {
      options.insert(.caseInsensitive)
    }
    selections = document.findString(trimmedQuery, withOptions: options)
      .filter { selection in
        if request.wholeWord {
          return selection.string?.range(
            of: trimmedQuery,
            options: request.caseSensitive ? [] : [.caseInsensitive]
          ) != nil
        }
        return true
      }

    if !selections.isEmpty {
      activeIndex = 0
      showActiveResult()
    }
    return state()
  }

  func goToNextResult() -> PdfSearchState {
    guard !selections.isEmpty else {
      return state()
    }
    activeIndex = (activeIndex + 1) % selections.count
    showActiveResult()
    return state()
  }

  func goToPreviousResult() -> PdfSearchState {
    guard !selections.isEmpty else {
      return state()
    }
    activeIndex = (activeIndex - 1 + selections.count) % selections.count
    showActiveResult()
    return state()
  }

  func clear() {
    selections = []
    query = ""
    activeIndex = -1
    pdfView?.setCurrentSelection(nil, animate: false)
  }

  func state() -> PdfSearchState {
    let activeText: String?
    if activeIndex >= 0, activeIndex < selections.count {
      activeText = selections[activeIndex].string
    } else {
      activeText = nil
    }
    return PdfSearchState(
      query: query,
      totalResults: Int64(selections.count),
      activeResultIndex: Int64(activeIndex),
      activeResultText: activeText
    )
  }

  static func hasSearchableText(_ document: PDFDocument) -> Bool {
    for index in 0..<document.pageCount {
      if let text = document.page(at: index)?.string,
         !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return true
      }
    }
    return false
  }

  private func showActiveResult() {
    guard activeIndex >= 0, activeIndex < selections.count,
          let pdfView else {
      return
    }
    let selection = selections[activeIndex]
    pdfView.setCurrentSelection(selection, animate: true)
    pdfView.go(to: selection)
  }
}
