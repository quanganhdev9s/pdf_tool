import UIKit

/// Lets the user drag the four corners the detector picked.
///
/// Exists because detection is a guess and sometimes a wrong one — a page on a
/// patterned desk, a folded corner, a shadow the segmentation reads as an edge.
/// Rather than make the user re-shoot and hope for better luck, this shows the
/// *uncorrected* capture with the quad drawn on it and lets them move the
/// corners onto the page they can see.
///
/// It edits the last captured page only. Editing an arbitrary page would mean
/// keeping every uncorrected full-resolution still around, and the uncorrected
/// still is the largest thing this feature touches.
final class PdfScanCornerEditorViewController: UIViewController {
  /// Called with the corrected corners, in Vision's normalised space.
  var onCommit: ((PdfScanQuad) -> Void)?
  var onCancel: (() -> Void)?

  private let image: UIImage
  private var quad: PdfScanQuad

  private let imageView = UIImageView()
  private let shapeLayer = CAShapeLayer()
  private var handles: [UIView] = []

  private let doneButton = UIButton(type: .system)
  private let cancelButton = UIButton(type: .system)
  private let resetButton = UIButton(type: .system)
  private let hintLabel = UILabel()

  private let detectedQuad: PdfScanQuad

  /// Magnifier shown while a corner is being dragged.
  ///
  /// The finger covers the exact spot it is placing, which is the spot that
  /// matters — a corner two millimetres inside the page edge is invisible until
  /// the page is dewarped and the edge is gone. The loupe puts that spot back
  /// on screen, next to the corner rather than in a fixed spot, so the eye does
  /// not have to travel.
  private let loupe = UIView()
  private let loupeImageLayer = CALayer()
  private let loupeCrosshair = CAShapeLayer()

  private static let loupeSize: CGFloat = 116
  private static let loupeZoom: CGFloat = 3.2

  /// Vertical distance from the corner to the loupe's centre. Roughly a
  /// fingertip plus the loupe's own radius, so it clears the hand.
  private static let loupeOffset: CGFloat = 104

  /// How close a touch must land to count as grabbing a corner. Generous: the
  /// handle is under the user's own fingertip, so precision comes from dragging,
  /// not from the initial touch.
  private static let grabRadius: CGFloat = 48

  private var draggingIndex: Int?

