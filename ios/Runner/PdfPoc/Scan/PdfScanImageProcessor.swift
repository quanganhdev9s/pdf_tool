import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Metal
import UIKit

/// Pipeline constants.
///
/// These were derived by rendering variants and comparing output, not by
/// reasoning from the symptom — an earlier pass tuned them by argument alone
/// and made the output worse. Re-tuning means rendering variants again.
enum PdfScanTuning {
  /// Radius of the morphological maximum that erases ink from the background
  /// estimate, as a fraction of the long edge, and its absolute ceiling.
  ///
  /// Must be wider than a stroke, narrower than a shadow. A plain blur cannot
  /// do this: ink pulls the average down, so a dense paragraph reads as shadow
  /// and gets lifted until the text goes grey.
  static let backgroundDilationFraction: CGFloat = 0.006
  static let backgroundDilationMaxPixels: Float = 18

  /// Blur applied after the dilation. Wide, because lighting varies slowly and
  /// anything sharper starts tracking page content.
  static let backgroundBlurFraction: CGFloat = 0.04

  /// Long edge every measurement pass runs at. The estimate is smooth by
  /// construction, so full resolution buys nothing; only the divide runs full
  /// size.
  static let measurementLongEdge: CGFloat = 512

  /// Share of the brightest pixels treated as glare rather than paper, so one
  /// specular highlight cannot move the paper reference.
  static let paperLevelGlareShare: CGFloat = 0.02

  /// Below this the frame has no bright region at all — a failed capture, not a
  /// document. Flattening is skipped rather than run at full gain over noise.
  static let minimumPaperLevel: CGFloat = 0.12

  /// Ceiling on the correction gain. This high only because the white point
  /// runs after the flattening: amplified paper noise lands above the clip and
  /// disappears. Raise the white point before raising this.
  static let maxGain: CGFloat = 4.5

  /// Bounds on gray-world white balance. Clamped so a warm cast comes out while
  /// genuinely yellow stock stays yellow.
  static let whiteBalanceGainRange: ClosedRange<CGFloat> = 0.75...1.35

  /// Runs after the flattening and before the white point, so the clip decides
  /// paper-versus-ink from a denoised signal rather than from speckle.
  static let noiseLevel: Float = 0.06
  static let noiseSharpness: Float = 0.30

  /// Black and white points for the remap after the flattening. The white point
  /// is a hard clip: a soft roll-off was the previous behaviour and is why the
  /// background came out pale uneven grey — nothing was ever actually white.
  /// Grey mode cuts deeper because tone has to carry the contrast chroma was.
  static let magicColorBlackPoint: CGFloat = 0.16
  static let magicColorWhitePoint: CGFloat = 0.90
  static let grayBlackPoint: CGFloat = 0.20
  static let grayWhitePoint: CGFloat = 0.88

  /// The global cut behind `blackAndWhite`, and the ramp around it that keeps
  /// glyph edges from stair-stepping. Only defensible after the flattening.
  static let binaryCut: CGFloat = 0.62
  static let binarySoftness: CGFloat = 0.03

  /// Positive vibrance after the white point, so a stamp or a highlighter reads
  /// as what it is. The cast is handled by white balance and the clip, not by
  /// draining chroma — draining it also drained blue ballpoint.
  static let chromaBoost: Float = 0.35

  /// How much of the correction Lighten applies.
  ///
  /// Lighten is for pages whose background is artwork. A large photograph
  /// survives both the maximum and the blur, so the full treatment reads it as
  /// illumination and divides it away: measured against a synthetic spread,
  /// full strength landed 0.35 RMS from the original artwork, half strength
  /// 0.17. The cost is that an unevenly lit page keeps some gradient (blank
  /// paper 0.73 rather than 0.99), which is why this is not the default.
  static let lightenFlattenStrength: CGFloat = 0.5

  /// Lighten's tail: lift midtones, and never clip to white — on a magazine
  /// page the "white" would be somebody's photograph.
  static let lightenGamma: Float = 0.80
  static let lightenBlackPoint: CGFloat = 0.02
  static let lightenWhitePoint: CGFloat = 0.96

