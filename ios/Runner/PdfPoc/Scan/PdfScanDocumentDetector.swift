import CoreImage
import CoreVideo
import Foundation
import Vision

/// The four corners of a detected page, normalised to the image and in Vision's
/// coordinate space: origin bottom-left, y up.
///
/// Kept in Vision's space rather than converted on detection because that is
/// also `CIPerspectiveCorrection`'s space — the correction is the whole point of
/// detecting, and every conversion in between is a chance to flip an axis.
struct PdfScanQuad {
  var topLeft: CGPoint
  var topRight: CGPoint
  var bottomLeft: CGPoint
  var bottomRight: CGPoint

  var corners: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

  /// Shoelace area, 0…1 of the frame. Used to reject a detection that found
  /// something page-shaped but far too small to be the page being photographed.
  var area: CGFloat {
    let points = corners
    var sum: CGFloat = 0
    for index in points.indices {
      let current = points[index]
      let next = points[(index + 1) % points.count]
      sum += current.x * next.y - next.x * current.y
    }
    return abs(sum) / 2
  }

  /// Largest distance any corner moved between two detections. The stability
  /// test is per corner, not on the centre: a page can rotate or skew about a
  /// steady centre while the frame is still moving.
  func maxCornerDistance(to other: PdfScanQuad) -> CGFloat {
    zip(corners, other.corners)
      .map { hypot($0.x - $1.x, $0.y - $1.y) }
      .max() ?? .greatestFiniteMagnitude
  }

  init(_ observation: VNRectangleObservation) {
    topLeft = observation.topLeft
    topRight = observation.topRight
    bottomLeft = observation.bottomLeft
    bottomRight = observation.bottomRight
  }

  init(corners: [CGPoint]) {
    topLeft = corners[0]
    topRight = corners[1]
    bottomRight = corners[2]
    bottomLeft = corners[3]
  }

  /// Rejects detections that are page-shaped only by accident.
  ///
  /// Segmentation returns *something* for almost any frame, and a bad quad is
  /// worse than none: it drives a perspective correction, so a degenerate one
  /// produces a page sheared into a wedge. Three things disqualify it — too
  /// small to be the sheet in hand, an aspect ratio no paper has, and a
  /// non-convex outline, which means the corners came back crossed or
  /// collapsed onto each other.
  var isPlausible: Bool {
    guard area >= 0.10 else { return false }

    let width = (hypot(topRight.x - topLeft.x, topRight.y - topLeft.y)
      + hypot(bottomRight.x - bottomLeft.x, bottomRight.y - bottomLeft.y)) / 2
    let height = (hypot(bottomLeft.x - topLeft.x, bottomLeft.y - topLeft.y)
      + hypot(bottomRight.x - topRight.x, bottomRight.y - topRight.y)) / 2
    guard width > 0.05, height > 0.05 else { return false }

    // A4 is 1.41, US Letter 1.29, a receipt far more. The bound is generous on
    // the long side and tight on the square side, where a bad detection lands.
    let aspect = max(width, height) / min(width, height)
    guard aspect <= 6 else { return false }

    return isConvex
  }

  /// Moves one corner, indexed the same way `corners` orders them.
  mutating func setCorner(at index: Int, to point: CGPoint) {
    switch index {
    case 0: topLeft = point
    case 1: topRight = point
    case 2: bottomRight = point
    default: bottomLeft = point
    }
  }

  /// Every cross product of consecutive edges must share a sign.
  ///
  /// Also the gate on the corner editor: a crossed or collapsed outline drives
  /// `CIPerspectiveCorrection` into producing a wedge, so it is refused before
  /// it gets there rather than after.
  var isConvex: Bool {
    let points = corners
    var sign: CGFloat = 0
    for index in points.indices {
      let a = points[index]
      let b = points[(index + 1) % points.count]
      let c = points[(index + 2) % points.count]
      let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
      if cross != 0 {
        if sign == 0 {
          sign = cross
        } else if (cross > 0) != (sign > 0) {
          return false
        }
      }
    }
    return sign != 0
  }

