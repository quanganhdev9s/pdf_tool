import CoreGraphics
import PDFKit

/// Reads what a page's own drawing operators say about the text on it.
///
/// PDFKit answers questions about text through `PDFSelection`, which is an
/// extraction: it reports the font it *resolved* rather than the one named, it
/// says nothing about colour, and it re-invents word breaks from geometry —
/// given a line set with wide tracking it answers "g i a n" for what was drawn
/// as "gian". Every one of those gaps had to be filled by guessing from pixels:
/// the ink colour from a histogram, the weight from how much ink a line lays
/// down, the tracking from how far a line runs past its own glyph advances.
///
/// The page itself does not have to be guessed at. A PDF's content stream is a
/// sequence of operators, and `CGPDFScanner` walks it: `Tf` names the font and
/// its size, `rg`/`g`/`k` set the colour the glyphs are filled with, `Tc` and
/// `Tz` are the tracking, `Tr` is the render mode — and mode 2 is how a
/// "bold" heading is made out of a regular face, by stroking it as well as
/// filling it. This reads those operators and reports them for one rectangle of
/// the page.
///
/// What it deliberately does not do is decode the *text*. That needs the font's
/// encoding and its `/ToUnicode` map, which is a different piece of work;
/// PDFKit's extraction stays in charge of what the words are. This only says
/// how they are drawn.
enum PdfContentStreamReader {
  /// How a run of text is drawn, in page coordinates.
  struct Attributes {
    /// `/BaseFont` of the font resource, e.g. `Helvetica-Bold`. Subset prefixes
    /// (`ABCDEF+`) are stripped.
    var fontName: String?
    /// Point size in page space: the `Tf` size scaled by the text matrix, so a
    /// document that sizes its type through the matrix reports honestly.
    var fontSize: CGFloat?
    /// Fill colour of the glyphs, when it comes from a colour space that can be
    /// read without resolving indirect objects.
    var fill: (red: CGFloat, green: CGFloat, blue: CGFloat)?
    /// `Tc`, converted to page points: what the page adds between characters on
    /// top of the font's own advances.
    var characterSpacing: CGFloat
    /// `Tz` as a fraction. 1 unless the page is condensing or expanding.
    var horizontalScale: CGFloat
    /// True when the render mode strokes the glyphs as well as filling them —
    /// `Tr 2` and `Tr 6`. A regular face drawn this way *is* the document's
    /// bold, and no font name will say so.
    var stroked: Bool
    /// `/Flags` bit 19 of the font descriptor, which a font sets to say it
    /// should be drawn bold even where its name does not.
    var forceBold: Bool
  }

  /// A run of text, and where the page starts drawing it.
  struct Run {
    var origin: CGPoint
    var attributes: Attributes
  }

  /// Every visible run on the page, in the order the page draws them.
  ///
  /// The whole page at once, because a scan costs the same whether one line is
  /// wanted or all of them, and a tap should not pay for it twice. Invisible
  /// runs are left out — a scanned page carries its OCR text in render mode 3,
  /// under the image, and its colour and size describe nothing anyone can see.
  static func runs(on page: PDFPage) -> [Run] {
    guard let pageRef = page.pageRef, let state = scan(pageRef) else { return [] }

    // The font dictionary is looked up once per resource name rather than once
    // per run: a page of body text is thousands of runs and a handful of fonts.
    var fonts: [String: (baseFont: String?, forceBold: Bool)] = [:]
    return state.hits.filter { $0.renderMode != 3 && $0.renderMode != 7 }.map { hit in
      let resource = hit.fontResource
      var font: (baseFont: String?, forceBold: Bool)?
      if let resource, let cached = fonts[resource] {
        font = cached
      } else {
        font = fontDictionary(named: resource, on: pageRef)
        if let resource, let font { fonts[resource] = font }
      }

      // Sanitised on the way out. Every number here was read from a file, and
      // a malformed one — a NaN, an infinity, a text matrix that divides by
      // zero — otherwise travels straight into a font size or a text attribute
      // and comes back as CoreGraphics complaining about invalid numeric
      // values for the rest of the session.
      return Run(
        origin: finite(hit.origin) ? hit.origin : .zero,
        attributes: Attributes(
          fontName: font?.baseFont,
          fontSize: hit.fontSize.isFinite && hit.fontSize > 0.01 ? hit.fontSize : nil,
          fill: hit.fill.flatMap { components in
            components.red.isFinite && components.green.isFinite && components.blue.isFinite
              ? components
              : nil
          },
          characterSpacing: hit.characterSpacing.isFinite
            ? min(max(hit.characterSpacing, -64), 64)
            : 0,
          horizontalScale: hit.horizontalScale.isFinite && hit.horizontalScale > 0.01
            ? min(hit.horizontalScale, 10)
            : 1,
          stroked: hit.stroked,
          forceBold: font?.forceBold ?? false
        )
      )
    }
  }

