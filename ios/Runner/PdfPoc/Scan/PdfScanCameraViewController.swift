import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UIKit
import Vision

protocol PdfScanCameraViewControllerDelegate: AnyObject {
  /// One page, already cropped and dewarped, at full capture resolution.
  ///
  /// Delivered per page rather than as an array at the end so the caller can
  /// write it to disk immediately. A thirty-page scan held in memory as
  /// `UIImage`s does not survive.
  func cameraController(_ controller: PdfScanCameraViewController, didCapture page: UIImage)

  /// The last delivered page, re-cropped after the user moved its corners.
  /// Replaces what `didCapture` handed over — same page, new pixels.
  func cameraController(
    _ controller: PdfScanCameraViewController,
    didAdjustLastPage page: UIImage
  )

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

  /// Nắn phối cảnh và mã hoá JPEG của ảnh vừa chụp. Tách khỏi main: cả hai việc
  /// đều ở độ phân giải đầy đủ và đủ nặng để thấy giật khi bấm chụp.
  private let stillQueue = DispatchQueue(label: "pdf.scan.camera.still", qos: .userInitiated)

  /// Hàng đợi riêng cho việc hâm nóng, **không** dùng chung với `stillQueue`.
  /// Lượt hâm mất hơn 10 giây (biên dịch shader Metal), mà `stillQueue` tuần
  /// tự — bấm chụp trong khoảng đó là ảnh phải xếp hàng sau nó.
  private let warmUpQueue = DispatchQueue(label: "pdf.scan.camera.warmup", qos: .utility)

  private let detector = PdfScanDocumentDetector()

  /// Thời gian dò của các khung gần đây; xem `recordDetection`.
  private var detectionSamples: [Int] = []
  private var stability = PdfScanCaptureStability()

  private var device: AVCaptureDevice?

  /// Set once inputs and outputs are attached. `startRunning` is illegal both
  /// before the session has any configuration and while one is open, so it is
  /// gated on this and never issued from the block that does the configuring.
  private var isSessionConfigured = false
  private var previewLayer: AVCaptureVideoPreviewLayer?
  private let overlayLayer = CAShapeLayer()

  /// Detection runs on every second frame. At 30 fps that is ~15 detections a
  /// second, which is enough to feel live and leaves the frame budget alone.
  private static let detectionFrameInterval = 2

  /// Khớp với nhịp dò ở trên: khung vàng nội suy từ lần dò này sang lần kế tiếp
  /// thay vì nhảy cóc. `CAShapeLayer` không nằm dưới một view nên nếu để mặc
  /// định nó tự chạy hoạt ảnh 0.25s cho mỗi `path` mới — dài gấp ba khoảng cách
  /// giữa hai lần dò, nên khung luôn bị bỏ dở giữa chừng và trông nhoè.
  private static let overlayFollowDuration = 0.08

  /// Portrait, because the connection is. Enough resolution for segmentation to
  /// place corners within a pixel or two of where a full-size frame would.
  private static let detectionBufferSize = (width: 720, height: 1280)
  private var frameCounter = 0

  /// Size of the buffers coming out of `videoOutput`, in the orientation they
  /// arrive in. Needed to map a detection onto the preview, and only known once
  /// the first buffer lands.
  private var bufferSize: CGSize = .zero

  /// Smoothed across detections — see `PdfScanCaptureStability.smoothingFactor`.
  private var lastQuad: PdfScanQuad?
  private var isCapturing = false

  /// Mốc lúc bấm máy, để đo quãng AVFoundation giữ ảnh — quãng dài nhất trong
  /// cả lần chụp mà trước đây không có gì đo.
  private var shutterAt: CFTimeInterval = 0
  private var pageCount = 0

  /// Mốc bắt đầu lượt dò nét chủ động; 0 là chưa có lượt nào đang chạy.
  ///
  /// Ở chế độ nét liên tục, `isAdjustingFocus` false chỉ nghĩa là ống kính đang
  /// đứng yên, chứ không phải nó đang nét vào tờ giấy — máy tự thấy cảnh không
  /// đổi nên không dò lại. Nên trước mỗi lần chụp tự động phải bắt nó dò thật
  /// một lượt rồi mới bấm.
  private var focusRunStartedAt: CFTimeInterval = 0
  private var didObserveFocusRun = false
  private static let focusRunTimeout: CFTimeInterval = 1.2