  /// Auto's classifier. Over synthetic pages under three lighting conditions,
  /// colour share measured 0.0000 on every neutral page, 0.031 on a page
  /// carrying one red stamp and 0.96 on a magazine spread; ink level measured
  /// 0.11 for printed text and 0.60 for pencil. Both thresholds sit in those
  /// gaps.
  static let autoChromaThreshold: CGFloat = 0.12
  static let autoColourShare: CGFloat = 0.02
  static let autoInkPercentile: CGFloat = 0.02
  static let autoFaintInkLevel: CGFloat = 0.45

  /// Unsharp mask, applied last so its bright halo lands in the clipped region
  /// and only the dark side — the side that reads as crisp — survives.
  static let sharpenRadiusFraction: CGFloat = 0.0008
  static let sharpenIntensity: Float = 0.5

  /// Bradley's adaptive threshold: the local-mean radius, and how far below its
  /// mean a pixel must sit to count as ink. The radius must exceed a stroke or
  /// the mean tracks the ink itself and glyphs hollow out.
  static let adaptiveMeanFraction: CGFloat = 0.015
  static let adaptiveThreshold: CGFloat = 0.89

  static let processedLongEdge: CGFloat = 2400
  static let processedJpegQuality: CGFloat = 0.92
}

/// The Metal-backed `CIContext` every scan render goes through — one for the
/// whole app, because a second duplicates the shader cache, buffer pool and
/// command queue and shares none of them.
///
/// `RGBAh` because the pipeline divides by small numbers in several places,
/// which 8-bit intermediates cannot carry. The working *colour space* is left
/// at the default deliberately: every threshold in this file is a coordinate in
/// whatever space the chain runs in, so changing it re-tunes all of them.
enum PdfScanRenderContext {
  static let shared: CIContext = {
    let options: [CIContextOption: Any] = [
      .workingFormat: CIFormat.RGBAh,
      .cacheIntermediates: true,
    ]
    if let device = MTLCreateSystemDefaultDevice() {
      return CIContext(mtlDevice: device, options: options)
    }
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
    // those are two extra full-page copies per page.
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

  // MARK: - Pipeline

  ///     luma → background estimate → flatten → white balance → denoise → tail
  ///
  /// The order is not cosmetic. Measurements run on luma because a colour cast
  /// makes per-channel brightness lie. White balance runs after the flattening,
  /// not before: the cast in a shadow is not the cast in the lit part of the
  /// same page, so measuring first averages two different casts. Every tail
  /// then ends in a *hard* decision about what counts as paper — a clipped
  /// white point or a threshold — which is the difference between this and a
  /// photo filter.
  ///
  /// Auto resolves here, after the shared head: asked of the raw capture, "is
  /// this page coloured" is confounded by cast and shadow; asked after a tail,
  /// the tail has already answered it.
  private func render(
    source: CIImage,
    extent: CGRect,
    preset: PdfScanPreset
  ) -> CIImage {
    guard preset != .original else { return source }

    let strength = preset == .lighten ? PdfScanTuning.lightenFlattenStrength : 1
    var working = illuminationFlattened(source, extent: extent, strength: strength)
    working = whiteBalanced(working, extent: extent)
    working = denoised(working)

    let resolved = preset == .auto ? autoResolved(working, extent: extent) : preset

    switch resolved {
    case .original, .auto:
      // `.original` returned above; `autoResolved` never answers `.auto`.
      return working

    case .lighten:
      let gamma = CIFilter.gammaAdjust()
      gamma.inputImage = working
      gamma.power = PdfScanTuning.lightenGamma
      working = gamma.outputImage?.cropped(to: extent) ?? working
      working = levelled(
        working,
        blackPoint: PdfScanTuning.lightenBlackPoint,
        whitePoint: PdfScanTuning.lightenWhitePoint
      )
      return sharpened(working, extent: extent)

    case .magicColor:
      working = levelled(
        working,
        blackPoint: PdfScanTuning.magicColorBlackPoint,
        whitePoint: PdfScanTuning.magicColorWhitePoint
      )
      let vibrance = CIFilter.vibrance()
      vibrance.inputImage = working
      vibrance.amount = PdfScanTuning.chromaBoost
      working = vibrance.outputImage?.cropped(to: extent) ?? working
      return sharpened(working, extent: extent)

    case .grayMode:
      working = levelled(
        lumaExtracted(working),
        blackPoint: PdfScanTuning.grayBlackPoint,
        whitePoint: PdfScanTuning.grayWhitePoint
      )
      return sharpened(working, extent: extent)

    case .blackAndWhite:
      let cut = PdfScanTuning.binaryCut
      let softness = PdfScanTuning.binarySoftness
      return levelled(
        lumaExtracted(working),
        blackPoint: max(cut - softness, 0),
        whitePoint: min(cut + softness, 1)
      ).cropped(to: extent)

    case .blackAndWhite2:
      return adaptiveThresholded(lumaExtracted(working), extent: extent)
    }
  }

  // MARK: - Illumination flattening

  /// Divides the page by its own illumination field.
  ///
  /// The divisor is the estimate *itself*, not the estimate normalised by the
  /// paper level. Normalising made the correction relative, so an evenly lit
  /// but underexposed capture — no shadow to detect — passed through untouched
  /// and landed as grey paper (0.758 in simulation, against pure white here).
  /// Dividing by the estimate is the reflectance formulation: blank paper is
  /// 1.0 regardless of exposure, which is what lets one global white point run
  /// afterwards.
  ///
  /// Expressed as a divisor rather than a gain because Core Image's multiply
  /// blend cannot produce a result above 1 and every gain here is above 1.
  private func illuminationFlattened(
    _ image: CIImage,
    extent: CGRect,
    strength: CGFloat
  ) -> CIImage {
    guard let estimate = estimatedBackground(lumaExtracted(image), extent: extent),
          hasUsablePaperLevel(estimate) else {
      return image
    }

    // Floored so the implied gain cannot exceed `maxGain`, capped at 1 so a
    // specular highlight is never darkened. Built at measurement size: the
    // estimate carries no detail finer than the blur that made it.
    let floor = 1 / PdfScanTuning.maxGain
    let clamp = CIFilter.colorClamp()
    clamp.inputImage = estimate
    clamp.minComponents = CIVector(x: floor, y: floor, z: floor, w: 0)
    clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
    guard var divisor = clamp.outputImage?.cropped(to: estimate.extent) else { return image }

    // Mix toward 1 — toward "change nothing" — for a partial correction.
    if strength < 1 {
      let soften = CIFilter.colorMatrix()
      soften.inputImage = divisor
      soften.rVector = CIVector(x: strength, y: 0, z: 0, w: 0)
      soften.gVector = CIVector(x: 0, y: strength, z: 0, w: 0)
      soften.bVector = CIVector(x: 0, y: 0, z: strength, w: 0)
      soften.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
      let rest = 1 - strength
      soften.biasVector = CIVector(x: rest, y: rest, z: rest, w: 0)
      divisor = soften.outputImage?.cropped(to: estimate.extent) ?? divisor
    }

    divisor = divisor
      .transformed(by: CGAffineTransform(
        scaleX: extent.width / max(estimate.extent.width, 1),
        y: extent.height / max(estimate.extent.height, 1)
      ))
      .clampedToExtent()
      .cropped(to: extent)

    // Divide blend treats `backgroundImage` as the base: this is image/divisor.
    let divide = CIFilter.divideBlendMode()
    divide.inputImage = divisor
    divide.backgroundImage = image
    return divide.outputImage?.cropped(to: extent) ?? image
  }

  /// The paper without the text on it, at measurement resolution: a
  /// morphological maximum to erase ink, then a wide blur to smooth what is
  /// left into an illumination field.
  ///
  /// Rectangle rather than circle because `CIMorphologyRectangleMaximum` is
  /// separable — linear in the radius where the circular variant is quadratic —
  /// and the blur two lines later erases the shape of the structuring element.
  private func estimatedBackground(_ luma: CIImage, extent: CGRect) -> CIImage? {
    let (small, smallExtent) = measurementScaled(luma, extent: extent)
    let longEdge = max(smallExtent.width, smallExtent.height)

    let radius = min(
      max(longEdge * PdfScanTuning.backgroundDilationFraction, 1),
      CGFloat(PdfScanTuning.backgroundDilationMaxPixels)
    )
    let dilate = CIFilter.morphologyRectangleMaximum()
    dilate.inputImage = small.clampedToExtent()
    dilate.width = Float(max(Int(radius) * 2 + 1, 3))
    dilate.height = dilate.width
    guard let dilated = dilate.outputImage else { return nil }

    let blur = CIFilter.boxBlur()
    blur.inputImage = dilated.clampedToExtent()
    blur.radius = max(Float(longEdge * PdfScanTuning.backgroundBlurFraction), 1)
    return blur.outputImage?.cropped(to: smallExtent)
  }

  /// Whether the frame has a bright enough region to be a document at all.
  /// A gate, not a scale factor — it exists so a black frame is passed through
  /// instead of being multiplied by the gain ceiling into noise.
  private func hasUsablePaperLevel(_ estimate: CIImage) -> Bool {
    guard let counts = histogram(of: estimate, extent: estimate.extent),
          let level = percentile(
            counts,
            share: PdfScanTuning.paperLevelGlareShare,
            fromTop: true
          ) else {
      return false
    }
    return level > PdfScanTuning.minimumPaperLevel
  }

  // MARK: - Auto

  /// Picks a preset from the page's own content: how much of the page is
  /// coloured, then how dark its darkest content is.
  ///
  /// Colour is a share above a threshold rather than an average — a page with
  /// one red stamp is a colour document even though 97% of it is black on
  /// white, and an average lets the white drown the stamp.
  ///
  /// It never answers `.blackAndWhite`, which is honest rather than an
  /// oversight: telling clean printed text (where a global cut is ideal) from a
  /// page carrying a greyscale photograph (where it destroys the photograph)
  /// needs a text-versus-continuous-tone measure, and the candidate for it —
  /// midtone mass under a wide blur — overlapped at 0.026 against 0.031 once
  /// the halo around a hard shadow edge fed into it. `.grayMode` is the
  /// conservative answer: never as crisp, never destructive.
  private func autoResolved(_ image: CIImage, extent: CGRect) -> PdfScanPreset {
    let (small, smallExtent) = measurementScaled(image, extent: extent)

    var colourShare: CGFloat = 0
    if let chroma = chromaExtracted(small, extent: smallExtent),
       let counts = histogram(of: chroma, extent: smallExtent) {
      colourShare = share(counts, above: PdfScanTuning.autoChromaThreshold)
    }
    if colourShare > PdfScanTuning.autoColourShare {
      logPdfEvent("scan_auto_preset", "resolved=magicColor colourShare=\(colourShare)")
      return .magicColor
    }

    var inkLevel: CGFloat = 0
    if let counts = histogram(of: lumaExtracted(small), extent: smallExtent),
       let level = percentile(
         counts,
         share: PdfScanTuning.autoInkPercentile,
         fromTop: false
       ) {
      inkLevel = level
    }
    let resolved: PdfScanPreset = inkLevel > PdfScanTuning.autoFaintInkLevel
      ? .blackAndWhite2
      : .grayMode
    logPdfEvent(
      "scan_auto_preset",
      "resolved=\(resolved.storageKey) colourShare=\(colourShare) inkLevel=\(inkLevel)"
    )
    return resolved
  }

  /// Per-pixel chroma as `max(r,g,b) - min(r,g,b)`. The difference blend is an
  /// absolute difference, which is the signed one here because the maximum
  /// component is never below the minimum.
  private func chromaExtracted(_ image: CIImage, extent: CGRect) -> CIImage? {
    let maximum = CIFilter.maximumComponent()
    maximum.inputImage = image
    let minimum = CIFilter.minimumComponent()
    minimum.inputImage = image
    guard let high = maximum.outputImage, let low = minimum.outputImage else { return nil }

    let difference = CIFilter.differenceBlendMode()
    difference.inputImage = high
    difference.backgroundImage = low
    return difference.outputImage?.cropped(to: extent)
  }

  // MARK: - Measurement

  /// Downscales to `measurementLongEdge`.
  private func measurementScaled(
    _ image: CIImage,
    extent: CGRect
  ) -> (image: CIImage, extent: CGRect) {
    let longEdge = max(extent.width, extent.height)
    let ratio = min(PdfScanTuning.measurementLongEdge / max(longEdge, 1), 1)
    let scaled = CGRect(
      x: 0,
      y: 0,
      width: max((extent.width * ratio).rounded(), 1),
      height: max((extent.height * ratio).rounded(), 1)
    )
    return (
      image.transformed(by: CGAffineTransform(scaleX: ratio, y: ratio)).cropped(to: scaled),
      scaled
    )
  }

  /// 256-bin histogram as bin counts. One GPU-to-CPU sync per call, which is
  /// why measurements go through a reduction rather than sampling pixels.
  private func histogram(of image: CIImage, extent: CGRect) -> [CGFloat]? {
    let filter = CIFilter.areaHistogram()
    filter.inputImage = image
    filter.extent = extent
    filter.count = 256
    filter.scale = 1
    guard let reduced = filter.outputImage else { return nil }

    var bins = [Float](repeating: 0, count: 256 * 4)
    context.render(
      reduced,
      toBitmap: &bins,
      rowBytes: 256 * 4 * MemoryLayout<Float>.size,
      bounds: CGRect(x: 0, y: 0, width: 256, height: 1),
      format: .RGBAf,
      colorSpace: nil
    )

    // Callers pass grayscale images, so the green channel carries all of it.
    let counts = stride(from: 1, to: bins.count, by: 4).map { CGFloat(bins[$0]) }
    return counts.reduce(0, +) > 0 ? counts : nil
  }

  /// The level with `share` of the distribution's mass beyond it, from either
  /// end.
  private func percentile(
    _ counts: [CGFloat],
    share: CGFloat,
    fromTop: Bool
  ) -> CGFloat? {
    let target = counts.reduce(0, +) * share
    var seen: CGFloat = 0
    for step in counts.indices {
      let index = fromTop ? counts.count - 1 - step : step
      seen += counts[index]
      guard seen >= target else { continue }
      return CGFloat(index) / CGFloat(counts.count - 1)
    }
    return nil
  }

  /// The share of the distribution's mass sitting above `level`.
  private func share(_ counts: [CGFloat], above level: CGFloat) -> CGFloat {
    let total = counts.reduce(0, +)
    guard total > 0 else { return 0 }
    let first = Int((level * CGFloat(counts.count - 1)).rounded(.up))
    guard first < counts.count else { return 0 }
    return counts[first...].reduce(0, +) / total
  }

  // MARK: - Stages

  /// Rec. 709 luma into all three channels. Doubles as the desaturation step
  /// for the grey and two-tone tails.
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

  /// Gray-world white balance. Cheaper and steadier than a white-patch
  /// estimate: the brightest pixel on a document photo is as often glare as it
  /// is paper, and keying off it makes the correction jump between two captures
  /// of the same page.
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
    let (small, smallExtent) = measurementScaled(image, extent: extent)

    let average = CIFilter.areaAverage()
    average.inputImage = small
    average.extent = smallExtent
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
    // A frame this dark carries no usable colour information.
    guard r > 0.02, g > 0.02, b > 0.02 else { return nil }

    let target = (r + g + b) / 3
    let range = PdfScanTuning.whiteBalanceGainRange
    return CIVector(
      x: min(max(target / r, range.lowerBound), range.upperBound),
      y: min(max(target / g, range.lowerBound), range.upperBound),
      z: min(max(target / b, range.lowerBound), range.upperBound)
    )
  }