  /// The attributes of the first run drawn inside `rect`.
  ///
  /// First rather than a blend: a line is one run of one style often enough,
  /// and where it is not, its opening is a better answer than an average.
  static func attributes(in rect: CGRect, among runs: [Run]) -> Attributes? {
    // Grown a little: the baseline of a line sits inside its box, but a run
    // that starts a hair left of the reported edge is still that line's.
    let target = rect.insetBy(dx: -2, dy: -1)
    return runs.first { target.contains($0.origin) }?.attributes
  }

  // MARK: - Addressing operators for deletion

  /// One text-showing operator, numbered the way `QPdfTextEraser` numbers them.
  struct ShowTextOp {
    /// Position among all text-showing operators on the page, from zero, in
    /// the order the page draws them. This is the address qpdf deletes by.
    var index: Int
    /// Which stretch between two moves of the text line matrix this belongs
    /// to. Operators sharing a segment are positioned relative to each other.
    var segment: Int
    /// Where the operator starts drawing, in page space.
    var origin: CGPoint
    /// False for the render modes that draw nothing — a scan's OCR layer.
    var isVisible: Bool
  }

  /// Every text-showing operator on the page, invisible ones included.
  static func showTextOps(on page: PDFPage) -> [ShowTextOp] {
    guard let pageRef = page.pageRef, let state = scan(pageRef) else { return [] }
    return state.hits.map { hit in
      ShowTextOp(
        index: hit.opIndex,
        segment: hit.segment,
        origin: finite(hit.origin) ? hit.origin : .zero,
        isVisible: hit.renderMode != 3 && hit.renderMode != 7
      )
    }
  }

  /// The operators to delete so that nothing is drawn inside `rect` any more,
  /// or nil when deleting them would move text that stays.
  ///
  /// Deleting a text-showing operator costs the page the advance that operator
  /// made to the text matrix. Anything that draws after it *in the same
  /// segment* was positioned by that advance and would slide backwards; once
  /// the line matrix moves again the debt is cleared, because every positioning
  /// operator computes from the line matrix, which showing text never touches.
  ///
  /// So a plan is safe exactly when, in every segment it touches, the operators
  /// being deleted run to the end of that segment. A paragraph selected whole —
  /// which is the only unit `PdfTextEditManager` offers — normally satisfies
  /// that, because the line below it begins with a `Td` or a `T*`. When it does
  /// not, this returns nil rather than a plan that would visibly shift the page,
  /// and the caller is expected to fall back to covering rather than deleting.
  ///
  /// Nil also comes back when nothing was found, so the caller cannot tell an
  /// empty selection from an unsafe one — neither is a deletion, and the
  /// fallback is the same.
  static func deletionPlan(for rect: CGRect, on page: PDFPage) -> [Int]? {
    let ops = showTextOps(on: page)
    guard !ops.isEmpty else { return nil }

    // Grown the same way `attributes(in:among:)` grows it: a run that starts a
    // hair outside the reported edge is still the line's.
    let target = rect.insetBy(dx: -2, dy: -1)
    let doomed = Set(ops.filter { target.contains($0.origin) }.map(\.index))
    guard !doomed.isEmpty else { return nil }

    var segments: [Int: [ShowTextOp]] = [:]
    for op in ops { segments[op.segment, default: []].append(op) }

    for group in segments.values {
      let ordered = group.sorted { $0.index < $1.index }
      guard let first = ordered.firstIndex(where: { doomed.contains($0.index) }) else { continue }
      // From the first doomed operator onwards, the rest of the segment has to
      // go too, or what survives it moves.
      if ordered[first...].contains(where: { !doomed.contains($0.index) }) { return nil }
    }

    return doomed.sorted()
  }

