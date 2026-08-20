import Flutter
import Foundation
import UIKit

/// Single owner of the scan feature: holds the session store, drives capture,
/// processing and export, and is the only place that talks to Flutter.
///
/// Deliberately independent of `PdfWorkspaceView`. The POC routed scanning
/// through the workspace, which meant a document had to already be open before
/// the user could scan; a scan session has nothing to do with an open document.
final class PdfScanCoordinator: NSObject {
  static let shared = PdfScanCoordinator()

  /// Enhancement applied automatically to every freshly captured page.
  ///
  /// Black and white wins on a badly lit page: desaturating removes the chroma
  /// noise that the shading correction amplifies out of the shadows, and the
  /// result reads as ink on paper rather than a photograph of paper. The cost is
  /// that it discards colour outright — a red stamp or a signature ends up black
  /// or gone — so the review screen still offers the other presets, and the user
  /// can switch a page or the whole session at any point.
  static let defaultPreset: PdfScanPreset = .magicColor

  private let store = PdfScanSessionStore()
  private let processor = PdfScanImageProcessor()
  private let exporter = PdfScanExporter()
  private lazy var captureManager = PdfScanCaptureManager(store: store)
  private lazy var library = PdfScanLibrary(store: store)

  private let workQueue = DispatchQueue(label: "pdf.scan.coordinator", qos: .userInitiated)
  private let stateLock = NSLock()
  private var cancelledOperationIds = Set<String>()

  private var flutterApi: PdfScanFlutterApi?
  private weak var reviewView: PdfScanReviewView?

  override init() {
    super.init()
    captureManager.delegate = self
  }

  // MARK: - Wiring

  func configure(binaryMessenger: FlutterBinaryMessenger) {
    flutterApi = PdfScanFlutterApi(binaryMessenger: binaryMessenger)
    PdfScanHostApiSetup.setUp(binaryMessenger: binaryMessenger, api: PdfScanHostApiImpl(coordinator: self))
    // Reclaim anything a previous run left behind before the user starts a new
    // session, so abandoned captures cannot accumulate indefinitely.
    workQueue.async { [store] in
      store.sweepOrphanedSessions()
    }
  }

  func attach(reviewView: PdfScanReviewView) {
    self.reviewView = reviewView
    if let session = activeSession {
      reviewView.render(session: session)
    }
  }

  func detach(reviewView: PdfScanReviewView) {
    if self.reviewView === reviewView {
      self.reviewView = nil
    }
  }

  private(set) var activeSession: PdfScanSessionRecord?

  // MARK: - Capture

  func startDocumentCapture() throws {
    try captureManager.startDocumentCapture(presenter: try requirePresenter())
  }

  func pickScanImages() throws {
    try captureManager.pickScanImages(presenter: try requirePresenter())
  }

  // MARK: - Page operations

  func pages(inSession sessionId: String) throws -> [PdfScanPageInfo] {
    try store.requireSession(withId: sessionId).pageInfos
  }

  func rotatePage(sessionId: String, pageId: String, degrees: Int) throws {
    let session = try store.requireSession(withId: sessionId)
    guard let page = session.page(withId: pageId) else {
      throw Self.pageNotFound(pageId)
    }
    page.rotationDegrees = (((page.rotationDegrees + degrees) % 360) + 360) % 360
    logPdfEvent("scan_page_rotated", "pageId=\(pageId) rotation=\(page.rotationDegrees)")
    refresh(session: session)
  }

  func deletePage(sessionId: String, pageId: String) throws {
    let session = try store.requireSession(withId: sessionId)
    guard let index = session.index(ofPageId: pageId) else {
      throw Self.pageNotFound(pageId)
    }
    let page = session.pages.remove(at: index)
    store.removeFiles(for: page)
    session.normalizeCurrentPageIndex()
    logPdfEvent("scan_page_deleted", "pageId=\(pageId) remaining=\(session.pages.count)")
    refresh(session: session)
  }

  func reorderPages(sessionId: String, pageIds: [String]) throws {
    let session = try store.requireSession(withId: sessionId)
    var reordered: [PdfScanPageRecord] = []
    reordered.reserveCapacity(session.pages.count)
    for pageId in pageIds {
      guard let page = session.page(withId: pageId) else {
        throw Self.pageNotFound(pageId)
      }
      reordered.append(page)
    }
    guard reordered.count == session.pages.count else {
      throw PdfPocError(
        code: "invalid_page_operation",
        message: "The new page order must list every page exactly once.",
        details: "expected=\(session.pages.count) received=\(reordered.count)"
      )
    }
    session.pages = reordered
    session.normalizeCurrentPageIndex()
    logPdfEvent("scan_pages_reordered", "sessionId=\(sessionId)")
    refresh(session: session)
  }

