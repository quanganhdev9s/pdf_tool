import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import Vision

protocol PdfScanCameraViewControllerDelegate: AnyObject {
  /// One page, already cropped and dewarped, at full capture resolution.
  ///
  /// Delivered per page rather than as an array at the end so the caller can
  /// write it to disk immediately. A thirty-page scan held in memory as
  /// `UIImage`s does not survive.
  func cameraController(_ controller: PdfScanCameraViewController, didCapture page: UIImage)

  func cameraControllerDidFinish(_ controller: PdfScanCameraViewController)
  func cameraControllerDidCancel(_ controller: PdfScanCameraViewController)
  func cameraController(
    _ controller: PdfScanCameraViewController,
    didFailWith error: PdfPocError
  )
}

/// The capture screen, in place of `VNDocumentCameraViewController`.
///
/// Written rather than adopted because VisionKit hands back an image that has
/// already been through its own enhancement — crop, dewarp *and* a colour
/// filter the user picks and the app cannot read or set. Running this app's
/// pipeline on top of that is correcting a correction, with no way to know what
/// the first one did. Here the page arrives cropped and dewarped and otherwise
/// untouched, which is what the pipeline is tuned to receive.
///
/// What VisionKit gave for free and is rebuilt here: live edge detection, the
/// overlay that shows it, auto-capture when the frame holds still, and the
/// perspective correction.
final class PdfScanCameraViewController: UIViewController {
  weak var delegate: PdfScanCameraViewControllerDelegate?

  private let session = AVCaptureSession()
  private let photoOutput = AVCapturePhotoOutput()
  private let videoOutput = AVCaptureVideoDataOutput()
  private let sessionQueue = DispatchQueue(label: "pdf.scan.camera.session")
  private let detectionQueue = DispatchQueue(label: "pdf.scan.camera.detection")

  private let detector = PdfScanDocumentDetector()
  private var stability = PdfScanCaptureStability()

  private var device: AVCaptureDevice?

  /// Set once inputs and outputs are attached. `startRunning` is illegal both
  /// before the session has any configuration and while one is open, so it is
  /// gated on this and never issued from the block that does the configuring.
  private var isSessionConfigured = false
  private var previewLayer: AVCaptureVideoPreviewLayer?
  private let overlayLayer = CAShapeLayer()

  /// Detection runs on every third frame. At 30 fps that is ~10 detections a
  /// second, which is enough to feel live and leaves the frame budget alone.
  private static let detectionFrameInterval = 3

  /// Portrait, because the connection is. Enough resolution for segmentation to
  /// place corners within a pixel or two of where a full-size frame would.
  private static let detectionBufferSize = (width: 720, height: 1280)
  private var frameCounter = 0
  private var isDetecting = false

  /// Size of the buffers coming out of `videoOutput`, in the orientation they
  /// arrive in. Needed to map a detection onto the preview, and only known once
  /// the first buffer lands.
  private var bufferSize: CGSize = .zero

  /// Smoothed across detections — see `PdfScanCaptureStability.smoothingFactor`.
  private var lastQuad: PdfScanQuad?
  private var isCapturing = false
  private var pageCount = 0

  private let shutterButton = UIButton(type: .custom)
  private let cancelButton = UIButton(type: .system)
  private let doneButton = UIButton(type: .system)
  private let torchButton = UIButton(type: .system)
  private let hintLabel = UILabel()
  private let autoCaptureSwitch = UISwitch()
  private let autoCaptureLabel = UILabel()
  private let thumbnailView = UIImageView()

  private var isAutoCaptureEnabled = true

  // MARK: - Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    configureInterface()
    requestAccessAndConfigure()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    startSession()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    sessionQueue.async { [weak self] in
      guard let self, self.session.isRunning else { return }
      self.session.stopRunning()
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    previewLayer?.frame = view.bounds
    overlayLayer.frame = view.bounds
    updateConnectionOrientation()
  }

  override var prefersStatusBarHidden: Bool { true }

