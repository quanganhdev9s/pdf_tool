import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Metal
import UIKit

/// Per-preset pipeline constants.
///
/// Every value here was chosen by rendering the pipeline over a real dim-lit
/// capture and comparing the output, not by reasoning from the symptom. That
/// distinction matters: an earlier pass tuned these by argument alone and made
/// the output worse. Each note below records what was observed at which value,
/// so the next change starts from evidence rather than from scratch.
///
/// Re-tuning means rendering variants over sample captures again — the sample
/// set these were derived from is no longer in the repository.
///
/// The constants behind background estimation, shadow detection, gain limiting,
/// white balance and the adaptive threshold (`backgroundDilationFraction`,
/// `backgroundBlurFraction`, `shadowMaskOnset`/`shadowMaskFull`, `maxGain`,
/// `whiteBalanceGainRange`, `adaptiveMeanFraction`, `adaptiveThreshold`) are
/// starting points reasoned from what each stage does, *not* swept over
/// captures. They are the first thing to check if output regresses.
enum PdfScanTuning {
  /// Radius of the morphological maximum that removes text from the background
  /// estimate, as a fraction of the long edge.
  ///
  /// Has to be wider than a stroke and narrower than a shadow. A plain blur
  /// cannot do this job: ink pulls the average down, so a dense paragraph reads
  /// as a shadow and gets lifted until the text goes gray. Taking the local
  /// maximum first throws the ink away and leaves the paper.
  static let backgroundDilationFraction: CGFloat = 0.006

  /// Absolute ceiling on the dilation radius. Morphology cost grows with
  /// radius, and past this the estimate stops improving.
  static let backgroundDilationMaxPixels: Float = 18

  /// Blur applied after the dilation, as a fraction of the long edge. Smooths
  /// the estimate into an illumination field; wide, because lighting varies
  /// slowly and anything sharper starts tracking page content.
  static let backgroundBlurFraction: CGFloat = 0.04

  /// Where the shadow mask turns on, as a shortfall from the paper level:
  /// `(paper - background) / paper`. Below the first value nothing is treated
  /// as shadow, above the second the correction is applied in full, and the
  /// ramp between them is what keeps a lifted region from showing a visible
  /// edge against its surroundings.
  static let shadowMaskOnset: CGFloat = 0.12
  static let shadowMaskFull: CGFloat = 0.45

  /// Ceiling on the correction gain, as a function of `shadowLift`.
  ///
  /// The single most important constant here, and the reason this pipeline
  /// bounds gain instead of clamping the divisor's floor. An unbounded divide
  /// multiplies sensor noise by the same factor it multiplies signal, so a
  /// corner the light never reached explodes into full-amplitude colour
  /// confetti. Around 2–2.5x a genuinely dim region becomes readable while its
  /// noise stays under what denoising can absorb.
  static func maxGain(shadowLift: CGFloat) -> CGFloat {
    let t = min(max(shadowLift, 0), 1)
    return 2.0 + 0.5 * t
  }

  /// Where the two controls that read it sit on their ranges: `maxGain` and
  /// `adaptiveThreshold`. A single constant rather than per-page state — shadow
  /// correction is automatic, so nothing varies it from one page to the next.
  static let shadowLift: CGFloat = 0.5

  /// Bounds on the per-channel gains auto white balance may apply.
  ///
  /// Gray-world assumes the average of the frame is neutral, which holds for a
  /// document — paper is most of the pixels and ink is roughly neutral. It
  /// stops holding on coloured stock or a page that is mostly a photograph, so
  /// the gains are clamped: a warm cast comes out, a genuinely yellow page
  /// stays yellow instead of being bleached to white.
  static let whiteBalanceGainRange: ClosedRange<CGFloat> = 0.75...1.35

  /// Runs *after* the correction. Before it, shadow noise is only a couple of
  /// levels deep and indistinguishable from paper texture; after it, it is the
  /// loudest thing in the frame.
  static let noiseLevel: Float = 0.05
  static let noiseSharpness: Float = 0.30