  // MARK: - Running the scanner

  private static func scan(_ pageRef: CGPDFPage) -> ScannerState? {
    let state = ScannerState()
    guard let table = CGPDFOperatorTableCreate() else { return nil }
    defer { CGPDFOperatorTableRelease(table) }
    register(into: table)

    let stream = CGPDFContentStreamCreateWithPage(pageRef)
    defer { CGPDFContentStreamRelease(stream) }

    let info = Unmanaged.passUnretained(state).toOpaque()
    let scanner = CGPDFScannerCreate(stream, table, info)
    defer { CGPDFScannerRelease(scanner) }
    CGPDFScannerScan(scanner)
    return state
  }
}

// MARK: - The state the operators move

/// Everything the scanner has to remember while it walks the stream.
///
/// A content stream is a machine with a stack: `q` and `Q` save and restore the
/// whole graphics state, `cm` multiplies into the transform, `BT` resets the
/// text matrices. Nothing can be understood one operator at a time, which is
/// why this is a class the C callbacks share rather than a pile of statics.
private final class ScannerState {
  struct Hit {
    var origin: CGPoint
    var fontResource: String?
    var fontSize: CGFloat
    var fill: (red: CGFloat, green: CGFloat, blue: CGFloat)?
    var characterSpacing: CGFloat
    var horizontalScale: CGFloat
    var stroked: Bool
    /// Position among all text-showing operators on the page, from zero.
    var opIndex: Int
    /// Which run of operators between two moves of the text line matrix this
    /// one belongs to. See `ScannerState.segment`.
    var segment: Int
    var renderMode: Int
  }

  struct Graphics {
    var ctm: CGAffineTransform = .identity
    var fill: (red: CGFloat, green: CGFloat, blue: CGFloat)? = (0, 0, 0)
    var fontResource: String?
    var fontSize: CGFloat = 0
    var characterSpacing: CGFloat = 0
    var horizontalScale: CGFloat = 1
    var renderMode: Int = 0
    var leading: CGFloat = 0
    var rise: CGFloat = 0
  }

  var graphics = Graphics()
  var stack: [Graphics] = []
  var textMatrix: CGAffineTransform = .identity
  var lineMatrix: CGAffineTransform = .identity
  var hits: [Hit] = []

  /// How many text-showing operators have gone past, invisible ones included.
  ///
  /// Invisible ones count because qpdf counts them: the ordinals here are the
  /// address a deletion is expressed in, and an address only works if both ends
  /// of the wire agree on it. A scanned page's OCR layer is drawn in render
  /// mode 3, and skipping it here would silently shift every ordinal after it.
  var showIndex = 0

  /// Which stretch of operators between two moves of the text line matrix we
  /// are in.
  ///
  /// This is what makes a deletion decidable. Showing text advances the text
  /// matrix `Tm` but never the text *line* matrix `Tlm`, and `Td`, `TD`, `Tm`,
  /// `T*`, `'` and `"` all compute their new position from `Tlm`. So removing a
  /// text-showing operator can only disturb operators that draw after it
  /// *within the same segment* — once the line matrix moves again, the page has
  /// forgotten where the deleted words left off.
  var segment = 0