  override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
    // Locked to portrait: the alternative is re-deriving the buffer-to-preview
    // mapping on every rotation, for a screen the user points at a sheet of
    // paper for a few seconds.
    .portrait
  }

  // MARK: - Session

  private func requestAccessAndConfigure() {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      configureSession()
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        DispatchQueue.main.async {
          guard let self else { return }
          granted ? self.configureSession() : self.failAccessDenied()
        }
      }
    default:
      failAccessDenied()
    }
  }

  private func failAccessDenied() {
    delegate?.cameraController(
      self,
      didFailWith: PdfPocError(
        code: "scan_camera_denied",
        message: "Camera access is off for this app. Turn it on in Settings to scan.",
        details: nil
      )
    )
  }

  private func configureSession() {
    guard let device = AVCaptureDevice.default(
      .builtInWideAngleCamera,
      for: .video,
      position: .back
    ) else {
      delegate?.cameraController(
        self,
        didFailWith: PdfPocError(
          code: "scan_camera_unavailable",
          message: "No camera is available on this device.",
          details: nil
        )
      )
      return
    }
    self.device = device

    let preview = AVCaptureVideoPreviewLayer(session: session)
    preview.videoGravity = .resizeAspectFill
    preview.frame = view.bounds
    view.layer.insertSublayer(preview, at: 0)
    previewLayer = preview

    sessionQueue.async { [weak self] in
      guard let self else { return }
      self.session.beginConfiguration()
      self.session.sessionPreset = .photo

      do {
        let input = try AVCaptureDeviceInput(device: device)
        guard self.session.canAddInput(input) else { throw PdfPocError.cameraSetupFailed }
        self.session.addInput(input)
      } catch {
        self.session.commitConfiguration()
        DispatchQueue.main.async {
          self.delegate?.cameraController(self, didFailWith: PdfPocError.cameraSetupFailed)
        }
        return
      }

      if self.session.canAddOutput(self.photoOutput) {
        self.photoOutput.maxPhotoQualityPrioritization = .quality
        self.session.addOutput(self.photoOutput)
      }

      // Detection buffers are requested small. The session preset is `.photo`,
      // so without this the video output hands over full sensor-sized frames —
      // several megapixels, thirty times a second, to answer a question about
      // where four corners are. Vision would downscale them itself anyway.
      self.videoOutput.alwaysDiscardsLateVideoFrames = true
      self.videoOutput.videoSettings = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Self.detectionBufferSize.width,
        kCVPixelBufferHeightKey as String: Self.detectionBufferSize.height,
      ]
      self.videoOutput.setSampleBufferDelegate(self, queue: self.detectionQueue)
      if self.session.canAddOutput(self.videoOutput) {
        self.session.addOutput(self.videoOutput)
      }

      self.session.commitConfiguration()
      self.isSessionConfigured = true
      self.configureFocus(device)

      DispatchQueue.main.async { self.updateConnectionOrientation() }
      self.startSession()
    }
  }

  /// Always its own block on `sessionQueue`, never a tail call inside the
  /// configuring one: that is what guarantees the `commitConfiguration` above
  /// has fully settled before the session is asked to run.
  private func startSession() {
    sessionQueue.async { [weak self] in
      guard let self, self.isSessionConfigured, !self.session.isRunning else { return }
      self.session.startRunning()
      logPdfEvent("scan_camera_started")
    }
  }

  /// Continuous autofocus with the page assumed to be centred, and macro-range
  /// focus allowed — a sheet held at reading distance is closer than the
  /// default range expects.
  private func configureFocus(_ device: AVCaptureDevice) {
    do {
      try device.lockForConfiguration()
      if device.isFocusModeSupported(.continuousAutoFocus) {
        device.focusMode = .continuousAutoFocus
      }
      if device.isAutoFocusRangeRestrictionSupported {
        device.autoFocusRangeRestriction = .near
      }
      if device.isExposureModeSupported(.continuousAutoExposure) {
        device.exposureMode = .continuousAutoExposure
      }
      device.unlockForConfiguration()
    } catch {
      // Focus tuning is an improvement, not a requirement; the defaults still
      // produce a usable capture.
    }
  }

  private func updateConnectionOrientation() {
    for connection in [previewLayer?.connection, videoOutput.connection(with: .video)] {
      guard let connection, connection.isVideoOrientationSupported else { continue }
      connection.videoOrientation = .portrait
    }
  }

  // MARK: - Interface

  private func configureInterface() {
    overlayLayer.fillColor = UIColor.systemYellow.withAlphaComponent(0.18).cgColor
    overlayLayer.strokeColor = UIColor.systemYellow.cgColor
    overlayLayer.lineWidth = 3
    overlayLayer.lineJoin = .round
    view.layer.addSublayer(overlayLayer)

    hintLabel.text = "Point at a page"
    hintLabel.textColor = .white
    hintLabel.textAlignment = .center
    hintLabel.font = .systemFont(ofSize: 15, weight: .medium)
    hintLabel.layer.shadowOpacity = 0.6
    hintLabel.layer.shadowRadius = 3
    hintLabel.layer.shadowOffset = .zero
    hintLabel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(hintLabel)

    cancelButton.setTitle("Cancel", for: .normal)
    cancelButton.tintColor = .white
    cancelButton.addTarget(self, action: #selector(handleCancel), for: .touchUpInside)
    cancelButton.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(cancelButton)

    doneButton.setTitle("Done", for: .normal)
    doneButton.tintColor = .white
    doneButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
    doneButton.isEnabled = false
    doneButton.addTarget(self, action: #selector(handleDone), for: .touchUpInside)
    doneButton.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(doneButton)

    torchButton.setImage(UIImage(systemName: "bolt.slash.fill"), for: .normal)
    torchButton.tintColor = .white
    torchButton.addTarget(self, action: #selector(handleTorch), for: .touchUpInside)
    torchButton.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(torchButton)

    shutterButton.backgroundColor = .white
    shutterButton.layer.cornerRadius = 34
    shutterButton.layer.borderWidth = 4
    shutterButton.layer.borderColor = UIColor.white.withAlphaComponent(0.5).cgColor
    shutterButton.addTarget(self, action: #selector(handleShutter), for: .touchUpInside)
    shutterButton.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(shutterButton)

    autoCaptureLabel.text = "Auto"
    autoCaptureLabel.textColor = .white
    autoCaptureLabel.font = .systemFont(ofSize: 13, weight: .medium)
    autoCaptureLabel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(autoCaptureLabel)

    autoCaptureSwitch.isOn = true
    autoCaptureSwitch.addTarget(self, action: #selector(handleAutoToggle), for: .valueChanged)
    autoCaptureSwitch.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(autoCaptureSwitch)

    thumbnailView.contentMode = .scaleAspectFill
    thumbnailView.clipsToBounds = true
    thumbnailView.layer.cornerRadius = 6
    thumbnailView.layer.borderWidth = 2
    thumbnailView.layer.borderColor = UIColor.white.cgColor
    thumbnailView.isHidden = true
    thumbnailView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(thumbnailView)

    let guide = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      cancelButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
      cancelButton.topAnchor.constraint(equalTo: guide.topAnchor, constant: 12),

      doneButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20),
      doneButton.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),

      torchButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      torchButton.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),

      hintLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24),
      hintLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),
      hintLabel.bottomAnchor.constraint(equalTo: shutterButton.topAnchor, constant: -20),

      shutterButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      shutterButton.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -28),
      shutterButton.widthAnchor.constraint(equalToConstant: 68),
      shutterButton.heightAnchor.constraint(equalToConstant: 68),

      autoCaptureSwitch.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20),
      autoCaptureSwitch.centerYAnchor.constraint(equalTo: shutterButton.centerYAnchor),
      autoCaptureLabel.centerXAnchor.constraint(equalTo: autoCaptureSwitch.centerXAnchor),
      autoCaptureLabel.bottomAnchor.constraint(equalTo: autoCaptureSwitch.topAnchor, constant: -6),

      thumbnailView.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
      thumbnailView.centerYAnchor.constraint(equalTo: shutterButton.centerYAnchor),
      thumbnailView.widthAnchor.constraint(equalToConstant: 48),
      thumbnailView.heightAnchor.constraint(equalToConstant: 64),
    ])
  }

  @objc private func handleCancel() {
    setTorch(on: false)
    delegate?.cameraControllerDidCancel(self)
  }

  @objc private func handleDone() {
    setTorch(on: false)
    delegate?.cameraControllerDidFinish(self)
  }

  @objc private func handleShutter() {
    capturePhoto()
  }

  @objc private func handleAutoToggle() {
    isAutoCaptureEnabled = autoCaptureSwitch.isOn
    stability.reset()
  }

  @objc private func handleTorch() {
    guard let device, device.hasTorch else { return }
    setTorch(on: device.torchMode != .on)
  }

  private func setTorch(on: Bool) {
    guard let device, device.hasTorch else { return }
    try? device.lockForConfiguration()
    device.torchMode = on ? .on : .off
    device.unlockForConfiguration()
    torchButton.setImage(
      UIImage(systemName: on ? "bolt.fill" : "bolt.slash.fill"),
      for: .normal
    )
  }

  // MARK: - Overlay

  /// Maps a detection onto the preview.
  ///
  /// The preview is `resizeAspectFill`, so the buffer is scaled up until it
  /// covers the layer and the overflow is cropped evenly on both axes — the
  /// same transform is applied here in reverse. Vision's y axis points up and
  /// UIKit's points down, hence the flip.
  private func updateOverlay(with quad: PdfScanQuad?) {
    guard let quad, bufferSize.width > 0, bufferSize.height > 0 else {
      overlayLayer.path = nil
      return
    }

    let bounds = view.bounds
    let scale = max(bounds.width / bufferSize.width, bounds.height / bufferSize.height)
    let scaled = CGSize(width: bufferSize.width * scale, height: bufferSize.height * scale)
    let offset = CGPoint(
      x: (scaled.width - bounds.width) / 2,
      y: (scaled.height - bounds.height) / 2
    )

    let path = UIBezierPath()
    for (index, corner) in quad.corners.enumerated() {
      let point = CGPoint(
        x: corner.x * scaled.width - offset.x,
        y: (1 - corner.y) * scaled.height - offset.y
      )
      index == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    path.close()
    overlayLayer.path = path.cgPath
  }

  // MARK: - Capture

  /// True while the lens or the exposure is still moving. Shooting through it
  /// is how a scanner produces a page that is legible on screen and unreadable
  /// in the PDF.
  private var isLensSettling: Bool {
    guard let device else { return false }
    return device.isAdjustingFocus || device.isAdjustingExposure
  }

  private func capturePhoto() {
    guard !isCapturing, session.isRunning else { return }
    isCapturing = true

    let settings = AVCapturePhotoSettings()
    settings.photoQualityPrioritization = .quality
    settings.flashMode = .off
    photoOutput.capturePhoto(with: settings, delegate: self)

    UIView.animate(withDuration: 0.08, animations: { self.view.alpha = 0.6 }) { _ in
      UIView.animate(withDuration: 0.12) { self.view.alpha = 1 }
    }
  }

  /// Crops and dewarps the captured still.
  ///
  /// Detection is run again on the still rather than reusing the quad from the
  /// live frame. The two differ — different resolution, different field of view,
  /// and a few tens of milliseconds apart — and mapping one onto the other is
  /// exactly the class of coordinate bug that is invisible until the output is
  /// subtly trapezoidal. Detecting twice costs one extra Vision pass per page.
  private func correctedImage(from image: CIImage) -> CIImage {
    // Both candidates are already validated — the detector rejects implausible
    // quads — so an unusable still detection falls through to the live one, and
    // a page with neither is left uncropped rather than sheared into a wedge.
    guard let quad = detector.detect(in: image) ?? lastQuad else { return image }

    let extent = image.extent
    func point(_ normalized: CGPoint) -> CGPoint {
      CGPoint(
        x: extent.origin.x + normalized.x * extent.width,
        y: extent.origin.y + normalized.y * extent.height
      )
    }

    let correction = CIFilter.perspectiveCorrection()
    correction.inputImage = image
    correction.topLeft = point(quad.topLeft)
    correction.topRight = point(quad.topRight)
    correction.bottomLeft = point(quad.bottomLeft)
    correction.bottomRight = point(quad.bottomRight)
    correction.crop = true
    return correction.outputImage ?? image
  }
}