  /// `CIDocumentEnhancer` strength.
  ///
  /// Measured contribution is small: on a dim capture, running it alone left
  /// the unlit corner black and the warm cast fully intact. It adds some local
  /// contrast, so it stays, but the correction does the real work.
  static let enhancerAmount: Float = 1.0

  /// Negative vibrance moves weakly saturated pixels much further than strongly
  /// saturated ones, so it drains a residual cast while leaving real ink
  /// coloured. At -0.85 it also drained blue ballpoint, which reads as low
  /// saturation once the page is flattened — hence the gentler value here.
  static let chromaSuppression: Float = -0.45

  /// Luminance above which a pixel is pulled to paper white.
  static let paperWhitePoint: CGFloat = 0.86

  /// Radius of the local-mean blur behind the adaptive threshold, as a fraction
  /// of the long edge. Has to be comfortably wider than a stroke or the mean
  /// tracks the ink itself and glyphs hollow out; narrow enough that it follows
  /// shading the correction left behind.
  static let adaptiveMeanFraction: CGFloat = 0.015

  /// How far below its local mean a pixel must sit to be called ink, as a ratio
  /// of the two. Bradley's adaptive threshold in the same shape: compare
  /// against the neighbourhood, not against a number that has to be right for
  /// the whole page.
  static func adaptiveThreshold(shadowLift: CGFloat) -> CGFloat {
    let t = min(max(shadowLift, 0), 1)
    return 0.94 - (0.94 - 0.84) * t
  }

  /// Long-edge ceiling for the processed image written to disk.
  static let processedLongEdge: CGFloat = 2400
  static let processedJpegQuality: CGFloat = 0.92
}

/// The Metal-backed `CIContext` every scan render goes through.
///
/// One for the whole app, not one per processor. A `CIContext` owns a compiled
/// shader cache, an intermediate-buffer pool and a command queue; a second one
/// duplicates all three and shares none of them, so the review canvas and the
/// full-resolution writer were each paying to warm up the same kernels.
///
/// Core Image already picks Metal on a real device — this only makes the device
/// explicit and pins the one setting that matters. `workingFormat: .RGBAh` keeps
/// the chain in half-float: the pipeline divides by small numbers in several
/// places, which 8-bit-per-channel intermediates cannot carry, and half-float is
/// roughly half the bandwidth of full float for the same headroom.
///
/// The working *colour space* is deliberately left at the default. Every tone
/// curve in this file — the paper-white curve, the shadow-mask ramp, the
/// adaptive threshold — is a set of coordinates in whatever space the chain
/// runs in, so changing it silently re-tunes all of them.
enum PdfScanRenderContext {
  static let shared: CIContext = {
    let options: [CIContextOption: Any] = [
      .workingFormat: CIFormat.RGBAh,
      .cacheIntermediates: true,
    ]
    if let device = MTLCreateSystemDefaultDevice() {
      return CIContext(mtlDevice: device, options: options)
    }
    // Simulator without a Metal device, or a device that failed to hand one
    // over. Correctness does not depend on the renderer, only speed does.
    return CIContext(options: options)
  }()
}

/// Turns a captured page into its enhanced form. Stateless apart from the
/// shared `CIContext`.
final class PdfScanImageProcessor {
  private var context: CIContext { PdfScanRenderContext.shared }

  /// Runs `preset` over the page's original capture and writes the result.
  /// Always reads `originalURL`, never the previous processed output.
  func process(
    page: PdfScanPageRecord,
    preset: PdfScanPreset,
    destination: URL
  ) throws {
    guard preset != .original else { return }

    guard let source = UIImage(contentsOfFile: page.originalURL.path),
          let sourceCG = source.cgImage else {
      throw PdfPocError(
        code: "scan_processing_failed",
        message: "Could not read the captured page for processing.",
        details: "pageId=\(page.id)"
      )
    }

    let scaled = downscaled(sourceCG)
    let extent = CGRect(x: 0, y: 0, width: scaled.width, height: scaled.height)
    let output = render(source: CIImage(cgImage: scaled), extent: extent, preset: preset)

    // Encoded straight off the render rather than via `CGImage` and `UIImage`:
    // those are two extra full-page copies of a 2400px image, per page, for a
    // file that is about to be written anyway.
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
      throw PdfPocError(
        code: "scan_processing_failed",
        message: "Could not render the enhanced page.",
        details: "pageId=\(page.id) preset=\(preset.storageKey)"
      )
    }