  /// The last still *before* perspective correction, plus the corners used on
  /// it. Kept so the corner editor has something to re-crop from.
  ///
  /// On disk rather than in memory: an uncorrected full-resolution capture is
  /// the largest single object this screen touches, and holding one alive for
  /// the whole session to serve an edit that usually never happens is the wrong
  /// trade. One file, overwritten by each capture.
  private var lastOriginalURL: URL?
  private var lastAppliedQuad: PdfScanQuad?

  private let shutterButton = UIButton(type: .custom)
  private let cancelButton = UIButton(type: .system)
  private let doneButton = UIButton(type: .system)
  private let torchButton = UIButton(type: .system)
  private let hintLabel = UILabel()
  private let autoCaptureSwitch = UISwitch()
  private let autoCaptureLabel = UILabel()
  private let thumbnailView = UIImageView()
  private let cropBadge = UIImageView()

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
        self.photoOutput.maxPhotoQualityPrioritization = .speed
        self.session.addOutput(self.photoOutput)
        self.limitPhotoDimensions(for: device)
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
      self.warmUpRenderPipeline()
    }
  }

  /// Trả trước chi phí một lần của đường xử lý ảnh tĩnh.
  ///
  /// Phải chạy **đúng** `quickPreview` trên một JPEG thật chứ không phải một
  /// `CIImage(color:)`: ảnh sinh ra từ generator không có texture đầu vào, nên
  /// CoreImage biên dịch một biến thể shader khác với biến thể mà ảnh chụp
  /// thật sẽ dùng. Đo được: hâm bằng generator tốn 6.3s mà lần chụp đầu vẫn
  /// phải trả thêm 3.3s; hâm đúng đường thì còn 137ms.
  private func warmUpRenderPipeline() {
    // Giữ mạnh thì Cancel xong, VC và capture session vẫn sống hết lượt hâm.
    warmUpQueue.async { [weak self] in
      var timer = StepTimer()
      guard let seed = Self.warmUpJpeg() else { return }
      let encodeMs = timer.lap()
      guard let self else { return }
      _ = self.quickPreview(from: seed, quad: Self.fullFrameQuad)
      logPdfEvent(
        "scan_render_warmup",
        "seed=\(encodeMs)ms preview=\(timer.lap())ms"
      )
    }
  }

  /// Ảnh giả cỡ xấp xỉ bản xem trước thật, để lượt hâm nóng đi qua đúng cỡ
  /// texture mà lần chụp đầu sẽ dùng.
  private static func warmUpJpeg() -> Data? {
    let size = CGSize(width: 720, height: 960)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
      UIColor.white.setFill()
      context.fill(CGRect(origin: .zero, size: size))
      UIColor.darkGray.setFill()
      context.fill(CGRect(x: 60, y: 80, width: 600, height: 40))
    }
    return image.jpegData(compressionQuality: 0.9)
  }

  /// Continuous autofocus with the page assumed to be centred, and macro-range
  /// focus allowed — a sheet held at reading distance is closer than the
  /// default range expects.
  private func configureFocus(_ device: AVCaptureDevice) {
    // Focus tuning is an improvement, not a requirement; the defaults still
    // produce a usable capture.
    guard (try? device.lockForConfiguration()) != nil else { return }
    defer { device.unlockForConfiguration() }
    if device.isAutoFocusRangeRestrictionSupported {
      device.autoFocusRangeRestriction = .near
    }
    applyContinuousFocus(device)
  }

  private func applyContinuousFocus(_ device: AVCaptureDevice) {
    if device.isFocusModeSupported(.continuousAutoFocus) {
      device.focusMode = .continuousAutoFocus
    }
    if device.isExposureModeSupported(.continuousAutoExposure) {
      device.exposureMode = .continuousAutoExposure
    }
  }

  /// Bắt ống kính dò nét một lượt thật vào giữa khung, ngay trước khi chụp tự
  /// động. Điểm ngắm lấy giữa khung chứ không lấy tâm tứ giác: tờ giấy đã chiếm
  /// phần lớn khung hình rồi, mà đổi hệ toạ độ Vision sang hệ của thiết bị là
  /// thêm một chỗ dễ sai.
  private func beginFocusRun() {
    guard let device else { return }
    guard (try? device.lockForConfiguration()) != nil else { return }
    defer { device.unlockForConfiguration() }

    let centre = CGPoint(x: 0.5, y: 0.5)
    if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
      device.focusPointOfInterest = centre
      device.focusMode = .autoFocus
    }
    if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
      device.exposurePointOfInterest = centre
      device.exposureMode = .autoExpose
    }
  }

  private func clearFocusRun() {
    focusRunStartedAt = 0
    didObserveFocusRun = false
  }

  /// Huỷ lượt dò đang chạy. Phải trả ống kính về dò liên tục, không thì nó kẹt
  /// ở chế độ nét đơn và lượt `beginFocusRun` sau không còn là một lần đổi chế
  /// độ thật nữa.
  private func cancelFocusRun() {
    guard focusRunStartedAt > 0 else { return }
    clearFocusRun()
    resumeContinuousFocus()
  }

  /// Trả về dò liên tục sau khi chụp xong, để khung xem trước còn sống cho
  /// trang kế tiếp thay vì đứng ở mức nét của trang vừa rồi.
  private func resumeContinuousFocus() {
    guard let device else { return }
    guard (try? device.lockForConfiguration()) != nil else { return }
    defer { device.unlockForConfiguration() }
    applyContinuousFocus(device)
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
    overlayLayer.lineWidth = 1.5
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
    thumbnailView.isUserInteractionEnabled = true
    thumbnailView.accessibilityLabel = "Chỉnh khung trang vừa chụp"
    thumbnailView.addGestureRecognizer(
      UITapGestureRecognizer(target: self, action: #selector(handleThumbnailTap))
    )
    thumbnailView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(thumbnailView)

    // Says the thumbnail does something. Without it the tap target is invisible
    // and nobody finds the editor.
    cropBadge.image = UIImage(systemName: "crop")
    cropBadge.tintColor = .white
    cropBadge.contentMode = .center
    cropBadge.backgroundColor = UIColor.black.withAlphaComponent(0.55)
    cropBadge.layer.cornerRadius = 10
    cropBadge.clipsToBounds = true
    cropBadge.isHidden = true
    cropBadge.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(cropBadge)

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

      cropBadge.trailingAnchor.constraint(equalTo: thumbnailView.trailingAnchor, constant: 6),
      cropBadge.bottomAnchor.constraint(equalTo: thumbnailView.bottomAnchor, constant: 6),
      cropBadge.widthAnchor.constraint(equalToConstant: 20),
      cropBadge.heightAnchor.constraint(equalToConstant: 20),
    ])
  }

  @objc private func handleCancel() {
    setTorch(on: false)
    discardStoredOriginal()
    delegate?.cameraControllerDidCancel(self)
  }

  @objc private func handleDone() {
    setTorch(on: false)
    discardStoredOriginal()
    delegate?.cameraControllerDidFinish(self)
  }

  @objc private func handleShutter() {
    capturePhoto(trigger: "manual")
  }

  /// Opens the corner editor on the page just captured.
  @objc private func handleThumbnailTap() {
    guard let url = lastOriginalURL, let quad = lastAppliedQuad else { return }

    setTorch(on: false)
    // Đọc và giải mã đều nặng: chạy trên main là khựng vài trăm ms trước khi
    // editor kịp hiện. Chỉ dựng bản thu nhỏ ở đây — bản đầy đủ để tới lúc
    // người dùng bấm xác nhận mới đọc, mà phần lớn lượt mở là bấm huỷ.
    stillQueue.async { [weak self] in
      guard let display = Self.editorDisplayImage(at: url) else { return }
      DispatchQueue.main.async {
        guard let self else { return }
        self.presentCornerEditor(display: display, originalURL: url, quad: quad)
      }
    }
  }

  /// Bản thu nhỏ để editor hiển thị. Góc là toạ độ chuẩn hoá nên chỉnh góc
  /// không cần pixel gốc.
  ///
  /// `kCGImageSourceCreateThumbnailWithTransform` lo phần hướng ảnh, đúng việc
  /// mà `normalizedUp()` làm cho bản đầy đủ: file lưu là ảnh thô còn nguyên cờ
  /// EXIF, không xoay lại thì trang nằm ngang dưới một tứ giác dựng đứng.
  private static func editorDisplayImage(at url: URL) -> UIImage? {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: 2400,
    ]
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else { return nil }
    return UIImage(cgImage: thumbnail)
  }

  private func presentCornerEditor(display: UIImage, originalURL: URL, quad: PdfScanQuad) {
    let editor = PdfScanCornerEditorViewController(image: display, quad: quad)
    editor.onCancel = { [weak self] in
      self?.dismiss(animated: true)
    }
    editor.onCommit = { [weak self] adjusted in
      guard let self else { return }
      self.dismiss(animated: true)
      self.applyAdjustedQuad(adjusted, originalURL: originalURL)
    }
    present(editor, animated: true)
  }

  /// Re-runs the correction with the corners the user set and hands the result
  /// back as a replacement for the page already delivered.
  private func applyAdjustedQuad(_ quad: PdfScanQuad, originalURL: URL) {
    lastAppliedQuad = quad

    // Nắn phối cảnh full-res, cùng lý do như đường chụp. Bản đầy đủ đọc ở đây
    // chứ không giữ sẵn suốt phiên editor.
    stillQueue.async { [weak self] in
      guard let data = try? Data(contentsOf: originalURL),
            let cgImage = UIImage(data: data)?.normalizedUp()?.cgImage else { return }
      let corrected = self?.perspectiveCorrected(CIImage(cgImage: cgImage), using: quad)
      guard let corrected,
            let output = PdfScanRenderContext.shared.createCGImage(
              corrected,
              from: corrected.extent
            ) else {
        return
      }

      let page = UIImage(cgImage: output)
      DispatchQueue.main.async {
        guard let self else { return }
        self.thumbnailView.image = page
        logPdfEvent("scan_camera_page_adjusted", "page=\(self.pageCount)")
        self.delegate?.cameraController(self, didAdjustLastPage: page)
      }
    }
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
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      overlayLayer.path = nil
      CATransaction.commit()
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

    CATransaction.begin()
    CATransaction.setAnimationDuration(Self.overlayFollowDuration)
    CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
    overlayLayer.path = path.cgPath
    CATransaction.commit()
  }

  // MARK: - Capture

  /// True while the lens or the exposure is still moving. Shooting through it
  /// is how a scanner produces a page that is legible on screen and unreadable
  /// in the PDF.
  private var isLensSettling: Bool {
    guard let device else { return false }
    return device.isAdjustingFocus || device.isAdjustingExposure
  }

  /// Chụp nhỏ hơn cả cảm biến.
  ///
  /// Trang sau khi nắn phối cảnh chưa bao giờ được dùng trên 2400px, mà ảnh cắt
  /// ra chỉ còn ~75% khung hình — nên khoảng 3200px là đủ dư. Cảm biến đầy
  /// (12MP) chỉ làm ISP và bước mã hoá lâu hơn.
  private func limitPhotoDimensions(for device: AVCaptureDevice) {
    guard #available(iOS 16.0, *) else { return }
    let wanted: Int32 = 3200
    let supported = device.activeFormat.supportedMaxPhotoDimensions
    guard let pick = supported
      .filter({ max($0.width, $0.height) >= wanted })
      .min(by: { max($0.width, $0.height) < max($1.width, $1.height) })
    else { return }
    photoOutput.maxPhotoDimensions = pick
    logPdfEvent("scan_photo_dimensions", "\(pick.width)x\(pick.height)")
  }

  private func capturePhoto(trigger: String) {
    guard !isCapturing, session.isRunning else { return }
    isCapturing = true
    shutterAt = CACurrentMediaTime()
    let lens = device.map {
      "lens=\(String(format: "%.3f", $0.lensPosition))"
        + " iso=\(Int($0.iso))"
        + " exposure=\(Int(CMTimeGetSeconds($0.exposureDuration) * 1000))ms"
    } ?? "lens=?"
    logPdfEvent("scan_capture_trigger", "trigger=\(trigger) \(lens)")

    let settings = AVCapturePhotoSettings()
    // `.quality` bật đường hợp nhất nhiều khung của ISP — đáng cho ảnh đời
    // thường, nhưng đây là tờ giấy phẳng và pipeline phía sau còn san sáng rồi
    // ép mức nữa, nên phần tinh tế mua được lại bị chính bước đó xoá đi.
    settings.photoQualityPrioritization = .speed
    if #available(iOS 16.0, *) {
      settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
    }
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
  private func correctedImage(
    from image: CIImage,
    fallbackQuad: PdfScanQuad? = nil
  ) -> (image: CIImage, quad: PdfScanQuad?) {
    // Both candidates are already validated — the detector rejects implausible
    // quads — so an unusable still detection falls through to the live one, and
    // a page with neither is left uncropped rather than sheared into a wedge.
    guard let quad = detector.detect(in: image) ?? fallbackQuad else { return (image, nil) }
    return (perspectiveCorrected(image, using: quad), quad)
  }

  private func perspectiveCorrected(_ image: CIImage, using quad: PdfScanQuad) -> CIImage {
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

  /// The whole frame, for when nothing was detected: the editor still needs a
  /// starting quad to show, and the page edges are the safest guess.
  private static let fullFrameQuad = PdfScanQuad(corners: [
    CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1),
    CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 0),
  ])
}

