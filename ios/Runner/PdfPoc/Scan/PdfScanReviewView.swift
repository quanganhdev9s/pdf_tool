import Flutter
import Foundation
import UIKit

final class PdfScanReviewPlatformViewFactory: NSObject, FlutterPlatformViewFactory {
  private let coordinator: PdfScanCoordinator

  init(coordinator: PdfScanCoordinator) {
    self.coordinator = coordinator
    super.init()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    PdfScanReviewPlatformView(frame: frame, coordinator: coordinator)
  }
}

final class PdfScanReviewPlatformView: NSObject, FlutterPlatformView {
  private let reviewView: PdfScanReviewView

  init(frame: CGRect, coordinator: PdfScanCoordinator) {
    reviewView = PdfScanReviewView(frame: frame, coordinator: coordinator)
    super.init()
  }

  func view() -> UIView {
    reviewView
  }
}

/// The review surface: a zoomable page preview above a draggable thumbnail
/// strip.
///
/// This lives natively rather than in Flutter for one measurable reason —
/// switching presets has to feel instant. Rendering here means the decoded
/// image never leaves the process, so a preset change is a redraw rather than
/// an encode, an IPC hop, a file write and a decode on the other side.
final class PdfScanReviewView: UIView {
  private let coordinator: PdfScanCoordinator

  private let previewScrollView = UIScrollView()
  private let previewImageView = UIImageView()
  private let emptyLabel = UILabel()
  private let badgeLabel = UILabel()
  private lazy var thumbnailCollectionView = UICollectionView(
    frame: .zero,
    collectionViewLayout: Self.makeThumbnailLayout()
  )

  private var sessionId: String?
  private var pages: [PdfScanPageRecord] = []
  private var currentIndex = 0
  private var isComparingOriginal = false

  /// Thumbnails are keyed by everything that changes their pixels, so a rotate
  /// or a preset change invalidates exactly the entries it should. `NSCache`
  /// vì khoá gồm cả preset lẫn góc xoay — đủ biến thể để chật bộ nhớ.
  private let thumbnailCache = NSCache<NSString, UIImage>()

  /// Riêng khỏi dải thumbnail: chung một hàng đợi tuần tự thì hai bên chặn nhau.
  private let previewQueue = DispatchQueue(label: "pdf.scan.review.preview", qos: .userInitiated)

