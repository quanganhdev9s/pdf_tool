import Foundation

/// Owns the on-disk layout of scan sessions and the in-memory index of them.
///
/// Sessions live under Caches rather than Documents: they are reconstructable
/// working state, must not sync to iCloud, and the system is allowed to reclaim
/// them under storage pressure. Layout is one directory per session:
///
///     <caches>/pdf_scan_sessions/<sessionId>/original/<pageId>.jpg
///                                           /processed/<pageId>.jpg
///
/// Access is serialised with a lock because capture callbacks land on the main
/// thread while processing and export run on background queues.
final class PdfScanSessionStore {
  /// Sessions older than this are swept at launch. A user who backgrounds the
  /// app mid-review gets their session back; an abandoned one does not leak.
  private static let sessionLifetime: TimeInterval = 24 * 60 * 60

  private let fileManager = FileManager.default
  private let lock = NSLock()
  private var sessions: [String: PdfScanSessionRecord] = [:]

  private lazy var rootDirectory: URL = {
    let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    return caches.appendingPathComponent("pdf_scan_sessions", isDirectory: true)
  }()

  // MARK: - Lifecycle

  func createSession(source: PdfScanSource) throws -> PdfScanSessionRecord {
    let id = UUID().uuidString
    let directory = rootDirectory.appendingPathComponent(id, isDirectory: true)
    let session = PdfScanSessionRecord(
      id: id,
      createdAt: Date(),
      source: source,
      directory: directory
    )
    do {
      try fileManager.createDirectory(at: session.originalsDirectory, withIntermediateDirectories: true)
      try fileManager.createDirectory(at: session.processedDirectory, withIntermediateDirectories: true)
    } catch {
      throw PdfPocError(
        code: "scan_storage_failed",
        message: "Could not create storage for the scan session.",
        details: error.localizedDescription
      )
    }

    lock.lock()
    sessions[id] = session
    lock.unlock()

    logPdfEvent("scan_session_created", "sessionId=\(id) source=\(source.storageKey)")
    return session
  }

  func session(withId sessionId: String) -> PdfScanSessionRecord? {
    lock.lock()
    defer { lock.unlock() }
    return sessions[sessionId]
  }

  func requireSession(withId sessionId: String) throws -> PdfScanSessionRecord {
    guard let session = session(withId: sessionId) else {
      throw PdfPocError(
        code: "scan_session_not_found",
        message: "That scan session is no longer available.",
        details: "sessionId=\(sessionId)"
      )
    }
    return session
  }

  func discardSession(withId sessionId: String) {
    lock.lock()
    let session = sessions.removeValue(forKey: sessionId)
    lock.unlock()

    guard let session else { return }
    try? fileManager.removeItem(at: session.directory)
    logPdfEvent("scan_session_discarded", "sessionId=\(sessionId)")
  }

  // MARK: - Page files

  /// Destination for a freshly captured page. Capture writes here directly so
  /// no full-resolution image is ever held in memory longer than one page.
  func originalImageURL(for session: PdfScanSessionRecord, pageId: String, fileExtension: String = "jpg") -> URL {
    session.originalsDirectory.appendingPathComponent("\(pageId).\(fileExtension)")
  }

  func processedImageURL(for session: PdfScanSessionRecord, pageId: String) -> URL {
    session.processedDirectory.appendingPathComponent("\(pageId).jpg")
  }

  func removeFiles(for page: PdfScanPageRecord) {
    try? fileManager.removeItem(at: page.originalURL)
    if let processedURL = page.processedURL {
      try? fileManager.removeItem(at: processedURL)
    }
  }

  // MARK: - Orphan sweep

  /// Deletes session directories left behind by a crash or a force-quit.
  /// Called once at launch; never relies on `discardSession` having run.
  func sweepOrphanedSessions() {
    guard let entries = try? fileManager.contentsOfDirectory(
      at: rootDirectory,
      includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) else {
      return
    }

    lock.lock()
    let liveIds = Set(sessions.keys)
    lock.unlock()

    let cutoff = Date().addingTimeInterval(-Self.sessionLifetime)
    var swept = 0
    for entry in entries {
      let id = entry.lastPathComponent
      guard !liveIds.contains(id) else { continue }

      let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
      let modified = values?.contentModificationDate ?? .distantPast
      guard modified < cutoff else { continue }

      try? fileManager.removeItem(at: entry)
      swept += 1
    }

    if swept > 0 {
      logPdfEvent("scan_sessions_swept", "count=\(swept)")
    }
  }

  /// Where finished PDFs live.
  ///
  /// Documents, not the session directory: an export is the thing the user came
  /// for, and the session directory is deleted when they discard the scan and
  /// swept by age regardless. Writing exports there meant a successful export
  /// could vanish.
  lazy var exportsDirectory: URL = {
    let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let directory = documents.appendingPathComponent("Scans", isDirectory: true)
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }()

  /// Default export destination when Flutter does not name one. Timestamped so
  /// the library list reads chronologically without opening any file.
  func defaultExportURL(for session: PdfScanSessionRecord) -> URL {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd_HHmmss"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    let name = "Scan_\(formatter.string(from: Date()))"

    var candidate = exportsDirectory.appendingPathComponent("\(name).pdf")
    var suffix = 2
    while fileManager.fileExists(atPath: candidate.path) {
      candidate = exportsDirectory.appendingPathComponent("\(name)_\(suffix).pdf")
      suffix += 1
    }
    return candidate
  }

  /// Newest first. Reads only what the filesystem already knows; page counts
  /// come from PDFKit at the call site.
  func exportedDocumentURLs() -> [URL] {
    let entries = (try? fileManager.contentsOfDirectory(
      at: exportsDirectory,
      includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
      options: [.skipsHiddenFiles]
    )) ?? []

    return entries
      .filter { $0.pathExtension.lowercased() == "pdf" }
      .sorted { lhs, rhs in
        let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
          .contentModificationDate ?? .distantPast
        let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
          .contentModificationDate ?? .distantPast
        return l > r
      }
  }
}