    do {
      try context.writeJPEGRepresentation(
        of: output.cropped(to: extent),
        to: destination,
        colorSpace: colorSpace,
        options: [
          kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption:
            PdfScanTuning.processedJpegQuality,
        ]
      )
    } catch {
      throw PdfPocError(
        code: "scan_processing_failed",
        message: "Could not encode the enhanced page.",
        details: "pageId=\(page.id) \(error.localizedDescription)"
      )
    }
  }

  // MARK: - Pipelines

  /// The pipeline, in the order the stages depend on each other.
  ///
  ///     luma → background estimate → shadow mask → bounded correction
  ///       → white balance → denoise → preset
  ///
  /// The order is not cosmetic.
  ///
  /// Everything measured is measured on luma, because a colour cast makes
  /// per-channel brightness lie: a yellow page reads as a blue-channel shadow.
  /// The background estimate strips text out before it strips lighting out, so
  /// a dense paragraph is not mistaken for a dark region. The mask exists so
  /// the correction can be *selective* — a page is usually mostly fine, and a
  /// global divide spends gain on parts that never needed it, which is how a
  /// well-lit half ends up washed out. Gain is bounded because a divide
  /// multiplies noise exactly as much as it multiplies signal.
  ///
  /// White balance comes *after* the correction rather than before: the cast in
  /// a shadow is not the cast in the lit part of the same page, so measuring it
  /// first means measuring an average of two different casts. Once lighting is
  /// flat there is one cast to remove. Denoise then runs on what the gain
  /// exposed, before the preset, so the threshold is not thresholding noise.
  ///
  private func render(
    source: CIImage,
    extent: CGRect,
    preset: PdfScanPreset
  ) -> CIImage {
    let shadowLift = PdfScanTuning.shadowLift
    guard preset != .original else { return source }

    var working = shadowCorrected(source, extent: extent, shadowLift: shadowLift)
    working = whiteBalanced(working, extent: extent)
    working = denoised(working)

    switch preset {
    case .original:
      return source

    case .enhancedColor:
      working = documentEnhanced(working)
      let vibrance = CIFilter.vibrance()
      vibrance.inputImage = working
      vibrance.amount = PdfScanTuning.chromaSuppression
      working = vibrance.outputImage ?? working
      return paperWhitened(working)

    case .cleanGrayscale:
      working = desaturated(working)
      working = documentEnhanced(working)
      return paperWhitened(working)

    case .blackAndWhite:
      working = desaturated(working)
      return adaptiveThresholded(working, extent: extent, shadowLift: shadowLift)
    }
  }

  // MARK: - Shadow correction

  /// Steps 1–4: luma, background estimate, shadow mask, bounded correction.
  ///
  /// The correction is expressed as a *divisor image* rather than a gain image
  /// because Core Image's multiply blend cannot produce a result above 1, while
  /// its divide blend can. Divisor 1 means "leave this pixel alone", so mixing
  /// the divisor toward white by the shadow mask is exactly "apply the
  /// correction only where shadow was detected".
  private func shadowCorrected(
    _ image: CIImage,
    extent: CGRect,
    shadowLift: CGFloat
  ) -> CIImage {
    let luma = lumaExtracted(image)
    guard let background = estimatedBackground(luma, extent: extent),
          let paperLevel = brightestLevel(of: background, extent: extent) else {
      return image
    }

    let ceiling = PdfScanTuning.maxGain(shadowLift: shadowLift)

    // background / paperLevel, floored so the gain it implies cannot exceed
    // `ceiling`, and capped at 1 so a region brighter than the paper estimate
    // is never darkened.
    let normalize = CIFilter.colorMatrix()
    normalize.inputImage = background
    let scale = 1 / paperLevel
    normalize.rVector = CIVector(x: scale, y: 0, z: 0, w: 0)
    normalize.gVector = CIVector(x: 0, y: scale, z: 0, w: 0)
    normalize.bVector = CIVector(x: 0, y: 0, z: scale, w: 0)
    normalize.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
    guard let normalized = normalize.outputImage?.cropped(to: extent) else { return image }

    let floor = 1 / ceiling
    let clamp = CIFilter.colorClamp()
    clamp.inputImage = normalized
    clamp.minComponents = CIVector(x: floor, y: floor, z: floor, w: 0)
    clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
    guard var divisor = clamp.outputImage?.cropped(to: extent) else { return image }

    // Mix toward white — no correction — everywhere the detector did not call
    // shadow. This is what keeps a page that is mostly fine from being spent
    // gain it never needed.
    let mask = shadowMask(normalized: normalized, extent: extent)
    let restrict = CIFilter.blendWithMask()
    restrict.inputImage = divisor
    restrict.backgroundImage = CIImage(color: .white).cropped(to: extent)
    restrict.maskImage = mask
    divisor = restrict.outputImage?.cropped(to: extent) ?? divisor

    // Verified by rendering both arrangements: divide blend treats
    // `backgroundImage` as the base, so this evaluates image / divisor.
    let divide = CIFilter.divideBlendMode()
    divide.inputImage = divisor
    divide.backgroundImage = image
    return divide.outputImage?.cropped(to: extent) ?? image
  }

  /// Rec. 709 luma into all three channels.
  private func lumaExtracted(_ image: CIImage) -> CIImage {
    let weights = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
    let matrix = CIFilter.colorMatrix()
    matrix.inputImage = image
    matrix.rVector = weights
    matrix.gVector = weights
    matrix.bVector = weights
    matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
    return matrix.outputImage ?? image
  }

  /// The paper, without the text on it: a morphological maximum to erase ink,
  /// then a wide blur to turn what is left into a smooth illumination field.
  private func estimatedBackground(_ luma: CIImage, extent: CGRect) -> CIImage? {
    let longEdge = max(extent.width, extent.height)

    // Rectangle rather than circle: `CIMorphologyRectangleMaximum` is
    // separable, so its cost is linear in the radius where the circular
    // variant's is quadratic. The estimate is blurred to nothing sharper than a
    // lighting field two lines later, so the shape of the structuring element
    // does not survive to the output.
    let radius = min(
      max(Float(longEdge * PdfScanTuning.backgroundDilationFraction), 1),
      PdfScanTuning.backgroundDilationMaxPixels
    )
    let side = max(Int(radius) * 2 + 1, 3)
    let dilate = CIFilter.morphologyRectangleMaximum()
    dilate.inputImage = luma.clampedToExtent()
    dilate.width = Float(side)
    dilate.height = Float(side)
    guard let dilated = dilate.outputImage else { return nil }

    let blur = CIFilter.boxBlur()
    blur.inputImage = dilated.clampedToExtent()
    blur.radius = max(Float(longEdge * PdfScanTuning.backgroundBlurFraction), 1)
    return blur.outputImage?.cropped(to: extent)
  }

  /// How bright the paper is where the light reached it. One 1x1 readback per
  /// render — a GPU-to-CPU sync, which is why it happens over a `CIAreaMaximum`
  /// rather than by sampling pixels.
  ///
  /// Taken from the *background estimate*, not the capture: a specular glare
  /// spot survives on the original and would set the reference far above real
  /// paper, leaving the whole page looking under-corrected.
  private func brightestLevel(of background: CIImage, extent: CGRect) -> CGFloat? {
    let maximum = CIFilter.areaMaximum()
    maximum.inputImage = background
    maximum.extent = extent
    guard let reduced = maximum.outputImage else { return nil }

    var pixel = [Float](repeating: 0, count: 4)
    context.render(
      reduced,
      toBitmap: &pixel,
      rowBytes: MemoryLayout<Float>.size * 4,
      bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
      format: .RGBAf,
      colorSpace: CGColorSpaceCreateDeviceRGB()
    )

    let level = CGFloat(pixel[0])
    // A frame with no bright region at all is not a document under uneven
    // light, it is a failed capture. Correcting from it would invent a paper
    // level that is not there.
    return level > 0.12 ? level : nil
  }

  /// Soft mask over the regions the background estimate says are in shadow.
  ///
  /// Soft on purpose: a hard cut would leave a visible seam exactly where the
  /// gain changes, which reads as a smudge around the recovered patch.
  private func shadowMask(normalized: CIImage, extent: CGRect) -> CIImage {
    // 1 - background/paper: how far this region falls short of lit paper.
    let shortfall = CIFilter.colorMatrix()
    shortfall.inputImage = normalized
    shortfall.rVector = CIVector(x: -1, y: 0, z: 0, w: 0)
    shortfall.gVector = CIVector(x: 0, y: -1, z: 0, w: 0)
    shortfall.bVector = CIVector(x: 0, y: 0, z: -1, w: 0)
    shortfall.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
    shortfall.biasVector = CIVector(x: 1, y: 1, z: 1, w: 0)
    guard let deficit = shortfall.outputImage?.cropped(to: extent) else { return normalized }

    let onset = PdfScanTuning.shadowMaskOnset
    let full = PdfScanTuning.shadowMaskFull
    let curve = CIFilter.toneCurve()
    curve.inputImage = deficit
    curve.point0 = CGPoint(x: 0, y: 0)
    curve.point1 = CGPoint(x: onset, y: 0.02)
    curve.point2 = CGPoint(x: (onset + full) / 2, y: 0.5)
    curve.point3 = CGPoint(x: full, y: 0.98)
    curve.point4 = CGPoint(x: 1, y: 1)
    return curve.outputImage?.cropped(to: extent) ?? deficit
  }

  // MARK: - Colour and preset stages

  /// Gray-world auto white balance: measure the average colour of the frame and
  /// scale each channel until that average is neutral.
  ///
  /// Cheaper and steadier here than a white-patch estimate. The brightest pixel
  /// on a document photo is as often a specular glare spot as it is paper, and
  /// keying off it makes the correction jump between two captures of the same
  /// page. The average moves smoothly.
  private func whiteBalanced(_ image: CIImage, extent: CGRect) -> CIImage {
    guard let gains = averageColourGains(image, extent: extent) else { return image }

    let matrix = CIFilter.colorMatrix()
    matrix.inputImage = image
    matrix.rVector = CIVector(x: gains.x, y: 0, z: 0, w: 0)
    matrix.gVector = CIVector(x: 0, y: gains.y, z: 0, w: 0)
    matrix.bVector = CIVector(x: 0, y: 0, z: gains.z, w: 0)
    matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
    return matrix.outputImage?.cropped(to: extent) ?? image
  }

  private func averageColourGains(_ image: CIImage, extent: CGRect) -> CIVector? {
    let average = CIFilter.areaAverage()
    average.inputImage = image
    average.extent = extent
    guard let averaged = average.outputImage else { return nil }

    var pixel = [Float](repeating: 0, count: 4)
    context.render(
      averaged,
      toBitmap: &pixel,
      rowBytes: MemoryLayout<Float>.size * 4,
      bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
      format: .RGBAf,
      colorSpace: CGColorSpaceCreateDeviceRGB()
    )

    let r = CGFloat(pixel[0]), g = CGFloat(pixel[1]), b = CGFloat(pixel[2])
    // A frame this dark carries no usable colour information; correcting from
    // it would amplify whatever the sensor happened to guess.
    guard r > 0.02, g > 0.02, b > 0.02 else { return nil }

    let target = (r + g + b) / 3
    let range = PdfScanTuning.whiteBalanceGainRange
    return CIVector(
      x: min(max(target / r, range.lowerBound), range.upperBound),
      y: min(max(target / g, range.lowerBound), range.upperBound),
      z: min(max(target / b, range.lowerBound), range.upperBound)
    )
  }

  /// Adaptive threshold: each pixel is judged against its own neighbourhood,
  /// not against one number chosen for the whole page.
  ///
  /// Same shape as Bradley's method, expressed in the filters already here —
  /// divide by a local mean, then cut at a ratio. A global cut cannot survive a
  /// page that is bright on one side: whatever value keeps faint pencil on the
  /// lit half turns the dim half into a solid blot, which is the exact failure
  /// this pipeline exists to remove. The cut is a steep curve rather than a
  /// hard step so anti-aliased glyph edges keep some weight.
  private func adaptiveThresholded(
    _ image: CIImage,
    extent: CGRect,
    shadowLift: CGFloat
  ) -> CIImage {
    let blur = CIFilter.boxBlur()
    blur.inputImage = image.clampedToExtent()
    blur.radius = max(
      Float(max(extent.width, extent.height) * PdfScanTuning.adaptiveMeanFraction),
      1
    )
    guard let localMean = blur.outputImage?.cropped(to: extent) else {
      return image
    }

    // Floored for the same reason the correction divisor is: a fully black
    // neighbourhood would otherwise divide into unbounded gain.
    let clamp = CIFilter.colorClamp()
    clamp.inputImage = localMean
    clamp.minComponents = CIVector(x: 0.05, y: 0.05, z: 0.05, w: 0)
    clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
    let bounded = clamp.outputImage ?? localMean

    let divide = CIFilter.divideBlendMode()
    divide.inputImage = bounded
    divide.backgroundImage = image
    guard let ratio = divide.outputImage?.cropped(to: extent) else { return image }

    let threshold = PdfScanTuning.adaptiveThreshold(shadowLift: shadowLift)
    let curve = CIFilter.toneCurve()
    curve.inputImage = ratio
    curve.point0 = CGPoint(x: 0, y: 0)
    curve.point1 = CGPoint(x: max(threshold - 0.06, 0.01), y: 0.02)
    curve.point2 = CGPoint(x: threshold, y: 0.5)
    curve.point3 = CGPoint(x: min(threshold + 0.06, 0.99), y: 0.98)
    curve.point4 = CGPoint(x: 1, y: 1)
    return curve.outputImage?.cropped(to: extent) ?? ratio
  }

  private func documentEnhanced(_ image: CIImage) -> CIImage {
    let enhancer = CIFilter.documentEnhancer()
    enhancer.inputImage = image
    enhancer.amount = PdfScanTuning.enhancerAmount
    return enhancer.outputImage ?? image
  }

  private func denoised(_ image: CIImage) -> CIImage {
    let denoise = CIFilter.noiseReduction()
    denoise.inputImage = image
    denoise.noiseLevel = PdfScanTuning.noiseLevel
    denoise.sharpness = PdfScanTuning.noiseSharpness
    return denoise.outputImage ?? image
  }

  private func paperWhitened(_ image: CIImage) -> CIImage {
    let curve = CIFilter.toneCurve()
    curve.inputImage = image
    curve.point0 = CGPoint(x: 0, y: 0)
    curve.point1 = CGPoint(x: 0.25, y: 0.20)
    curve.point2 = CGPoint(x: 0.55, y: 0.58)
    curve.point3 = CGPoint(x: PdfScanTuning.paperWhitePoint, y: 0.97)
    curve.point4 = CGPoint(x: 1, y: 1)
    return curve.outputImage ?? image
  }

  private func desaturated(_ image: CIImage) -> CIImage {
    let controls = CIFilter.colorControls()
    controls.inputImage = image
    controls.saturation = 0
    controls.brightness = 0
    controls.contrast = 1
    return controls.outputImage ?? image
  }

  // MARK: - Scaling

  private func downscaled(_ image: CGImage) -> CGImage {
    let longEdge = CGFloat(max(image.width, image.height))
    guard longEdge > PdfScanTuning.processedLongEdge else { return image }

    let scale = PdfScanTuning.processedLongEdge / longEdge
    let size = CGSize(
      width: max((CGFloat(image.width) * scale).rounded(), 1),
      height: max((CGFloat(image.height) * scale).rounded(), 1)
    )

    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    let resized = renderer.image { _ in
      UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
    }
    return resized.cgImage ?? image
  }
}