  /// `OperationQueue` chứ không phải concurrent queue + semaphore: cách kia
  /// chặn thread ở `wait()`.
  private let thumbnailQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 3
    queue.qualityOfService = .userInitiated
    return queue
  }()

  /// `reloadData()` chạy cho mọi thay đổi session; không có tập này thì mỗi
  /// lượt lại xếp thêm một job trùng.
  private var inFlightThumbnails: Set<String> = []

  private var lastPreviewBounds: CGSize = .zero
  private var lastPreviewPageId: String?

  private static let thumbnailSize = CGSize(width: 132, height: 176)

  init(frame: CGRect, coordinator: PdfScanCoordinator) {
    self.coordinator = coordinator
    super.init(frame: frame)
    thumbnailCache.totalCostLimit = 48 * 1024 * 1024
    configure()
    coordinator.attach(reviewView: self)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    coordinator.detach(reviewView: self)
  }

  // MARK: - Layout

  private func configure() {
    backgroundColor = .systemGroupedBackground

    previewScrollView.delegate = self
    previewScrollView.minimumZoomScale = 1
    previewScrollView.maximumZoomScale = 5
    previewScrollView.showsHorizontalScrollIndicator = false
    previewScrollView.showsVerticalScrollIndicator = false
    previewScrollView.backgroundColor = .secondarySystemGroupedBackground
    addSubview(previewScrollView)

    previewImageView.contentMode = .scaleAspectFit
    previewImageView.backgroundColor = .clear
    previewScrollView.addSubview(previewImageView)

    badgeLabel.font = .systemFont(ofSize: 12, weight: .semibold)
    badgeLabel.textColor = .white
    badgeLabel.backgroundColor = UIColor.black.withAlphaComponent(0.62)
    badgeLabel.textAlignment = .center
    badgeLabel.layer.cornerRadius = 11
    badgeLabel.layer.masksToBounds = true
    badgeLabel.isHidden = true
    addSubview(badgeLabel)

    thumbnailCollectionView.backgroundColor = .systemGroupedBackground
    thumbnailCollectionView.dataSource = self
    thumbnailCollectionView.delegate = self
    thumbnailCollectionView.dragDelegate = self
    thumbnailCollectionView.dropDelegate = self
    thumbnailCollectionView.dragInteractionEnabled = true
    thumbnailCollectionView.showsHorizontalScrollIndicator = false
    thumbnailCollectionView.register(
      PdfScanThumbnailCell.self,
      forCellWithReuseIdentifier: PdfScanThumbnailCell.reuseIdentifier
    )
    addSubview(thumbnailCollectionView)

    emptyLabel.text = "No pages in this scan yet."
    emptyLabel.textAlignment = .center
    emptyLabel.numberOfLines = 0
    emptyLabel.textColor = .secondaryLabel
    emptyLabel.font = .systemFont(ofSize: 15, weight: .medium)
    addSubview(emptyLabel)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let stripHeight: CGFloat = 196
    let previewHeight = max(bounds.height - stripHeight, 0)

    previewScrollView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: previewHeight)
    thumbnailCollectionView.frame = CGRect(
      x: 0,
      y: previewHeight,
      width: bounds.width,
      height: min(stripHeight, bounds.height)
    )
    emptyLabel.frame = previewScrollView.frame.insetBy(dx: 24, dy: 24)

    badgeLabel.frame = CGRect(x: 16, y: 16, width: 92, height: 22)

    // Reset ở mọi lượt layout là xoá mức phóng người dùng đang đặt.
    if lastPreviewBounds != previewScrollView.bounds.size {
      lastPreviewBounds = previewScrollView.bounds.size
      previewScrollView.zoomScale = 1
      previewImageView.frame = previewScrollView.bounds.insetBy(dx: 12, dy: 12)
      previewScrollView.contentSize = previewScrollView.bounds.size
      updatePreview()
    }
  }

  // MARK: - Rendering

  /// Called on the main thread whenever the coordinator mutates the session.
  func render(session: PdfScanSessionRecord) {
    sessionId = session.id
    pages = session.pages
    currentIndex = session.currentPageIndex
    isComparingOriginal = session.isComparingOriginal

    let hasPages = !pages.isEmpty
    emptyLabel.isHidden = hasPages
    previewScrollView.isHidden = !hasPages
    badgeLabel.isHidden = !(hasPages && isComparingOriginal)
    badgeLabel.text = "Original"

    thumbnailCollectionView.reloadData()
    updatePreview()
  }

  /// Cập nhật đúng một trang. `render(session:)` gọi `reloadData()`, mà áp
  /// preset cho cả tập thì nó chạy một lần cho mỗi trang. Thêm/bớt trang thì
  /// quay về đường cũ.
  func renderPage(session: PdfScanSessionRecord, pageId: String) {
    guard sessionId == session.id,
          pages.count == session.pages.count,
          let index = session.pages.firstIndex(where: { $0.id == pageId }) else {
      render(session: session)
      return
    }
    pages = session.pages
    UIView.performWithoutAnimation {
      thumbnailCollectionView.reloadItems(at: [IndexPath(item: index, section: 0)])
    }
    if index == currentIndex { updatePreview() }
  }

  func renderEmpty() {
    sessionId = nil
    pages = []
    currentIndex = 0
    thumbnailCache.removeAllObjects()
    emptyLabel.isHidden = false
    previewScrollView.isHidden = true
    badgeLabel.isHidden = true
    previewImageView.image = nil
    thumbnailCollectionView.reloadData()
  }

  private func updatePreview() {
    guard currentIndex >= 0, currentIndex < pages.count else {
      previewImageView.image = nil
      return
    }
    let page = pages[currentIndex]
    if lastPreviewPageId != page.id {
      lastPreviewPageId = page.id
      previewScrollView.zoomScale = 1
    }
    let url = isComparingOriginal ? page.originalURL : page.renderURL
    let rotation = page.rotationDegrees
    // Cỡ giải mã nằm trong khoá: dùng lại bản cũ sau khi đổi bounds thì mờ.
    let targetSize = previewScrollView.bounds.size
    let key = cacheKey(
      for: page,
      size: "preview-\(Int(targetSize.width))x\(Int(targetSize.height))",
      comparing: isComparingOriginal
    )

    if let cached = thumbnailCache.object(forKey: key as NSString) {
      previewImageView.image = cached
      return
    }

    // Decode off the main thread; a full-resolution page would otherwise drop
    // frames every time the user steps between pages.
    previewQueue.async { [weak self] in
      guard let self else { return }
      let image = Self.decode(url: url, rotation: rotation, fitting: targetSize)
      DispatchQueue.main.async {
        guard self.currentIndex < self.pages.count,
              self.pages[self.currentIndex].id == page.id else {
          return
        }
        if let image {
          self.store(image, forKey: key)
        }
        self.previewImageView.image = image
      }
    }
  }

  /// Cost theo byte, để `totalCostLimit` có nghĩa.
  private func store(_ image: UIImage, forKey key: String) {
    let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
    thumbnailCache.setObject(image, forKey: key as NSString, cost: cost)
  }

  /// `comparing` chỉ đúng cho preview. Dải thumbnail luôn hiện bản đã xử lý:
  /// đưa cờ so sánh vào khoá của cả dải nghĩa là bật tắt một cái là mười
  /// thumbnail phải giải mã lại, hai lần.
  private func cacheKey(
    for page: PdfScanPageRecord,
    size: String,
    comparing: Bool = false
  ) -> String {
    let variant = comparing ? "orig" : page.preset.storageKey
    return "\(page.id)|\(variant)|\(page.rotationDegrees)|\(size)"
  }

  /// Downsamples while decoding so a 12 MP capture never becomes a full-size
  /// bitmap just to fill a thumbnail.
  private static func decode(url: URL, rotation: Int, fitting size: CGSize) -> UIImage? {
    let maxPixel = max(size.width, size.height) * UIScreen.main.scale
    guard maxPixel > 0 else { return nil }

    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      return nil
    }
    return UIImage(cgImage: thumbnail).rotated(byDegrees: rotation)
  }

  private static func makeThumbnailLayout() -> UICollectionViewLayout {
    let layout = UICollectionViewFlowLayout()
    layout.scrollDirection = .horizontal
    layout.sectionInset = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
    layout.minimumLineSpacing = 12
    layout.itemSize = thumbnailSize
    return layout
  }

  private func commitReorder() {
    guard let sessionId else { return }
    try? coordinator.reorderPages(sessionId: sessionId, pageIds: pages.map(\.id))
  }
}