// MARK: - Live frames

extension PdfScanCameraViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
  /// Gộp lại rồi in mỗi 30 lần dò. In từng khung là log lấn át đúng thứ đang đo.
  /// Chỉ chạm trên `detectionQueue`.
  private func recordDetection(ms: Int) {
    detectionSamples.append(ms)
    guard detectionSamples.count >= 30 else { return }
    let total = detectionSamples.reduce(0, +)
    logPdfEvent(
      "scan_detect_rate",
      "frames=\(detectionSamples.count) avg=\(total / detectionSamples.count)ms"
        + " max=\(detectionSamples.max() ?? 0)ms every=\(Self.detectionFrameInterval)"
    )
    detectionSamples.removeAll(keepingCapacity: true)
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    frameCounter += 1
    guard frameCounter % Self.detectionFrameInterval == 0,
          !isCapturing,
          let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
      return
    }

    let size = CGSize(
      width: CVPixelBufferGetWidth(pixelBuffer),
      height: CVPixelBufferGetHeight(pixelBuffer)
    )
    let timer = StepTimer()
    let quad = detector.detect(in: pixelBuffer)
    recordDetection(ms: timer.total)

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
        if self.focusRunStartedAt > 0 { return "Focusing…" }
        return self.isAutoCaptureEnabled ? "Hold steady" : "Tap the shutter"
      }()

      // The focus check gates auto-capture only. Manual shutter stays live: a
      // camera that never focuses would otherwise leave the user with no way to
      // take the picture at all.
      guard steady, self.isAutoCaptureEnabled, !self.isCapturing else {
        self.cancelFocusRun()
        return
      }

      guard self.focusRunStartedAt > 0 else {
        self.focusRunStartedAt = CACurrentMediaTime()
        self.didObserveFocusRun = false
        self.beginFocusRun()
        return
      }

      if isSettling { self.didObserveFocusRun = true }
      let elapsed = CACurrentMediaTime() - self.focusRunStartedAt
      let converged = self.didObserveFocusRun && !isSettling
      guard converged || elapsed > Self.focusRunTimeout else { return }

      self.clearFocusRun()
      self.stability.markCaptured()
      logPdfEvent(
        "scan_auto_focus_run",
        "outcome=\(converged ? "converged" : "timeout") ms=\(Int(elapsed * 1000))"
      )
      self.capturePhoto(trigger: "auto")
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
    if shutterAt > 0 {
      logPdfEvent(
        "scan_shutter_latency",
        "ms=\(Int(((CACurrentMediaTime() - shutterAt) * 1000).rounded()))"
      )
      shutterAt = 0
    }

    if let error {
      isCapturing = false
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

    guard let data = photo.fileDataRepresentation() else {
      isCapturing = false
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

    // `lastQuad` chỉ được đụng tới trên main. Lấy một bản ở đây rồi truyền đi,
    // để hàng đợi xử lý ảnh không phải đọc nó.
    let quadHint = lastQuad
    stillQueue.async { [weak self] in
      guard let self else { return }
      autoreleasepool {
        self.processCapturedPhoto(data: data, quadHint: quadHint)
      }
    }
  }

  /// Chạy trên `stillQueue`. Trả kết quả về main chỉ để cập nhật giao diện.
  ///
  /// Chia làm hai chặng có chủ đích: một bản xem trước nhỏ dựng gần như tức thì
  /// để hoạt ảnh chạy ngay sau tiếng chụp, rồi mới tới bản đầy đủ. Nếu đợi bản
  /// đầy đủ mới bắt đầu thì người dùng nhìn màn hình đứng im mất một lúc.
  private func processCapturedPhoto(data: Data, quadHint: PdfScanQuad?) {
    var timer = StepTimer()
    // Mở cửa cho khung hình trực tiếp chỉ khi đã xong hẳn. Trước đây cờ này
    // được nhả ngay lúc delegate trả về, nên Vision chạy song song với cả
    // đường xử lý ảnh tĩnh và giành nhau GPU: đo được `max=12775ms` cho một
    // lần dò.
    defer { DispatchQueue.main.async { [weak self] in self?.isCapturing = false } }

    func failOnMain(_ message: String) {
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.delegate?.cameraController(
          self,
          didFailWith: PdfPocError(code: "scan_capture_failed", message: message, details: nil)
        )
      }
    }

    if let preview = quickPreview(from: data, quad: quadHint) {
      DispatchQueue.main.async { [weak self] in
        self?.flyCaptureToThumbnail(preview)
      }
    }
    let previewMs = timer.lap()

    guard let captured = UIImage(data: data)?.normalizedUp(),
          let cgImage = captured.cgImage else {
      failOnMain("Could not read the captured page.")
      return
    }
    let decodeMs = timer.lap()

    let result = correctedImage(from: CIImage(cgImage: cgImage), fallbackQuad: quadHint)
    let corrected = result.image
    let detectMs = timer.lap()
    storeOriginal(data, quad: result.quad ?? Self.fullFrameQuad)
    let storeMs = timer.lap()

    guard let output = PdfScanRenderContext.shared.createCGImage(corrected, from: corrected.extent) else {
      failOnMain("Could not straighten the captured page.")
      return
    }
    let page = UIImage(cgImage: output)
    logPdfEvent(
      "scan_capture_pipeline",
      "bytes=\(data.count) out=\(output.width)x\(output.height)"
        + " preview=\(previewMs)ms decode=\(decodeMs)ms detect=\(detectMs)ms"
        + " store=\(storeMs)ms raster=\(timer.lap())ms total=\(timer.total)ms"
    )

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.pageCount += 1
      self.doneButton.isEnabled = true
      self.doneButton.setTitle("Done (\(self.pageCount))", for: .normal)
      self.thumbnailView.image = page
      self.thumbnailView.isHidden = false
      self.cropBadge.isHidden = false
      self.stability.reset()
      self.clearFocusRun()
      self.resumeContinuousFocus()
      logPdfEvent("scan_camera_page_captured", "page=\(self.pageCount)")
      self.delegate?.cameraController(self, didCapture: page)
    }
  }

  /// Ảnh nhỏ dùng cho hoạt ảnh, giải mã thẳng ở kích thước rút gọn.
  ///
  /// ImageIO giải nén JPEG theo bậc nên bản này rẻ hơn hẳn bản đầy đủ. Khung
  /// dùng để cắt là khung từ luồng xem trước chứ không dò lại — đây chỉ là ảnh
  /// để nhìn, bản chính thức vẫn được dò riêng ở dưới.
  private func quickPreview(from data: Data, quad: PdfScanQuad?) -> UIImage? {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: 720,
    ]
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      return nil
    }
    guard let quad else { return UIImage(cgImage: thumb) }

    let corrected = perspectiveCorrected(CIImage(cgImage: thumb), using: quad)
    guard let output = PdfScanRenderContext.shared.createCGImage(
      corrected,
      from: corrected.extent
    ) else {
      return UIImage(cgImage: thumb)
    }
    return UIImage(cgImage: output)
  }
}

