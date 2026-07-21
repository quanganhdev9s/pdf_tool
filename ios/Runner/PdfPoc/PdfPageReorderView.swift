import Flutter
import PDFKit
import UIKit

final class PdfPageReorderPlatformViewFactory: NSObject, FlutterPlatformViewFactory {
  private let runtime: PdfPocRuntime

  init(runtime: PdfPocRuntime) {
    self.runtime = runtime
    super.init()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    PdfPageReorderPlatformView(frame: frame, runtime: runtime)
  }
}

final class PdfPageReorderPlatformView: NSObject, FlutterPlatformView {
  private let reorderView: PdfPageReorderView

  init(frame: CGRect, runtime: PdfPocRuntime) {
    reorderView = PdfPageReorderView(frame: frame, runtime: runtime)
    super.init()
  }

  func view() -> UIView {
    reorderView
  }
}

final class PdfPageReorderView: UIView {
  private let runtime: PdfPocRuntime
  private let statusLabel = UILabel()
  private var items: [PdfPageReorderPreview] = []
  private lazy var collectionView = UICollectionView(
    frame: .zero,
    collectionViewLayout: makeLayout()
  )

  init(frame: CGRect, runtime: PdfPocRuntime) {
    self.runtime = runtime
    super.init(frame: frame)
    configure()
    reloadPages()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    collectionView.frame = bounds
    statusLabel.frame = bounds.insetBy(dx: 24, dy: 24)
  }

  private func configure() {
    backgroundColor = .systemBackground
    collectionView.backgroundColor = .systemBackground
    collectionView.dataSource = self
    collectionView.delegate = self
    collectionView.dragDelegate = self
    collectionView.dropDelegate = self
    collectionView.dragInteractionEnabled = true
    collectionView.alwaysBounceVertical = true
    collectionView.register(
      PdfPageReorderCell.self,
      forCellWithReuseIdentifier: PdfPageReorderCell.reuseIdentifier
    )
    addSubview(collectionView)

    statusLabel.isHidden = true
    statusLabel.textAlignment = .center
    statusLabel.numberOfLines = 0
    statusLabel.textColor = .secondaryLabel
    statusLabel.font = UIFont.systemFont(ofSize: 15, weight: .medium)
    addSubview(statusLabel)
  }

  private func reloadPages() {
    do {
      items = try runtime.requireWorkspace().pageReorderPreviews(
        maxPixelSize: CGSize(width: 220, height: 300)
      )
      runtime.setPendingPageReorder(items.map(\.pageIndex))
      statusLabel.isHidden = true
      collectionView.reloadData()
      logPdfEvent("page_reorder_view_loaded", "pages=\(items.count)")
    } catch let error as PdfPocError {
      showError(error.message)
      runtime.clearPendingPageReorder()
    } catch {
      showError(error.localizedDescription)
      runtime.clearPendingPageReorder()
    }
  }

  private func showError(_ message: String) {
    items = []
    collectionView.reloadData()
    statusLabel.text = message
    statusLabel.isHidden = false
    logPdfEvent("page_reorder_view_error", message)
  }

  private func updatePendingOrder() {
    let order = items.map(\.pageIndex)
    runtime.setPendingPageReorder(order)
    logPdfEvent("page_reorder_order_changed", "order=\(order)")
  }

  private func makeLayout() -> UICollectionViewLayout {
    let layout = UICollectionViewFlowLayout()
    layout.sectionInset = UIEdgeInsets(top: 16, left: 16, bottom: 24, right: 16)
    layout.minimumLineSpacing = 16
    layout.minimumInteritemSpacing = 12
    return layout
  }
}

extension PdfPageReorderView: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
    items.count
  }

  func collectionView(
    _ collectionView: UICollectionView,
    cellForItemAt indexPath: IndexPath
  ) -> UICollectionViewCell {
    let cell = collectionView.dequeueReusableCell(
      withReuseIdentifier: PdfPageReorderCell.reuseIdentifier,
      for: indexPath
    )
    guard let reorderCell = cell as? PdfPageReorderCell else {
      return cell
    }
    let item = items[indexPath.item]
    reorderCell.configure(
      image: item.thumbnail,
      title: "Page \(item.pageIndex + 1)"
    )
    return reorderCell
  }

  func collectionView(
    _ collectionView: UICollectionView,
    layout collectionViewLayout: UICollectionViewLayout,
    sizeForItemAt indexPath: IndexPath
  ) -> CGSize {
    let columns: CGFloat = bounds.width >= 700 ? 4 : 2
    let horizontalInsets: CGFloat = 32
    let spacing = (columns - 1) * 12
    let width = floor((bounds.width - horizontalInsets - spacing) / columns)
    return CGSize(width: max(width, 120), height: max(width * 1.38, 168))
  }
}

extension PdfPageReorderView: UICollectionViewDragDelegate, UICollectionViewDropDelegate {
  func collectionView(
    _ collectionView: UICollectionView,
    itemsForBeginning session: UIDragSession,
    at indexPath: IndexPath
  ) -> [UIDragItem] {
    let item = items[indexPath.item]
    let provider = NSItemProvider(object: "\(item.pageIndex)" as NSString)
    let dragItem = UIDragItem(itemProvider: provider)
    dragItem.localObject = item
    return [dragItem]
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
    performDropWith coordinator: UICollectionViewDropCoordinator
  ) {
    let destinationIndexPath = coordinator.destinationIndexPath
      ?? IndexPath(item: items.count - 1, section: 0)

    for dropItem in coordinator.items {
      guard let sourceIndexPath = dropItem.sourceIndexPath else {
        continue
      }
      collectionView.performBatchUpdates {
        let movedItem = items.remove(at: sourceIndexPath.item)
        let destinationItem = min(destinationIndexPath.item, items.count)
        items.insert(movedItem, at: destinationItem)
        collectionView.moveItem(
          at: sourceIndexPath,
          to: IndexPath(item: destinationItem, section: destinationIndexPath.section)
        )
      }
      coordinator.drop(
        dropItem.dragItem,
        toItemAt: IndexPath(
          item: min(destinationIndexPath.item, items.count - 1),
          section: destinationIndexPath.section
        )
      )
    }
    updatePendingOrder()
  }
}

final class PdfPageReorderCell: UICollectionViewCell {
  static let reuseIdentifier = "PdfPageReorderCell"

  private let imageView = UIImageView()
  private let titleLabel = UILabel()

  override init(frame: CGRect) {
    super.init(frame: frame)
    configure()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    titleLabel.frame = CGRect(
      x: 8,
      y: bounds.height - 30,
      width: bounds.width - 16,
      height: 22
    )
    imageView.frame = CGRect(
      x: 8,
      y: 8,
      width: bounds.width - 16,
      height: max(titleLabel.frame.minY - 16, 0)
    )
  }

  func configure(image: UIImage, title: String) {
    imageView.image = image
    titleLabel.text = title
  }

  private func configure() {
    contentView.backgroundColor = .secondarySystemBackground
    contentView.layer.cornerRadius = 8
    contentView.layer.borderColor = UIColor.separator.cgColor
    contentView.layer.borderWidth = 1
    contentView.clipsToBounds = true

    imageView.contentMode = .scaleAspectFit
    imageView.backgroundColor = .white
    imageView.layer.borderColor = UIColor.separator.cgColor
    imageView.layer.borderWidth = 1
    contentView.addSubview(imageView)

    titleLabel.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
    titleLabel.textAlignment = .center
    titleLabel.textColor = .label
    contentView.addSubview(titleLabel)
  }
}