  /// Where the next glyph would be placed, in page space.
  var textOrigin: CGPoint {
    let matrix = textMatrix.concatenating(graphics.ctm)
    return CGPoint(x: matrix.tx, y: matrix.ty + graphics.rise * scale)
  }

  /// How much the text and page matrices between them scale a point size.
  var scale: CGFloat {
    let matrix = textMatrix.concatenating(graphics.ctm)
    let vertical = hypot(matrix.c, matrix.d)
    return vertical > 0.0001 ? vertical : 1
  }

  /// Called for every text-showing operator.
  ///
  /// Every one of them, including the modes that draw nothing — filtering is
  /// left to the caller now that the ordinal has to survive it. Modes 3 and 7
  /// are how a scan's OCR layer is written, under the image everybody actually
  /// reads; `runs(on:)` still drops them, because their colour and size
  /// describe nothing anyone can see.
  func showText() {
    hits.append(Hit(
      origin: textOrigin,
      fontResource: graphics.fontResource,
      fontSize: graphics.fontSize * scale,
      fill: graphics.fill,
      characterSpacing: graphics.characterSpacing * graphics.horizontalScale * scale,
      horizontalScale: graphics.horizontalScale,
      stroked: graphics.renderMode == 2 || graphics.renderMode == 6,
      opIndex: showIndex,
      segment: segment,
      renderMode: graphics.renderMode
    ))
    showIndex += 1
  }

  func setLineMatrix(_ matrix: CGAffineTransform) {
    lineMatrix = matrix
    textMatrix = matrix
    segment += 1
  }

  func nextLine(by offset: CGPoint) {
    setLineMatrix(CGAffineTransform(translationX: offset.x, y: offset.y).concatenating(lineMatrix))
  }
}

// MARK: - Operator callbacks

private func finite(_ point: CGPoint) -> Bool {
  point.x.isFinite && point.y.isFinite
}

/// Operands come off the scanner's stack last one first, so a pop of `count`
/// numbers has to be turned back around before it means anything.
private func numbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat] {
  var values: [CGFloat] = []
  for _ in 0..<count {
    var value: CGPDFReal = 0
    guard CGPDFScannerPopNumber(scanner, &value) else { break }
    values.append(CGFloat(value))
  }
  return values.reversed()
}

/// Every operand still on the stack, for the colour operators whose arity
/// depends on a colour space set earlier.
private func allNumbers(_ scanner: CGPDFScannerRef) -> [CGFloat] {
  var values: [CGFloat] = []
  while true {
    var value: CGPDFReal = 0
    guard CGPDFScannerPopNumber(scanner, &value) else { break }
    values.append(CGFloat(value))
  }
  return values.reversed()
}

private func state(_ info: UnsafeMutableRawPointer?) -> ScannerState? {
  info.map { Unmanaged<ScannerState>.fromOpaque($0).takeUnretainedValue() }
}

/// Components to RGB, by count: one is grey, three are already RGB, four are
/// CMYK. Anything else came from a colour space this reader does not resolve —
/// Separation, Indexed, a pattern — and is left unanswered rather than guessed.
private func rgb(from components: [CGFloat]) -> (red: CGFloat, green: CGFloat, blue: CGFloat)? {
  switch components.count {
  case 1:
    return (components[0], components[0], components[0])
  case 3:
    return (components[0], components[1], components[2])
  case 4:
    let k = components[3]
    return (
      (1 - components[0]) * (1 - k),
      (1 - components[1]) * (1 - k),
      (1 - components[2]) * (1 - k)
    )
  default:
    return nil
  }
}