extension PdfScanCameraViewController {
  /// Ảnh vừa chụp hiện ra to giữa màn hình rồi bay thu nhỏ về ô thumbnail.
  ///
  /// Auto-capture bấm máy hộ người dùng, nên nếu không có gì báo thì họ không
  /// biết đã chụp được hay chưa. Ảnh bay về đúng chỗ thumbnail vừa xác nhận đã
  /// chụp, vừa chỉ luôn nơi bấm vào để chỉnh lại khung.
  /// Ảnh đứng yên ở cỡ lớn bao lâu trước khi bay — đây mới là lúc người dùng
  /// xác nhận vừa chụp được gì, phần bay chỉ để chỉ chỗ.
  private static let flyHoldDuration: TimeInterval = 0.45
  private static let flyTravelDuration: TimeInterval = 1.15
  private static let flyBounceDuration: TimeInterval = 0.42

  /// Hình chữ nhật lớn nhất mang đúng tỉ lệ [size], canh giữa trong [bounds].
  private static func aspectFitted(_ size: CGSize, in bounds: CGRect) -> CGRect {
    guard size.width > 0, size.height > 0 else { return bounds }
    let scale = min(bounds.width / size.width, bounds.height / size.height)
    let fitted = CGSize(width: size.width * scale, height: size.height * scale)
    return CGRect(
      x: bounds.midX - fitted.width / 2,
      y: bounds.midY - fitted.height / 2,
      width: fitted.width,
      height: fitted.height
    )
  }