  func showPage(sessionId: String, pageId: String) throws {
    let session = try store.requireSession(withId: sessionId)
    guard let index = session.index(ofPageId: pageId) else {
      throw Self.pageNotFound(pageId)
    }
    session.currentPageIndex = index
    refresh(session: session)
  }

  func setComparingOriginal(sessionId: String, comparing: Bool) throws {
    let session = try store.requireSession(withId: sessionId)
    session.isComparingOriginal = comparing
    DispatchQueue.main.async { [weak self] in
      self?.reviewView?.render(session: session)
    }
  }

  // MARK: - Processing

  func applyPreset(sessionId: String, pageId: String, preset: PdfScanPreset) throws {
    let session = try store.requireSession(withId: sessionId)
    guard let page = session.page(withId: pageId) else {
      throw Self.pageNotFound(pageId)
    }
    processPages([page], in: session, preset: preset, operationId: UUID().uuidString)
  }

  func applyPresetToAll(sessionId: String, preset: PdfScanPreset) throws {
    let session = try store.requireSession(withId: sessionId)
    processPages(session.pages, in: session, preset: preset, operationId: UUID().uuidString)
  }

  /// Processes serially inside an autorelease pool. Running a whole session in
  /// parallel at full resolution is the reliable way to get killed for memory.
  private func processPages(
    _ pages: [PdfScanPageRecord],
    in session: PdfScanSessionRecord,
    preset: PdfScanPreset,
    operationId: String
  ) {
    let total = Int64(pages.count)
    workQueue.async { [weak self] in
      guard let self else { return }
      for (offset, page) in pages.enumerated() {
        if self.isCancelled(operationId) { break }
        autoreleasepool {
          do {
            page.discardProcessedImage()
            if preset == .original {
              page.preset = .original
            } else {
              let destination = self.store.processedImageURL(for: session, pageId: page.id)
              try self.processor.process(page: page, preset: preset, destination: destination)
              page.preset = preset
              page.processedURL = destination
            }
            DispatchQueue.main.async {
              self.emitPageProcessed(session: session, page: page)
              self.reviewView?.render(session: session)
            }
          } catch let error as PdfPocError {
            DispatchQueue.main.async { self.emitFailure(operationId: operationId, error: error) }
          } catch {
            DispatchQueue.main.async {
              self.emitFailure(
                operationId: operationId,
                error: PdfPocError(
                  code: "scan_processing_failed",
                  message: "Could not enhance a page.",
                  details: error.localizedDescription
                )
              )
            }
          }
        }
        DispatchQueue.main.async {
          self.flutterApi?.onScanProgress(
            operationId: operationId,
            completedPages: Int64(offset + 1),
            totalPages: total
          ) { _ in }
        }
      }
      self.clearCancellation(operationId)
    }
  }

  // MARK: - Export

  func exportSession(request: PdfScanExportRequest) throws {
    let session = try store.requireSession(withId: request.sessionId)
    let trimmed = request.outputPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let outputURL = trimmed.isEmpty
      ? store.defaultExportURL(for: session)
      : URL(fileURLWithPath: trimmed)
    let operationId = UUID().uuidString

    workQueue.async { [weak self] in
      guard let self else { return }
      do {
        let result = try self.exporter.export(
          session: session,
          quality: request.quality,
          outputURL: outputURL,
          operationId: operationId,
          isCancelled: { self.isCancelled(operationId) },
          onProgress: { completed, total in
            DispatchQueue.main.async {
              self.flutterApi?.onScanProgress(
                operationId: operationId,
                completedPages: completed,
                totalPages: total
              ) { _ in }
            }
          }
        )
        DispatchQueue.main.async {
          self.flutterApi?.onScanExportCompleted(
            operationId: operationId,
            result: result,
            cancelled: false
          ) { _ in }
        }
      } catch let error as PdfPocError where error.code == "scan_cancelled" {
        DispatchQueue.main.async {
          self.flutterApi?.onScanExportCompleted(
            operationId: operationId,
            result: nil,
            cancelled: true
          ) { _ in }
        }
      } catch let error as PdfPocError {
        DispatchQueue.main.async { self.emitFailure(operationId: operationId, error: error) }
      } catch {
        DispatchQueue.main.async {
          self.emitFailure(
            operationId: operationId,
            error: PdfPocError(
              code: "scan_export_failed",
              message: "Exporting the scan failed.",
              details: error.localizedDescription
            )
          )
        }
      }
      self.clearCancellation(operationId)
    }
  }