  private func denoised(_ image: CIImage) -> CIImage {
    let denoise = CIFilter.noiseReduction()
    denoise.inputImage = image
    denoise.noiseLevel = PdfScanTuning.noiseLevel
    denoise.sharpness = PdfScanTuning.noiseSharpness
    return denoise.outputImage ?? image
  }

  /// Linear levels with hard clipping. A matrix and a clamp rather than a
  /// `CIToneCurve` deliberately: a spline asked to be flat and then steep
  /// overshoots between its knots, which shows up as a grey band just inside
  /// the white point — exactly where the eye looks for clean paper.
  ///
  /// This is also what removes a colour cast from paper: the cast lives at high
  /// luminance, so clipping sends it to neutral white per channel.
  private func levelled(
    _ image: CIImage,
    blackPoint: CGFloat,
    whitePoint: CGFloat
  ) -> CIImage {
    let scale = 1 / max(whitePoint - blackPoint, 0.01)
    let bias = -blackPoint * scale

    let matrix = CIFilter.colorMatrix()
    matrix.inputImage = image
    matrix.rVector = CIVector(x: scale, y: 0, z: 0, w: 0)
    matrix.gVector = CIVector(x: 0, y: scale, z: 0, w: 0)
    matrix.bVector = CIVector(x: 0, y: 0, z: scale, w: 0)
    matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
    matrix.biasVector = CIVector(x: bias, y: bias, z: bias, w: 0)
    guard let stretched = matrix.outputImage else { return image }

    let clamp = CIFilter.colorClamp()
    clamp.inputImage = stretched
    clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
    clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
    return clamp.outputImage ?? stretched
  }