private func register(into table: CGPDFOperatorTableRef) {
  // Graphics state
  CGPDFOperatorTableSetCallback(table, "q") { _, info in
    guard let state = state(info) else { return }
    state.stack.append(state.graphics)
  }
  CGPDFOperatorTableSetCallback(table, "Q") { _, info in
    guard let state = state(info), let restored = state.stack.popLast() else { return }
    state.graphics = restored
  }
  CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
    guard let state = state(info) else { return }
    let values = numbers(scanner, 6)
    guard values.count == 6 else { return }
    let matrix = CGAffineTransform(
      a: values[0], b: values[1], c: values[2],
      d: values[3], tx: values[4], ty: values[5]
    )
    state.graphics.ctm = matrix.concatenating(state.graphics.ctm)
  }

  // Fill colour
  CGPDFOperatorTableSetCallback(table, "g") { scanner, info in
    guard let state = state(info) else { return }
    state.graphics.fill = rgb(from: numbers(scanner, 1))
  }
  CGPDFOperatorTableSetCallback(table, "rg") { scanner, info in
    guard let state = state(info) else { return }
    state.graphics.fill = rgb(from: numbers(scanner, 3))
  }
  CGPDFOperatorTableSetCallback(table, "k") { scanner, info in
    guard let state = state(info) else { return }
    state.graphics.fill = rgb(from: numbers(scanner, 4))
  }
  CGPDFOperatorTableSetCallback(table, "sc") { scanner, info in
    guard let state = state(info) else { return }
    state.graphics.fill = rgb(from: allNumbers(scanner))
  }
  CGPDFOperatorTableSetCallback(table, "scn") { scanner, info in
    guard let state = state(info) else { return }
    // A pattern fill leaves a name on the stack and no components; the colour
    // of a pattern is not a colour.
    state.graphics.fill = rgb(from: allNumbers(scanner))
  }

  // Text state
  CGPDFOperatorTableSetCallback(table, "Tf") { scanner, info in
    guard let state = state(info) else { return }
    var size: CGPDFReal = 0
    CGPDFScannerPopNumber(scanner, &size)
    var name: UnsafePointer<Int8>?
    CGPDFScannerPopName(scanner, &name)
    state.graphics.fontSize = CGFloat(size)
    state.graphics.fontResource = name.map { String(cString: $0) }
  }
  CGPDFOperatorTableSetCallback(table, "Tc") { scanner, info in
    guard let state = state(info) else { return }
    state.graphics.characterSpacing = numbers(scanner, 1).first ?? 0
  }
  CGPDFOperatorTableSetCallback(table, "Tz") { scanner, info in
    guard let state = state(info) else { return }
    state.graphics.horizontalScale = (numbers(scanner, 1).first ?? 100) / 100
  }
  CGPDFOperatorTableSetCallback(table, "Tr") { scanner, info in
    guard let state = state(info) else { return }
    state.graphics.renderMode = Int(numbers(scanner, 1).first ?? 0)
  }
  CGPDFOperatorTableSetCallback(table, "Ts") { scanner, info in
    guard let state = state(info) else { return }
    state.graphics.rise = numbers(scanner, 1).first ?? 0
  }
  CGPDFOperatorTableSetCallback(table, "TL") { scanner, info in
    guard let state = state(info) else { return }
    state.graphics.leading = numbers(scanner, 1).first ?? 0
  }

  // Text positioning
  CGPDFOperatorTableSetCallback(table, "BT") { _, info in
    guard let state = state(info) else { return }
    state.setLineMatrix(.identity)
  }
  CGPDFOperatorTableSetCallback(table, "Tm") { scanner, info in
    guard let state = state(info) else { return }
    let values = numbers(scanner, 6)
    guard values.count == 6 else { return }
    state.setLineMatrix(CGAffineTransform(
      a: values[0], b: values[1], c: values[2],
      d: values[3], tx: values[4], ty: values[5]
    ))
  }
  CGPDFOperatorTableSetCallback(table, "Td") { scanner, info in
    guard let state = state(info) else { return }
    let values = numbers(scanner, 2)
    guard values.count == 2 else { return }
    state.nextLine(by: CGPoint(x: values[0], y: values[1]))
  }
  CGPDFOperatorTableSetCallback(table, "TD") { scanner, info in
    guard let state = state(info) else { return }
    let values = numbers(scanner, 2)
    guard values.count == 2 else { return }
    state.graphics.leading = -values[1]
    state.nextLine(by: CGPoint(x: values[0], y: values[1]))
  }
  CGPDFOperatorTableSetCallback(table, "T*") { _, info in
    guard let state = state(info) else { return }
    state.nextLine(by: CGPoint(x: 0, y: -state.graphics.leading))
  }

  // Showing text
  CGPDFOperatorTableSetCallback(table, "Tj") { _, info in
    state(info)?.showText()
  }
  CGPDFOperatorTableSetCallback(table, "TJ") { _, info in
    state(info)?.showText()
  }
  CGPDFOperatorTableSetCallback(table, "'") { _, info in
    guard let state = state(info) else { return }
    state.nextLine(by: CGPoint(x: 0, y: -state.graphics.leading))
    state.showText()
  }
  CGPDFOperatorTableSetCallback(table, "\"") { scanner, info in
    guard let state = state(info) else { return }
    _ = numbers(scanner, 2)
    state.nextLine(by: CGPoint(x: 0, y: -state.graphics.leading))
    state.showText()
  }
}