// MARK: - Live frames

extension PdfScanCameraViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    frameCounter += 1
    guard frameCounter % Self.detectionFrameInterval == 0,
          !isDetecting,
          !isCapturing,
          let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
      return
    }

    isDetecting = true
    let size = CGSize(
      width: CVPixelBufferGetWidth(pixelBuffer),
      height: CVPixelBufferGetHeight(pixelBuffer)
    )
    let quad = detector.detect(in: pixelBuffer)
    isDetecting = false

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.bufferSize = size

      // Blend toward the new detection rather than replacing: Vision's corners
      // jitter on a page that is not moving, and that jitter would otherwise
      // read as movement and keep resetting the steadiness count.
      let smoothed: PdfScanQuad?
      if let quad {
        smoothed = self.lastQuad.map {
          $0.blended(towards: quad, factor: PdfScanCaptureStability.smoothingFactor)
        } ?? quad
      } else {
        smoothed = nil
      }
      self.lastQuad = smoothed
      self.updateOverlay(with: smoothed)

      let steady = self.stability.update(with: smoothed)
      let isSettling = self.isLensSettling

      self.hintLabel.text = {
        guard smoothed != nil else { return "Point at a page" }
        if isSettling { return "Focusing…" }
        return self.isAutoCaptureEnabled ? "Hold steady" : "Tap the shutter"
      }()

      // The focus check gates auto-capture only. Manual shutter stays live: a
      // camera that never focuses would otherwise leave the user with no way to
      // take the picture at all.
      if steady, self.isAutoCaptureEnabled, !self.isCapturing, !isSettling {
        self.capturePhoto()
      }
    }
  }
}