  // MARK: - Library

  func listExportedScans() -> [PdfScanExportedDocument] {
    library.exportedDocuments()
  }

  func openExportedScan(path: String) throws {
    try library.open(path: path, presenter: try requirePresenter())
  }

  func shareExportedScan(path: String) throws {
    try library.share(path: path, presenter: try requirePresenter())
  }

  func deleteExportedScan(path: String) throws {
    try library.delete(path: path)
  }

  // MARK: - Cancellation and teardown

  func cancelOperation(operationId: String) {
    stateLock.lock()
    cancelledOperationIds.insert(operationId)
    stateLock.unlock()
    captureManager.cancel()
    logPdfEvent("scan_operation_cancel_requested", "operationId=\(operationId)")
  }

  func discardSession(sessionId: String) {
    if activeSession?.id == sessionId {
      activeSession = nil
      DispatchQueue.main.async { [weak self] in
        self?.reviewView?.renderEmpty()
      }
    }
    store.discardSession(withId: sessionId)
  }

  private func isCancelled(_ operationId: String) -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return cancelledOperationIds.contains(operationId)
  }

  private func clearCancellation(_ operationId: String) {
    stateLock.lock()
    cancelledOperationIds.remove(operationId)
    stateLock.unlock()
  }

  // MARK: - Callbacks

  private func refresh(session: PdfScanSessionRecord) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.reviewView?.render(session: session)
      self.flutterApi?.onScanPagesChanged(
        sessionId: session.id,
        pages: session.pageInfos
      ) { _ in }
      self.flutterApi?.onScanCurrentPageChanged(
        sessionId: session.id,
        pageIndex: Int64(session.currentPageIndex),
        pageCount: Int64(session.pages.count)
      ) { _ in }
    }
  }

  private func emitPageProcessed(session: PdfScanSessionRecord, page: PdfScanPageRecord) {
    guard let index = session.index(ofPageId: page.id) else { return }
    flutterApi?.onScanPageProcessed(
      sessionId: session.id,
      page: PdfScanPageInfo(
        pageId: page.id,
        index: Int64(index),
        preset: page.preset,
        rotationDegrees: Int64(page.rotationDegrees)
      )
    ) { _ in }
  }

  private func emitFailure(operationId: String, error: PdfPocError) {
    logPdfEvent("scan_operation_failed", "operationId=\(operationId) code=\(error.code)")
    flutterApi?.onScanOperationFailed(
      operationId: operationId,
      code: error.code,
      message: error.message,
      details: error.details
    ) { _ in }
  }

  private func requirePresenter() throws -> UIViewController {
    guard let presenter = Self.topViewController() else {
      throw PdfPocError(
        code: "internal_error",
        message: "Could not find a view controller to present the scanner from.",
        details: nil
      )
    }
    return presenter
  }

  /// Scanning starts from Flutter, so there is no native view to walk up from.
  private static func topViewController() -> UIViewController? {
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
    guard var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
      return nil
    }
    while let presented = top.presentedViewController {
      top = presented
    }
    return top
  }

  private static func pageNotFound(_ pageId: String) -> PdfPocError {
    PdfPocError(
      code: "scan_page_not_found",
      message: "That page is no longer part of the scan session.",
      details: "pageId=\(pageId)"
    )
  }
}

extension PdfScanCoordinator: PdfScanCaptureManagerDelegate {
  func captureManager(_ manager: PdfScanCaptureManager, didCreate session: PdfScanSessionRecord) {
    activeSession = session
    flutterApi?.onScanSessionCreated(info: session.info) { _ in }
    reviewView?.render(session: session)

    guard Self.defaultPreset != .original else { return }
    logPdfEvent(
      "scan_default_preset_apply",
      "sessionId=\(session.id) preset=\(Self.defaultPreset.storageKey) pages=\(session.pages.count)"
    )
    processPages(
      session.pages,
      in: session,
      preset: Self.defaultPreset,
      operationId: UUID().uuidString
    )
  }

  func captureManagerDidCancel(_ manager: PdfScanCaptureManager) {
    flutterApi?.onScanSessionCancelled { _ in }
  }

  func captureManager(_ manager: PdfScanCaptureManager, didFailWith error: PdfPocError) {
    emitFailure(operationId: "capture", error: error)
  }
}