  init(image: UIImage, quad: PdfScanQuad) {
    self.image = image
    self.quad = quad
    self.detectedQuad = quad
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .fullScreen
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var prefersStatusBarHidden: Bool { true }
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black

    imageView.image = image
    imageView.contentMode = .scaleAspectFit
    imageView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(imageView)

    shapeLayer.fillColor = UIColor.systemYellow.withAlphaComponent(0.14).cgColor
    shapeLayer.strokeColor = UIColor.systemYellow.cgColor
    shapeLayer.lineWidth = 2
    shapeLayer.lineJoin = .round
    view.layer.addSublayer(shapeLayer)

    for _ in 0..<4 {
      let handle = UIView()
      handle.backgroundColor = .white
      handle.layer.borderColor = UIColor.systemYellow.cgColor
      handle.layer.borderWidth = 3
      handle.layer.cornerRadius = 13
      handle.frame = CGRect(x: 0, y: 0, width: 26, height: 26)
      handle.isUserInteractionEnabled = false
      view.addSubview(handle)
      handles.append(handle)
    }

    hintLabel.text = "Kéo 4 góc cho khớp mép trang"
    hintLabel.textColor = .white
    hintLabel.font = .systemFont(ofSize: 14, weight: .medium)
    hintLabel.textAlignment = .center
    hintLabel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(hintLabel)

    cancelButton.setTitle("Huỷ", for: .normal)
    cancelButton.tintColor = .white
    cancelButton.addTarget(self, action: #selector(handleCancel), for: .touchUpInside)
    cancelButton.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(cancelButton)

    resetButton.setTitle("Khôi phục", for: .normal)
    resetButton.tintColor = .white
    resetButton.addTarget(self, action: #selector(handleReset), for: .touchUpInside)
    resetButton.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(resetButton)

    doneButton.setTitle("Xong", for: .normal)
    doneButton.tintColor = .white
    doneButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
    doneButton.addTarget(self, action: #selector(handleDone), for: .touchUpInside)
    doneButton.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(doneButton)

    configureLoupe()

    let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    view.addGestureRecognizer(pan)

    let guide = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      cancelButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
      cancelButton.topAnchor.constraint(equalTo: guide.topAnchor, constant: 12),
      doneButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20),
      doneButton.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),
      resetButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      resetButton.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),

      imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      imageView.topAnchor.constraint(equalTo: cancelButton.bottomAnchor, constant: 20),
      imageView.bottomAnchor.constraint(equalTo: hintLabel.topAnchor, constant: -20),

      hintLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
      hintLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20),
      hintLabel.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -24),
    ])
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    shapeLayer.frame = view.bounds
    redraw()
  }

  private func configureLoupe() {
    loupe.frame = CGRect(x: 0, y: 0, width: Self.loupeSize, height: Self.loupeSize)
    loupe.layer.cornerRadius = Self.loupeSize / 2
    loupe.layer.borderWidth = 3
    loupe.layer.borderColor = UIColor.white.cgColor
    loupe.backgroundColor = .black
    loupe.clipsToBounds = true
    loupe.isHidden = true
    loupe.isUserInteractionEnabled = false
    view.addSubview(loupe)

    // Zooming by moving `contentsRect` over the same layer, rather than
    // cropping a new image each frame: the pixels are already on the GPU, and a
    // drag updates this thirty times a second.
    loupeImageLayer.frame = loupe.bounds
    loupeImageLayer.contents = image.cgImage
    loupeImageLayer.contentsGravity = .resize
    // A 12MP capture shown on a phone is being *minified* even inside the
    // loupe, so the filter that matters is the downscaling one. Nearest here
    // would alias the page edge into a staircase — the one thing the user is
    // trying to line the corner up against.
    loupeImageLayer.minificationFilter = .trilinear
    loupeImageLayer.magnificationFilter = .linear
    loupe.layer.addSublayer(loupeImageLayer)

    let centre = Self.loupeSize / 2
    let reticle = UIBezierPath()
    reticle.move(to: CGPoint(x: centre - 18, y: centre))
    reticle.addLine(to: CGPoint(x: centre + 18, y: centre))
    reticle.move(to: CGPoint(x: centre, y: centre - 18))
    reticle.addLine(to: CGPoint(x: centre, y: centre + 18))
    reticle.append(UIBezierPath(
      arcCenter: CGPoint(x: centre, y: centre),
      radius: 7,
      startAngle: 0,
      endAngle: .pi * 2,
      clockwise: true
    ))
    loupeCrosshair.path = reticle.cgPath
    loupeCrosshair.strokeColor = UIColor.systemYellow.cgColor
    loupeCrosshair.fillColor = UIColor.clear.cgColor
    loupeCrosshair.lineWidth = 1.5
    loupeCrosshair.frame = loupe.bounds
    loupe.layer.addSublayer(loupeCrosshair)
  }

  /// Points the loupe at one corner and parks it where the hand is not.
  private func updateLoupe(forCornerAt index: Int) {
    let corner = quad.corners[index]
    let anchor = viewPoint(corner)
    let rect = drawnRect
    guard rect.width > 0, rect.height > 0 else { return }

    // How much of the image the loupe covers, in the image's own unit space.
    // `contentsRect` has its origin top-left, Vision's y points up, hence the
    // flip on the centre.
    let visible = Self.loupeSize / Self.loupeZoom
    let width = visible / rect.width
    let height = visible / rect.height
    let centre = CGPoint(x: corner.x, y: 1 - corner.y)

    // Implicit animation would make the loupe lag a frame behind the finger,
    // which reads as the image sloshing inside it.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    loupeImageLayer.contentsRect = CGRect(
      x: centre.x - width / 2,
      y: centre.y - height / 2,
      width: width,
      height: height
    )

    // Above the corner by default; below it when there is no room, so the loupe
    // never leaves the screen and never hides behind the top controls.
    let radius = Self.loupeSize / 2
    let minY = view.safeAreaInsets.top + radius + 8
    let maxY = view.bounds.height - view.safeAreaInsets.bottom - radius - 8
    var y = anchor.y - Self.loupeOffset
    if y < minY { y = min(anchor.y + Self.loupeOffset, maxY) }
    let x = min(max(anchor.x, radius + 8), view.bounds.width - radius - 8)
    loupe.center = CGPoint(x: x, y: min(max(y, minY), maxY))
    CATransaction.commit()
  }

  // MARK: - Geometry

  /// Where the image is actually drawn inside `imageView`. `scaleAspectFit`
  /// letterboxes, and every conversion here has to be against the drawn image
  /// rather than the view, or the corners land off the page.
  private var drawnRect: CGRect {
    let bounds = imageView.bounds
    let size = image.size
    guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else {
      return bounds
    }
    let fit = min(bounds.width / size.width, bounds.height / size.height)
    let drawn = CGSize(width: size.width * fit, height: size.height * fit)
    return CGRect(
      x: imageView.frame.origin.x + (bounds.width - drawn.width) / 2,
      y: imageView.frame.origin.y + (bounds.height - drawn.height) / 2,
      width: drawn.width,
      height: drawn.height
    )
  }

  /// Vision space (origin bottom-left) to view space (origin top-left).
  private func viewPoint(_ normalized: CGPoint) -> CGPoint {
    let rect = drawnRect
    return CGPoint(
      x: rect.origin.x + normalized.x * rect.width,
      y: rect.origin.y + (1 - normalized.y) * rect.height
    )
  }

  private func normalizedPoint(_ point: CGPoint) -> CGPoint {
    let rect = drawnRect
    guard rect.width > 0, rect.height > 0 else { return .zero }
    return CGPoint(
      x: min(max((point.x - rect.origin.x) / rect.width, 0), 1),
      y: min(max(1 - (point.y - rect.origin.y) / rect.height, 0), 1)
    )
  }

  private func redraw() {
    let points = quad.corners.map(viewPoint)

    let path = UIBezierPath()
    for (index, point) in points.enumerated() {
      index == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    path.close()
    shapeLayer.path = path.cgPath

    for (handle, point) in zip(handles, points) {
      handle.center = point
    }

    // A crossed or collapsed outline cannot drive a perspective correction, so
    // the way out is closed until the user untangles it.
    let usable = quad.isConvex
    doneButton.isEnabled = usable
    doneButton.alpha = usable ? 1 : 0.4
    hintLabel.text = usable
      ? "Kéo 4 góc cho khớp mép trang"
      : "Các góc đang chéo nhau — kéo lại cho thành hình tứ giác"
  }

  // MARK: - Actions

  @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
    let location = gesture.location(in: view)

    switch gesture.state {
    case .began:
      let points = quad.corners.map(viewPoint)
      let nearest = points.enumerated().min { lhs, rhs in
        hypot(lhs.element.x - location.x, lhs.element.y - location.y)
          < hypot(rhs.element.x - location.x, rhs.element.y - location.y)
      }
      guard let nearest,
            hypot(nearest.element.x - location.x, nearest.element.y - location.y)
              <= Self.grabRadius else {
        draggingIndex = nil
        return
      }
      draggingIndex = nearest.offset
      handles[nearest.offset].transform = CGAffineTransform(scaleX: 1.3, y: 1.3)
      loupe.isHidden = false
      updateLoupe(forCornerAt: nearest.offset)

    case .changed:
      guard let index = draggingIndex else { return }
      quad.setCorner(at: index, to: normalizedPoint(location))
      redraw()
      updateLoupe(forCornerAt: index)

    case .ended, .cancelled, .failed:
      if let index = draggingIndex {
        handles[index].transform = .identity
      }
      draggingIndex = nil
      loupe.isHidden = true

    default:
      break
    }
  }

  @objc private func handleReset() {
    quad = detectedQuad
    redraw()
  }

  @objc private func handleDone() {
    guard quad.isConvex else { return }
    onCommit?(quad)
  }

  @objc private func handleCancel() {
    onCancel?()
  }
}