// MARK: - Stills

extension PdfScanCameraViewController: AVCapturePhotoCaptureDelegate {
  func photoOutput(
    _ output: AVCapturePhotoOutput,
    didFinishProcessingPhoto photo: AVCapturePhoto,
    error: Error?
  ) {
    defer { isCapturing = false }

    if let error {
      delegate?.cameraController(
        self,
        didFailWith: PdfPocError(
          code: "scan_capture_failed",
          message: "Could not capture the page.",
          details: error.localizedDescription
        )
      )
      return
    }

    guard let data = photo.fileDataRepresentation(),
          let captured = UIImage(data: data)?.normalizedUp(),
          let cgImage = captured.cgImage else {
      delegate?.cameraController(
        self,
        didFailWith: PdfPocError(
          code: "scan_capture_failed",
          message: "Could not read the captured page.",
          details: nil
        )
      )
      return
    }

    let corrected = correctedImage(from: CIImage(cgImage: cgImage))
    guard let output = PdfScanRenderContext.shared.createCGImage(corrected, from: corrected.extent) else {
      delegate?.cameraController(
        self,
        didFailWith: PdfPocError(
          code: "scan_capture_failed",
          message: "Could not straighten the captured page.",
          details: nil
        )
      )
      return
    }

    let page = UIImage(cgImage: output)
    pageCount += 1
    doneButton.isEnabled = true
    doneButton.setTitle("Done (\(pageCount))", for: .normal)
    thumbnailView.image = page
    thumbnailView.isHidden = false
    stability.reset()

    logPdfEvent("scan_camera_page_captured", "page=\(pageCount)")
    delegate?.cameraController(self, didCapture: page)
  }
}

private extension PdfPocError {
  static var cameraSetupFailed: PdfPocError {
    PdfPocError(
      code: "scan_camera_unavailable",
      message: "Could not start the camera.",
      details: nil
    )
  }
}

private extension UIImage {
  /// Bakes the EXIF orientation into the pixels.
  ///
  /// Everything downstream — Vision, `CIPerspectiveCorrection`, the pipeline —
  /// reads the `CGImage`, which does not carry the orientation flag. Without
  /// this, a page shot in portrait is detected and dewarped sideways.
  func normalizedUp() -> UIImage? {
    guard imageOrientation != .up else { return self }
    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    format.opaque = true
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
      draw(in: CGRect(origin: .zero, size: size))
    }
  }
}
