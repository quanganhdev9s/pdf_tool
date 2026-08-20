import CoreGraphics
import Foundation

/// One captured page. `originalURL` is written once at capture and never
/// mutated: every preset change reprocesses from it, so switching presets
/// cannot compound one enhancement on top of another.
final class PdfScanPageRecord {
  let id: String
  let originalURL: URL
  var processedURL: URL?
  var preset: PdfScanPreset
  var rotationDegrees: Int

  init(
    id: String = UUID().uuidString,
    originalURL: URL,
    processedURL: URL? = nil,
    preset: PdfScanPreset = .original,
    rotationDegrees: Int = 0
  ) {
    self.id = id
    self.originalURL = originalURL
    self.processedURL = processedURL
    self.preset = preset
    self.rotationDegrees = rotationDegrees
  }

  /// The image the export and the review canvas should draw. Falls back to the
  /// original whenever processing has not run or was discarded.
  var renderURL: URL {
    if preset != .original, let processedURL, FileManager.default.fileExists(atPath: processedURL.path) {
      return processedURL
    }
    return originalURL
  }

  func discardProcessedImage() {
    if let processedURL {
      try? FileManager.default.removeItem(at: processedURL)
    }
    processedURL = nil
  }
}

/// A capture-to-export unit. Pages live on disk under `directory` so a session
/// survives the app being backgrounded mid-review.
final class PdfScanSessionRecord {
  let id: String
  let createdAt: Date
  let source: PdfScanSource
  let directory: URL
  var pages: [PdfScanPageRecord]
  var currentPageIndex: Int
  var isComparingOriginal: Bool

  init(
    id: String,
    createdAt: Date,
    source: PdfScanSource,
    directory: URL,
    pages: [PdfScanPageRecord] = [],
    currentPageIndex: Int = 0,
    isComparingOriginal: Bool = false
  ) {
    self.id = id
    self.createdAt = createdAt
    self.source = source
    self.directory = directory
    self.pages = pages
    self.currentPageIndex = currentPageIndex
    self.isComparingOriginal = isComparingOriginal
  }

  var originalsDirectory: URL { directory.appendingPathComponent("original", isDirectory: true) }
  var processedDirectory: URL { directory.appendingPathComponent("processed", isDirectory: true) }

  func page(withId pageId: String) -> PdfScanPageRecord? {
    pages.first { $0.id == pageId }
  }

  func index(ofPageId pageId: String) -> Int? {
    pages.firstIndex { $0.id == pageId }
  }

  /// Clamps into a valid range after a delete, so the review canvas never ends
  /// up pointing past the end of the list.
  func normalizeCurrentPageIndex() {
    if pages.isEmpty {
      currentPageIndex = 0
    } else {
      currentPageIndex = min(max(currentPageIndex, 0), pages.count - 1)
    }
  }

  var info: PdfScanSessionInfo {
    PdfScanSessionInfo(sessionId: id, pageCount: Int64(pages.count), source: source)
  }

  var pageInfos: [PdfScanPageInfo] {
    pages.enumerated().map { index, page in
      PdfScanPageInfo(
        pageId: page.id,
        index: Int64(index),
        preset: page.preset,
        rotationDegrees: Int64(page.rotationDegrees)
      )
    }
  }

  /// Tally used in the export result, e.g. "magicColor x3, original x1".
  var presetSummary: String {
    var counts: [PdfScanPreset: Int] = [:]
    for page in pages {
      counts[page.preset, default: 0] += 1
    }
    let ordered: [PdfScanPreset] = [
      .auto, .original, .lighten, .magicColor, .grayMode,
      .blackAndWhite, .blackAndWhite2,
    ]
    return ordered
      .compactMap { preset in
        guard let count = counts[preset], count > 0 else { return nil }
        return "\(preset.storageKey) x\(count)"
      }
      .joined(separator: ", ")
  }
}

extension PdfScanPreset {
  var storageKey: String {
    switch self {
    case .auto: return "auto"
    case .original: return "original"
    case .lighten: return "lighten"
    case .magicColor: return "magicColor"
    case .grayMode: return "grayMode"
    case .blackAndWhite: return "blackAndWhite"
    case .blackAndWhite2: return "blackAndWhite2"
    }
  }
}

extension PdfScanSource {
  var storageKey: String {
    switch self {
    case .scanner: return "scanner"
    case .photoPicker: return "photoPicker"
    }
  }
}