  func flyCaptureToThumbnail(_ page: UIImage) {
    // Thumbnail nhận ảnh ngay: hiệu ứng chỉ là lớp phủ tạm bên trên nó.
    thumbnailView.image = page
    thumbnailView.isHidden = false

    view.layoutIfNeeded()
    let destination = thumbnailView.frame
    let stage = view.bounds
    guard destination.width > 0, stage.width > 0 else { return }

    let flyer = UIImageView(image: page)
    // Cùng `contentMode` với đích đến, nếu không thì lúc hạ cánh ảnh đang
    // letterbox trong khi thumbnail thật thì cắt đầy khung.
    flyer.contentMode = .scaleAspectFill
    flyer.clipsToBounds = true
    flyer.layer.cornerRadius = 10
    flyer.layer.borderWidth = 2
    flyer.layer.borderColor = UIColor.white.cgColor
    // Khung phải mang đúng tỉ lệ của ảnh, không phải tỉ lệ màn hình: viền và bo
    // góc vẽ theo khung, nên khung rộng hơn ảnh là viền hở ra khỏi mép ảnh.
    flyer.frame = Self.aspectFitted(
      page.size,
      in: stage.insetBy(dx: stage.width * 0.12, dy: stage.height * 0.12)
    )
    view.addSubview(flyer)

    // Thumbnail lặn đi trong lúc ảnh đang bay tới, nếu không sẽ thấy hai ảnh.
    thumbnailView.alpha = 0
    cropBadge.alpha = 0

    UIView.animate(
      withDuration: Self.flyTravelDuration,
      delay: Self.flyHoldDuration,
      usingSpringWithDamping: 0.88,
      initialSpringVelocity: 0.25,
      options: [.curveEaseInOut],
      animations: {
        flyer.frame = destination
        flyer.layer.cornerRadius = 6
        flyer.alpha = 0.9
      },
      completion: { [weak self] _ in
        flyer.removeFromSuperview()
        guard let self else { return }
        self.thumbnailView.alpha = 1
        self.cropBadge.alpha = 1
        // Nảy nhẹ để mắt bắt được chỗ ảnh vừa rơi vào.
        self.thumbnailView.transform = CGAffineTransform(scaleX: 1.18, y: 1.18)
        UIView.animate(withDuration: Self.flyBounceDuration) {
          self.thumbnailView.transform = .identity
        }
      }
    )
  }

  private static let originalFileName = "pdf_scan_last_capture.jpg"

  private var originalFileURL: URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(Self.originalFileName)
  }

  /// Overwrites the single scratch file. Only the newest capture is editable,
  /// so only the newest one is kept.
  private func storeOriginal(_ data: Data, quad: PdfScanQuad) {
    let url = originalFileURL
    do {
      try data.write(to: url, options: .atomic)
      lastOriginalURL = url
      lastAppliedQuad = quad
    } catch {
      // The page itself is already delivered; losing this only costs the
      // ability to re-crop it, so it fails quietly.
      lastOriginalURL = nil
      lastAppliedQuad = nil
    }
  }

  func discardStoredOriginal() {
    if let lastOriginalURL {
      try? FileManager.default.removeItem(at: lastOriginalURL)
    }
    lastOriginalURL = nil
    lastAppliedQuad = nil
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
