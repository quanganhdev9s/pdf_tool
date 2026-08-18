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
  /// or a preset change invalidates exactly the entries it should.
  private var thumbnailCache: [String: UIImage] = [:]
  private let renderQueue = DispatchQueue(label: "pdf.scan.review.render", qos: .userInitiated)

  private static let thumbnailSize = CGSize(width: 132, height: 176)

  init(frame: CGRect, coordinator: PdfScanCoordinator) {
    self.coordinator = coordinator
    super.init(frame: frame)
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

    previewScrollView.zoomScale = 1
    previewImageView.frame = previewScrollView.bounds.insetBy(dx: 12, dy: 12)
    previewScrollView.contentSize = previewScrollView.bounds.size
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

  func renderEmpty() {
    sessionId = nil
    pages = []
    currentIndex = 0
    thumbnailCache.removeAll()
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
    let url = isComparingOriginal ? page.originalURL : page.renderURL
    let rotation = page.rotationDegrees
    let key = cacheKey(for: page, size: "preview")

    if let cached = thumbnailCache[key] {
      previewImageView.image = cached
      return
    }

    // Decode off the main thread; a full-resolution page would otherwise drop
    // frames every time the user steps between pages.
    let targetSize = previewScrollView.bounds.size
    renderQueue.async { [weak self] in
      guard let self else { return }
      let image = Self.decode(url: url, rotation: rotation, fitting: targetSize)
      DispatchQueue.main.async {
        guard self.currentIndex < self.pages.count,
              self.pages[self.currentIndex].id == page.id else {
          return
        }
        if let image {
          self.thumbnailCache[key] = image
        }
        self.previewImageView.image = image
      }
    }
  }

  private func cacheKey(for page: PdfScanPageRecord, size: String) -> String {
    let variant = isComparingOriginal ? "orig" : page.preset.storageKey
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
    thumbnailCell.configure(
      image: thumbnailCache[key],
      title: "\(indexPath.item + 1)",
      isSelected: indexPath.item == currentIndex
    )

    if thumbnailCache[key] == nil {
      let url = isComparingOriginal ? page.originalURL : page.renderURL
      let rotation = page.rotationDegrees
      renderQueue.async { [weak self] in
        guard let self else { return }
        let image = Self.decode(url: url, rotation: rotation, fitting: Self.thumbnailSize)
        DispatchQueue.main.async {
          guard let image else { return }
          self.thumbnailCache[key] = image
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
    let destinationIndexPath = dropCoordinator.destinationIndexPath
      ?? IndexPath(item: max(pages.count - 1, 0), section: 0)

    for dropItem in dropCoordinator.items {
      guard let sourceIndexPath = dropItem.sourceIndexPath else { continue }
      collectionView.performBatchUpdates {
        let moved = pages.remove(at: sourceIndexPath.item)
        let destination = min(destinationIndexPath.item, pages.count)
        pages.insert(moved, at: destination)
        collectionView.moveItem(
          at: sourceIndexPath,
          to: IndexPath(item: destination, section: destinationIndexPath.section)
        )
      }
      dropCoordinator.drop(
        dropItem.dragItem,
        toItemAt: IndexPath(
          item: min(destinationIndexPath.item, max(pages.count - 1, 0)),
          section: destinationIndexPath.section
        )
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