extension PdfScanReviewView: UIScrollViewDelegate {
  func viewForZooming(in scrollView: UIScrollView) -> UIView? {
    previewImageView
  }
}

extension PdfScanReviewView: UICollectionViewDataSource, UICollectionViewDelegate {
  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
    pages.count
  }

  func collectionView(
    _ collectionView: UICollectionView,
    cellForItemAt indexPath: IndexPath
  ) -> UICollectionViewCell {
    let cell = collectionView.dequeueReusableCell(
      withReuseIdentifier: PdfScanThumbnailCell.reuseIdentifier,
      for: indexPath
    )
    guard let thumbnailCell = cell as? PdfScanThumbnailCell else { return cell }

    let page = pages[indexPath.item]
    let key = cacheKey(for: page, size: "thumb")
    let cached = thumbnailCache.object(forKey: key as NSString)
    thumbnailCell.configure(
      image: cached,
      title: "\(indexPath.item + 1)",
      isSelected: indexPath.item == currentIndex
    )

    if cached == nil, !inFlightThumbnails.contains(key) {
      inFlightThumbnails.insert(key)
      let url = page.renderURL
      let rotation = page.rotationDegrees
      thumbnailQueue.addOperation { [weak self] in
        guard let self else { return }
        let image = Self.decode(url: url, rotation: rotation, fitting: Self.thumbnailSize)
        DispatchQueue.main.async {
          self.inFlightThumbnails.remove(key)
          guard let image else { return }
          self.store(image, forKey: key)
          if let visible = collectionView.cellForItem(at: indexPath) as? PdfScanThumbnailCell {
            visible.configure(
              image: image,
              title: "\(indexPath.item + 1)",
              isSelected: indexPath.item == self.currentIndex
            )
          }
        }
      }
    }
    return thumbnailCell
  }

  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    guard let sessionId, indexPath.item < pages.count else { return }
    try? coordinator.showPage(sessionId: sessionId, pageId: pages[indexPath.item].id)
  }
}