  /// Bradley's adaptive threshold: divide by a local mean, then cut at a ratio,
  /// so each pixel is judged against its own neighbourhood. The cut is a steep
  /// curve rather than a step so anti-aliased glyph edges keep some weight.
  private func adaptiveThresholded(_ image: CIImage, extent: CGRect) -> CIImage {
    let blur = CIFilter.boxBlur()
    blur.inputImage = image.clampedToExtent()
    blur.radius = max(
      Float(max(extent.width, extent.height) * PdfScanTuning.adaptiveMeanFraction),
      1
    )
    guard let localMean = blur.outputImage?.cropped(to: extent) else { return image }

    // Floored for the same reason the flattening divisor is: a fully black
    // neighbourhood would divide into unbounded gain.
    let clamp = CIFilter.colorClamp()
    clamp.inputImage = localMean
    clamp.minComponents = CIVector(x: 0.05, y: 0.05, z: 0.05, w: 0)
    clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)

    let divide = CIFilter.divideBlendMode()
    divide.inputImage = clamp.outputImage ?? localMean
    divide.backgroundImage = image
    guard let ratio = divide.outputImage?.cropped(to: extent) else { return image }

    let threshold = PdfScanTuning.adaptiveThreshold
    let curve = CIFilter.toneCurve()
    curve.inputImage = ratio
    curve.point0 = CGPoint(x: 0, y: 0)
    curve.point1 = CGPoint(x: max(threshold - 0.06, 0.01), y: 0.02)
    curve.point2 = CGPoint(x: threshold, y: 0.5)
    curve.point3 = CGPoint(x: min(threshold + 0.06, 0.99), y: 0.98)
    curve.point4 = CGPoint(x: 1, y: 1)
    return curve.outputImage?.cropped(to: extent) ?? ratio
  }

  /// Unsharp mask sized to the page rather than to a pixel count, so an export
  /// and a downscaled preview get the same apparent crispness.
  private func sharpened(_ image: CIImage, extent: CGRect) -> CIImage {
    let sharpen = CIFilter.unsharpMask()
    sharpen.inputImage = image.clampedToExtent()
    sharpen.radius = Float(
      max(max(extent.width, extent.height) * PdfScanTuning.sharpenRadiusFraction, 0.5)
    )
    sharpen.intensity = PdfScanTuning.sharpenIntensity
    return sharpen.outputImage?.cropped(to: extent) ?? image
  }

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
    return renderer.image { _ in
      UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
    }.cgImage ?? image
  }
}
