import CoreGraphics
import Foundation

/// One captured page. `originalURL` is written once at capture and never
/// mutated: every preset change reprocesses from it, so switching presets
/// cannot compound one enhancement on top of another.
final class PdfScanPageRecord {
  let id: String
  let originalURL: URL

  /// Ba trường dưới đây bị ghi từ hàng đợi xử lý ảnh và đọc từ main cùng lúc,
  /// nên đi qua khoá. Khoá đệ quy vì `renderURL` đọc hai trường trong một lượt.
  private let lock = NSRecursiveLock()
  private var _processedURL: URL?
  private var _preset: PdfScanPreset
  private var _rotationDegrees: Int

  init(
    id: String = UUID().uuidString,
    originalURL: URL,
    processedURL: URL? = nil,
    preset: PdfScanPreset = .original,
    rotationDegrees: Int = 0
  ) {
    self.id = id
    self.originalURL = originalURL
    self._processedURL = processedURL
    self._preset = preset
    self._rotationDegrees = rotationDegrees
  }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  var processedURL: URL? {
    get { locked { _processedURL } }
    set { locked { _processedURL = newValue } }
  }

  var preset: PdfScanPreset {
    get { locked { _preset } }
    set { locked { _preset = newValue } }
  }

  var rotationDegrees: Int {
    get { locked { _rotationDegrees } }
    set { locked { _rotationDegrees = newValue } }
  }

  /// The image the export and the review canvas should draw. Falls back to the
  /// original whenever processing has not run or was discarded.
  ///
  /// `fileExists` ở đây là đường lui cho trường hợp hệ thống dọn thư mục cache
  /// khi máy hết chỗ, chứ không phải thừa.
  var renderURL: URL {
    locked {
      if _preset != .original,
         let url = _processedURL,
         FileManager.default.fileExists(atPath: url.path) {
        return url
      }
      return originalURL
    }
  }

  func discardProcessedImage() {
    locked {
      if let url = _processedURL {
        try? FileManager.default.removeItem(at: url)
      }
      _processedURL = nil
    }
  }
}

/// A capture-to-export unit. Pages live on disk under `directory` so a session
/// survives the app being backgrounded mid-review.
final class PdfScanSessionRecord {
  let id: String
  let createdAt: Date
  let source: PdfScanSource
  let directory: URL

  /// `pages` bị thêm từ hàng đợi chụp, bị xoá và đổi thứ tự từ main, còn từng
  /// trang thì bị hàng đợi xử lý ảnh ghi vào. Trước đây không có đồng bộ nào,
  /// nên đây là nguồn của những lần crash không tái hiện được.
  private let lock = NSRecursiveLock()
  private var _pages: [PdfScanPageRecord]
  private var _currentPageIndex: Int
  private var _isComparingOriginal: Bool

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
    self._pages = pages
    self._currentPageIndex = currentPageIndex
    self._isComparingOriginal = isComparingOriginal
  }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  var pages: [PdfScanPageRecord] {
    get { locked { _pages } }
    set { locked { _pages = newValue } }
  }

  var currentPageIndex: Int {
    get { locked { _currentPageIndex } }
    set { locked { _currentPageIndex = newValue } }
  }

  var isComparingOriginal: Bool {
    get { locked { _isComparingOriginal } }
    set { locked { _isComparingOriginal = newValue } }
  }

  /// Gộp nhiều thay đổi thành một lượt. Xoá một trang rồi kẹp lại chỉ số trang
  /// hiện tại là hai thao tác, mà luồng khác không được phép nhìn thấy khoảng
  /// giữa hai thao tác đó.
  func mutate<T>(_ body: () -> T) -> T {
    locked(body)
  }

  /// Thêm trang là đọc rồi ghi, nên phải là một thao tác chứ không phải
  /// `pages.append` qua thuộc tính tính toán.
  func appendPage(_ page: PdfScanPageRecord) {
    locked { _pages.append(page) }
  }

  @discardableResult
  func removePage(at index: Int) -> PdfScanPageRecord {
    locked { _pages.remove(at: index) }
  }

  var originalsDirectory: URL { directory.appendingPathComponent("original", isDirectory: true) }
  var processedDirectory: URL { directory.appendingPathComponent("processed", isDirectory: true) }

  func page(withId pageId: String) -> PdfScanPageRecord? {
    locked { _pages.first { $0.id == pageId } }
  }

  func index(ofPageId pageId: String) -> Int? {
    locked { _pages.firstIndex { $0.id == pageId } }
  }

  /// Clamps into a valid range after a delete, so the review canvas never ends
  /// up pointing past the end of the list.
  func normalizeCurrentPageIndex() {
    locked {
      if _pages.isEmpty {
        _currentPageIndex = 0
      } else {
        _currentPageIndex = min(max(_currentPageIndex, 0), _pages.count - 1)
      }
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