extension PdfScanReviewView: UICollectionViewDragDelegate, UICollectionViewDropDelegate {
  func collectionView(
    _ collectionView: UICollectionView,
    itemsForBeginning session: UIDragSession,
    at indexPath: IndexPath
  ) -> [UIDragItem] {
    let page = pages[indexPath.item]
    let provider = NSItemProvider(object: page.id as NSString)
    let item = UIDragItem(itemProvider: provider)
    item.localObject = page
    return [item]
  }

  func collectionView(
    _ collectionView: UICollectionView,
    dropSessionDidUpdate session: UIDropSession,
    withDestinationIndexPath destinationIndexPath: IndexPath?
  ) -> UICollectionViewDropProposal {
    UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
  }

  func collectionView(
    _ collectionView: UICollectionView,
    performDropWith dropCoordinator: UICollectionViewDropCoordinator
  ) {
    let fallback = IndexPath(item: max(pages.count - 1, 0), section: 0)
    var destinationIndexPath = dropCoordinator.destinationIndexPath ?? fallback

    // Đích phải tính lại sau mỗi item: `pages` bị sửa ngay trong vòng lặp, nên
    // một chỉ số tính sẵn từ đầu sẽ lệch kể từ item thứ hai trở đi.
    for dropItem in dropCoordinator.items {
      guard let sourceIndexPath = dropItem.sourceIndexPath else { continue }
      var landed = destinationIndexPath
      collectionView.performBatchUpdates {
        let moved = pages.remove(at: sourceIndexPath.item)
        let destination = min(destinationIndexPath.item, pages.count)
        pages.insert(moved, at: destination)
        landed = IndexPath(item: destination, section: destinationIndexPath.section)
        collectionView.moveItem(at: sourceIndexPath, to: landed)
      }
      dropCoordinator.drop(dropItem.dragItem, toItemAt: landed)
      destinationIndexPath = IndexPath(
        item: min(landed.item + 1, max(pages.count - 1, 0)),
        section: landed.section
      )
    }
    commitReorder()
  }
}

final class PdfScanThumbnailCell: UICollectionViewCell {
  static let reuseIdentifier = "PdfScanThumbnailCell"

  private let imageView = UIImageView()
  private let titleLabel = UILabel()

  override init(frame: CGRect) {
    super.init(frame: frame)
    contentView.backgroundColor = .secondarySystemGroupedBackground
    contentView.layer.cornerRadius = 8
    contentView.layer.borderWidth = 2
    contentView.layer.borderColor = UIColor.clear.cgColor
    contentView.clipsToBounds = true

    imageView.contentMode = .scaleAspectFit
    imageView.backgroundColor = .systemBackground
    contentView.addSubview(imageView)

    titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
    titleLabel.textColor = .secondaryLabel
    titleLabel.textAlignment = .center
    contentView.addSubview(titleLabel)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Nếu không, cell tái sử dụng hiện ảnh trang cũ tới khi giải mã xong.
  override func prepareForReuse() {
    super.prepareForReuse()
    imageView.image = nil
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let labelHeight: CGFloat = 20
    imageView.frame = CGRect(
      x: 6,
      y: 6,
      width: contentView.bounds.width - 12,
      height: contentView.bounds.height - labelHeight - 10
    )
    titleLabel.frame = CGRect(
      x: 0,
      y: contentView.bounds.height - labelHeight - 2,
      width: contentView.bounds.width,
      height: labelHeight
    )
  }

  func configure(image: UIImage?, title: String, isSelected: Bool) {
    imageView.image = image
    titleLabel.text = title
    contentView.layer.borderColor = isSelected
      ? UIColor.systemBlue.cgColor
      : UIColor.clear.cgColor
  }
}