// MARK: - The font behind the resource name

/// `/BaseFont` and the descriptor flag that matter, looked up in the page's
/// resources.
///
/// `Tf` names a resource, not a font: `/F3` means whatever `/Resources /Font
/// /F3` points at. That dictionary is where the real name lives, and where a
/// font can declare itself bold through `/FontDescriptor /Flags` even when its
/// name does not say so.
private func fontDictionary(
  named resource: String?,
  on page: CGPDFPage
) -> (baseFont: String?, forceBold: Bool)? {
  guard let resource,
        let pageDictionary = page.dictionary,
        let fonts = resources(in: pageDictionary, key: "Font") else { return nil }

  var font: CGPDFDictionaryRef?
  guard CGPDFDictionaryGetDictionary(fonts, resource, &font), let font else { return nil }

  var baseFont: UnsafePointer<Int8>?
  var name: String?
  if CGPDFDictionaryGetName(font, "BaseFont", &baseFont), let baseFont {
    // Subset fonts are named `ABCDEF+Helvetica`; the prefix identifies the
    // subset, not the typeface.
    let full = String(cString: baseFont)
    name = full.count > 7 && full[full.index(full.startIndex, offsetBy: 6)] == "+"
      ? String(full.dropFirst(7))
      : full
  }

  var descriptor: CGPDFDictionaryRef?
  var flags: CGPDFInteger = 0
  if CGPDFDictionaryGetDictionary(font, "FontDescriptor", &descriptor), let descriptor {
    CGPDFDictionaryGetInteger(descriptor, "Flags", &flags)
  }
  // Bit 19 of the flags, counting from one, is ForceBold.
  let forceBold = flags & (1 << 18) != 0

  return (name, forceBold)
}

/// `/Resources` is inheritable: a page that does not carry its own uses its
/// parent's, and a document that sets the resources once on the page tree is
/// perfectly ordinary.
private func resources(in dictionary: CGPDFDictionaryRef, key: String) -> CGPDFDictionaryRef? {
  var node: CGPDFDictionaryRef? = dictionary
  var depth = 0
  while let current = node, depth < 8 {
    var resources: CGPDFDictionaryRef?
    if CGPDFDictionaryGetDictionary(current, "Resources", &resources), let resources {
      var found: CGPDFDictionaryRef?
      if CGPDFDictionaryGetDictionary(resources, key, &found), let found {
        return found
      }
    }
    var parent: CGPDFDictionaryRef?
    node = CGPDFDictionaryGetDictionary(current, "Parent", &parent) ? parent : nil
    depth += 1
  }
  return nil
}