  /// Exponential blend toward a new detection.
  ///
  /// Vision's corners jitter by a pixel or two between frames even on a still
  /// page, which reads as a nervous overlay. Smoothing is cosmetic on the
  /// overlay but load-bearing for the stability test: it keeps the noise from
  /// being mistaken for movement.
  func blended(towards other: PdfScanQuad, factor: CGFloat) -> PdfScanQuad {
    func mix(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
      CGPoint(x: a.x + (b.x - a.x) * factor, y: a.y + (b.y - a.y) * factor)
    }
    return PdfScanQuad(corners: [
      mix(topLeft, other.topLeft),
      mix(topRight, other.topRight),
      mix(bottomRight, other.bottomRight),
      mix(bottomLeft, other.bottomLeft),
    ])
  }
}

/// Finds the page in a frame.
///
/// One request object, reused: `VNDetectDocumentSegmentationRequest` builds a
/// model on first use, and creating it per frame would dominate the frame
/// budget.
final class PdfScanDocumentDetector {
  private let request: VNDetectDocumentSegmentationRequest = {
    let request = VNDetectDocumentSegmentationRequest()
    // The quad is all this needs; the segmentation mask is the expensive part
    // of the output and nothing here consumes it.
    request.preferBackgroundProcessing = false
    return request
  }()

  /// Below this the observation is a guess about a frame with no page in it.
  private static let minimumConfidence: VNConfidence = 0.5

  private let queue = DispatchQueue(label: "pdf.scan.detector")

  func detect(in pixelBuffer: CVPixelBuffer) -> PdfScanQuad? {
    perform { try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform([$0]) }
  }

  func detect(in image: CIImage) -> PdfScanQuad? {
    perform { try VNImageRequestHandler(ciImage: image, options: [:]).perform([$0]) }
  }

  private func perform(
    _ body: (VNDetectDocumentSegmentationRequest) throws -> Void
  ) -> PdfScanQuad? {
    queue.sync {
      do {
        try body(request)
      } catch {
        return nil
      }
      guard let observation = request.results?.first,
            observation.confidence >= Self.minimumConfidence else {
        return nil
      }
      let quad = PdfScanQuad(observation)
      return quad.isPlausible ? quad : nil
    }
  }
}

/// Decides when the frame has held still long enough to shoot.
///
/// Auto-capture is the part of a scanner that is felt rather than seen. Too
/// strict and it never fires, so the user hunts for the shutter; too loose and
/// it fires mid-movement and every page comes out motion-blurred. The rule here
/// is deliberately conservative on both axes — a large page, held steady, for
/// most of a second — with a manual shutter always available as the escape.
struct PdfScanCaptureStability {
  /// Minimum share of the frame the page must fill. Below this the detection is
  /// as likely to be a book on a desk in the background as the page in hand.
  static let minimumArea: CGFloat = 0.18

  /// How far a corner may drift between detections and still count as still,
  /// normalised to the frame. Detections are close together in time, so a
  /// genuinely still page moves very little between two of them.
  static let cornerTolerance: CGFloat = 0.015

  /// Consecutive steady detections required. At the ~15 fps this runs at, this
  /// is a little over half a second.
  static let requiredSteadyFrames = 10

  /// How far each detection pulls the smoothed quad. Low enough to absorb
  /// per-frame jitter, high enough that the overlay still tracks a moving page
  /// rather than lagging behind it.
  static let smoothingFactor: CGFloat = 0.45

  private var previous: PdfScanQuad?
  private var steadyFrames = 0

  /// Set after a capture so the same held-still page does not immediately
  /// trigger a second one. Cleared once the frame moves again.
  private var isLatched = false

  mutating func reset() {
    previous = nil
    steadyFrames = 0
    isLatched = true
  }

  /// Returns true on the frame the capture should fire.
  mutating func update(with quad: PdfScanQuad?) -> Bool {
    guard let quad, quad.area >= Self.minimumArea else {
      previous = nil
      steadyFrames = 0
      // Losing the page is what releases the latch: it is the clearest signal
      // the user has moved on to the next sheet.
      isLatched = false
      return false
    }

    defer { previous = quad }
    guard let previous else {
      steadyFrames = 0
      return false
    }

    if quad.maxCornerDistance(to: previous) <= Self.cornerTolerance {
      steadyFrames += 1
    } else {
      steadyFrames = 0
      isLatched = false
    }

    guard !isLatched, steadyFrames >= Self.requiredSteadyFrames else { return false }
    steadyFrames = 0
    isLatched = true
    return true
  }
}
