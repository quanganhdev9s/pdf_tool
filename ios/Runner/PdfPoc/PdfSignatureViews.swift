import PencilKit
import UIKit

final class PdfSignatureCaptureView: UIView {
  let canvasView = PKCanvasView()

  private let titleLabel = UILabel()

  override init(frame: CGRect) {
    super.init(frame: frame)
    configure()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configure()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    titleLabel.frame = CGRect(x: 12, y: 10, width: bounds.width - 24, height: 24)
    canvasView.frame = CGRect(
      x: 12,
      y: 42,
      width: max(bounds.width - 24, 0),
      height: max(bounds.height - 54, 0)
    )
    canvasView.contentSize = canvasView.bounds.size
  }

  func show(drawing: PKDrawing?) {
    canvasView.drawing = drawing ?? PKDrawing()
    isHidden = false
    canvasView.becomeFirstResponder()
  }

  func hideCapture() {
    canvasView.resignFirstResponder()
    isHidden = true
  }

  func clear() {
    canvasView.drawing = PKDrawing()
  }

  private func configure() {
    isHidden = true
    backgroundColor = UIColor.systemBackground.withAlphaComponent(0.96)
    layer.borderColor = UIColor.separator.cgColor
    layer.borderWidth = 1
    layer.cornerRadius = 8
    clipsToBounds = true

    titleLabel.text = "Draw electronic signature"
    titleLabel.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
    titleLabel.textColor = .secondaryLabel
    titleLabel.textAlignment = .center
    addSubview(titleLabel)

    canvasView.backgroundColor = .clear
    canvasView.isOpaque = false
    canvasView.drawingPolicy = .anyInput
    canvasView.minimumZoomScale = 1
    canvasView.maximumZoomScale = 1
    canvasView.isScrollEnabled = false
    canvasView.contentInset = .zero
    canvasView.tool = PKInkingTool(.pen, color: .label, width: 3)
    addSubview(canvasView)
  }
}

final class PdfSignaturePlacementView: UIImageView, UIGestureRecognizerDelegate {
  private lazy var placementPanGesture = UIPanGestureRecognizer(
    target: self,
    action: #selector(handlePan(_:))
  )
  private lazy var placementPinchGesture = UIPinchGestureRecognizer(
    target: self,
    action: #selector(handlePinch(_:))
  )

  override init(frame: CGRect) {
    super.init(frame: frame)
    configure()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configure()
  }

  var isActive: Bool {
    !isHidden
  }

  func begin(image: UIImage, frame: CGRect) {
    self.image = image
    self.frame = frame
    isHidden = false
  }

  func cancel() {
    isHidden = true
    image = nil
  }

  func resize(by scale: CGFloat, containerBounds: CGRect) {
    let currentFrame = frame
    let newWidth = min(max(currentFrame.width * scale, 80), max(containerBounds.width - 32, 80))
    let aspect = currentFrame.height / max(currentFrame.width, 1)
    let newHeight = min(max(newWidth * aspect, 40), max(containerBounds.height - 32, 40))
    frame = CGRect(
      x: currentFrame.midX - newWidth / 2,
      y: currentFrame.midY - newHeight / 2,
      width: newWidth,
      height: newHeight
    )
  }

  private func configure() {
    isHidden = true
    isUserInteractionEnabled = true
    contentMode = .scaleAspectFit
    backgroundColor = UIColor.systemYellow.withAlphaComponent(0.12)
    layer.borderColor = UIColor.systemBlue.cgColor
    layer.borderWidth = 2
    layer.cornerRadius = 4
    clipsToBounds = true
    placementPanGesture.delegate = self
    placementPinchGesture.delegate = self
    addGestureRecognizer(placementPanGesture)
    addGestureRecognizer(placementPinchGesture)
  }

  @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
    guard isActive, let superview else { return }
    let translation = recognizer.translation(in: superview)
    center = CGPoint(x: center.x + translation.x, y: center.y + translation.y)
    recognizer.setTranslation(.zero, in: superview)
    logPdfEvent("signature_placement_pan", "frame=\(frame)")
  }

  @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
    guard isActive, let superview else { return }
    resize(by: recognizer.scale, containerBounds: superview.bounds)
    recognizer.scale = 1
    logPdfEvent("signature_placement_pinch", "frame=\(frame)")
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    let gestures: Set<UIGestureRecognizer> = [
      placementPanGesture,
      placementPinchGesture,
    ]
    return gestures.contains(gestureRecognizer) && gestures.contains(otherGestureRecognizer)
  }
}
