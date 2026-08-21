import PDFKit
import UIKit

/// Chọn và thay thế các đoạn chữ trên trang.
///
/// PDFKit đọc được chữ và biết nó nằm đâu, nhưng không sửa được content stream.
/// Nên một lần sửa ở đây là: giữ `CommittedEdit` trong bộ nhớ, vẽ đè lên trang
/// để xem trước, rồi lúc `save()` mới ghi thật — qpdf xoá operator cũ,
/// CoreGraphics vẽ chữ mới thành nội dung trang. Không dùng annotation.
///
/// Style được **đo**, không đoán: font từ attributed string của selection, màu
/// mực và màu giấy từ pixel render thật của chính đoạn chữ đó.
///
/// Đơn vị là **đoạn văn**, không phải dòng — ngắt dòng là tai nạn typesetting,
/// câu người ta muốn sửa thường trải qua nhiều dòng. Dòng được gộp lại thành
/// chữ liền để sửa xong tự xuống dòng lại trong khung.

final class PdfTextEditManager: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
  var onSelection: ((PdfTextBlock?) -> Void)?

  /// Nhờ workspace làm chữ gốc vô hình ngay, trước khi ô nhập mở ra.
  ///
  /// Trả về trang **thay thế** — tài liệu bị ghi lại và mở lại nên đối tượng
  /// trang cũ thành rác. Trả nil nghĩa là không giấu được, và mọi thứ chạy như
  /// cũ: miếng vá làm nhiệm vụ che.
  var onHideOriginal: ((Int, CGRect) -> PDFPage?)?

  /// Nhờ workspace trả tài liệu về trạng thái trước khi giấu, khi bấm Huỷ.
  var onRestoreOriginal: (() -> Void)?

  /// Nhờ workspace ghi chỉnh sửa vào trang. Manager giữ cử chỉ, ô nhập và
  /// style; chỉ việc đụng vào document là ở ngoài.
  var onCommit: ((PdfTextEditCommit) -> Void)?

  /// Một lần commit: chữ thay thế, style, và hai hình chữ nhật.
  ///
  /// Hai, vì chúng trả lời hai câu khác nhau. `cover` là chỗ chữ gốc nằm và
  /// không bao giờ dịch. `request.bounds` là chỗ chữ mới được bố cục, do nút
  /// kéo chỉnh — cho chữ mới nhiều chỗ hơn không được nới rộng cái lỗ trên trang.
  struct PdfTextEditCommit {
    var request: PdfTextEditRequest
    var cover: CGRect
    /// Tracking của trang. Mang theo vì `dismissEditor` đã xoá nó trước khi
    /// commit được chuyển đi.
    var kern: CGFloat
  }

  /// Một chỉnh sửa đã commit, đang chờ ghi vào file.
  ///
  /// Trước đây là hai annotation PDFKit, và ba lỗi đắt nhất đều là của chúng:
  /// freeText với font standard-14 không mang nổi `ế ộ ư đ` vào file;
  /// `addAnnotation` đầu tiên của tiến trình tốn 4613ms trên máy thật; và PDFKit
  /// bố cục chữ theo luật khác ô nhập nên chữ nhảy ngay khi commit.
  struct CommittedEdit {
    /// Giữ chính trang, không giữ chỉ số — chỉ số chỉ đúng tới khi ai đó sắp
    /// xếp lại trang. Chỉ số chỉ được hỏi một lần, đúng lúc ghi file.
    var page: PDFPage
    /// Chỗ chữ gốc nằm. Cố định suốt lần sửa: nút kéo chỉnh chữ, không chỉnh lỗ.
    var cover: CGRect
    /// Hộp bố cục chữ mới, toạ độ trang.
    var bounds: CGRect
    var text: String
    var font: UIFont
    var ink: UIColor
    var kern: CGFloat

    /// Chiều cao tối đa chữ được chiếm, tính từ đỉnh `bounds` xuống. Bằng
    /// khoảng cách tới block kế tiếp phía dưới, đo lúc commit.
    var maxHeight: CGFloat

    /// Toàn bộ vùng trang mà chỉnh sửa này chiếm.
    var occupied: CGRect { cover.union(bounds) }
  }

  /// Fallback ratio from line height to point size, used only when the
  /// selection carries no font.
  ///
  /// A line box holds ascender, descender and leading, so the glyphs are
  /// meaningfully smaller than the box around them. The measured size is always
  /// preferred — this is the guess of last resort.
  static let fontSizeFromLineHeight: CGFloat = 0.72

  /// Pixel height the line is rendered at when sampling its colours.
  ///
  /// Sixty-four pixels of line height puts several fully-covered pixels inside
  /// each stroke, which is what makes an unblended sample exist at all.
  static let colourSampleLineHeight: CGFloat = 64
  static let colourSampleScaleRange: ClosedRange<CGFloat> = 4...16

  /// Share of a run's pixels taken as ink — the ones least like its paper.
  static let inkPixelShare = 0.005

  /// Colours the histogram distinguishes: five bits a channel.
  static let histogramBuckets = 32 * 32 * 32

  /// Most pixels a colour measurement will look at.
  ///
  /// A run rendered at sampling scale is a few hundred thousand pixels, and a
  /// colour taken from every tenth of them is the same colour. The cap is what
  /// keeps a tap on a wide line from stalling the frame it happens in.
  static let colourSampleBudget = 60_000

  /// Smallest number of pixels the ink slice may contain. Keeps a very short
  /// run — a couple of characters — from deciding its colour on one pixel.
  static let minimumInkSamples = 12

  /// How far above the line box a stacked diacritic may reach, as a share of
  /// the point size.
  ///
  /// PDFKit's line box is font metrics — ascender to descender — and Vietnamese
  /// stacks a tone mark on top of a circumflex, which on a capital clears the
  /// ascender entirely. A cover fitted to the reported box leaves the tips of
  /// those marks standing over it. Measured at a quarter of the point size on
  /// Helvetica; the cap is the ceiling on how far the search will trust ink
  /// above the line as belonging to it.
  static let diacriticHeadroom: CGFloat = 0.3

  /// A row of the headroom band this full is another line of text, not a mark
  /// on this one, and the search stops there. Marks are narrow and land over a
  /// few letters; a line of type inks a good part of the width.
  static let crowdedRowShare = 0.4

  /// How much heavier than the reported font the page's own ink has to be
  /// before the replacement is set bold. A bold face lays down roughly 40% more
  /// ink than its regular; the threshold sits well below that and well above
  /// the few percent that measurement noise and tracking account for.
  static let boldInkRatio = 1.18

  /// Bounds on the tracking read off a line, as a share of the point size.
  ///
  /// A line's width is its glyph advances plus whatever the page adds between
  /// them, and dividing the difference between the gaps models that well enough
  /// — as long as the string PDFKit hands back is the string that was drawn.
  ///
  /// Sometimes it is not, and the asymmetry here is why. Given a line set with
  /// wide tracking, PDFKit's extraction reads the gaps as word breaks and
  /// answers "g i a n" for what was drawn as "gian": a longer string than the
  /// page holds, whose natural width overshoots the run, whose difference comes
  /// out negative. Squeezing the field's text on the strength of that is the
  /// one outcome worse than leaving it alone, so the negative side is held to a
  /// hair — enough for genuinely condensed type, not enough to crush a
  /// misread line. The positive side, which is the case this exists for, stays
  /// generous.
  static let kernRange: ClosedRange<CGFloat> = -0.03...0.4

  /// Bề rộng dải mép trái/phải dùng để lấy màu nền, tính bằng điểm trang.
  /// Nằm ngoài glyph nên đọc được nền thật, đủ hẹp để không chạm block bên cạnh.
  static let paperMargin: CGFloat = 6

  /// Least difference in luma between ink and paper for the pair to be read as
  /// text on a background at all. Below it the sample probably caught an image
  /// or a solid fill, and inventing an ink colour from it would produce
  /// invisible text.
  static let minimumContrast: CGFloat = 0.12

  /// Grown around the reported bounds before covering, in points. Glyph
  /// antialiasing spills past the bounds PDFKit reports, and a cover that fits
  /// exactly leaves a grey ghost of the original line.
  static let coverPadding: CGFloat = 1.5

  /// Marks the two annotations an edit produces, written into `/NM`. Prefixes,
  /// not exact names: the key is meant to be unique per page, so each carries a
  /// UUID, and ours are recognised by what they start with.

  /// Size used when an edit's annotation reports no font of its own. Only
  /// reachable through a document where the annotation's `/DA` did not parse.
  static let fallbackFontSize: CGFloat = 12

  /// Padding PDFKit leaves inside a free-text annotation's bounds, in points.
  ///
  /// Measured: whatever height the bounds are given, PDFKit starts the ink two
  /// points below their top edge. Used twice — to leave the text room, and to
  /// lift the box by the same two points so the replacement lands on the
  /// baseline the original sat on.

  /// How much taller than the text measures the free-text box is made.
  ///
  /// PDFKit generates the annotation's appearance itself and lays the line out
  /// with its own metrics, which run taller than the measurement here — with a
  /// box fitted exactly to the text, a Vietnamese tone mark stacked on a
  /// circumflex is cut. Measured on Helvetica-Bold at 24pt: a box one line box
  /// tall renders 20 points of the 24.5 the line needs, and everything from
  /// 1.2x up renders all of it. A quarter over sits clear of that edge, and
  /// costs nothing visible — the box draws no background, and the cover is
  /// measured from the run rather than from here.

  /// How far below a line the next one may start and still be the same
  /// paragraph, as a share of the line's own height.
  ///
  /// Body copy is set with leading well under one line height, so a gap wider
  /// than this is a paragraph break, a table row or the start of a new block —
  /// not the continuation of the sentence that was tapped.
  static let paragraphLineGap: CGFloat = 0.85

  /// How much two lines' heights may differ and still be read as the same
  /// paragraph. Catches the heading sitting directly above body text.
  static let paragraphHeightRatio: ClosedRange<CGFloat> = 0.72...1.38

  /// Share of the narrower line that must sit horizontally within the wider one
  /// for the two to belong together. Keeps a neighbouring column out.
  static let paragraphOverlapShare: CGFloat = 0.4

  /// Khoảng trống ngang bao nhiêu thì cắt một dòng làm hai, theo chiều cao dòng.
  ///
  /// `selectionsByLine` trả về cả một hàng chữ là một dòng, kể cả khi hàng đó là
  /// `Tên:` rồi một khoảng trống rộng rồi `Nguyễn Văn A`. Hai thứ đó không liên
  /// quan gì nhau nhưng đến đây là một hình chữ nhật duy nhất, nên `continues()`
  /// không bao giờ được hỏi tới.
  ///
  /// Một dấu cách thường rộng khoảng 0.25 chiều cao dòng, nên ngưỡng này nằm
  /// cách xa mọi khoảng cách từ ngữ bình thường.
  static let paragraphColumnGap: CGFloat = 0.3

  /// Khe rộng gấp mấy lần khoảng cách từ của chính dòng đó thì coi là sang cột.
  ///
  /// Ngưỡng cố định theo chiều cao dòng không dùng được: chữ dàn đều kéo giãn
  /// dấu cách rất rộng, còn ô bảng thì có khi chỉ cách nhau vài điểm. Đo dấu
  /// cách thật của dòng rồi nhân lên thì cùng một luật chạy được cho cả hai.
  static let columnGapInSpaces: CGFloat = 2.5

  /// Hai dòng cùng đoạn thì gộp lại không rộng hơn dòng rộng nhất bao nhiêu.
  ///
  /// Kiểm tra chồng lấn phía trên tính theo dòng **hẹp hơn**, và phải như vậy:
  /// dòng cuối một đoạn thường ngắn hơn hẳn các dòng trên. Nhưng chính vì thế
  /// một từ ngắn nằm lệch hẳn sang bên cũng lọt — nó chỉ cần chồng 40% của
  /// chính nó, tức là vài điểm. Chỗ này chặn lại: hai dòng cùng đoạn nằm gần
  /// như trong cùng một cột, nên hợp của chúng phải xấp xỉ dòng rộng nhất.
  static let paragraphSpreadShare: CGFloat = 1.35

  /// Stands in for "as tall as it needs", in points.
  ///
  /// `CGFloat.greatestFiniteMagnitude` is the usual idiom and it is a way to
  /// get NaN back out of TextKit: multiply it by any layout factor and it
  /// overflows to infinity, and infinity minus infinity is what CoreGraphics
  /// then complains about. A number larger than any page and smaller than
  /// arithmetic trouble does the same job.
  static let unboundedHeight: CGFloat = 100_000

  /// How long the page has to stay quiet before its blocks are read, in
  /// seconds. Long enough that a scroll, a keystroke or a commit is over by the
  /// time it fires.
  static let blockReadDelay: TimeInterval = 0.4

  /// Ngưỡng cảnh báo cho một lần gõ phím, tính bằng giây. Nửa frame ở 60Hz —
  /// quá đó là ô nhập không theo kịp bàn phím.
  static let keystrokeBudget: TimeInterval = 0.008

  /// Ceiling on how many lines are gathered around the tapped one. A runaway
  /// walk over a densely set page is the only failure mode worth bounding.
  static let paragraphLineLimit = 40

  /// Side of the grip dragged to resize the block, in points. Sized for a
  /// fingertip, not for the hairline it sits on.
  ///
  /// Vùng chạm, không phải chấm nhìn thấy. Hai thứ tách nhau vì chúng phục vụ
  /// hai bên khác nhau: ngón tay cần chỗ, còn mắt cần thấy chữ dưới nút.
  static let resizeHandleSize: CGFloat = 26

  /// Đường kính chấm tròn vẽ ở mỗi góc, in points.
  static let resizeHandleDotSize: CGFloat = 13

  /// Clearance kept between a resized block and the next one, in points.
  static let blockGutter: CGFloat = 2

  /// Floor on a resized block, in points. Below this the field is too small to
  /// aim at, and a drag past a neighbour would otherwise collapse it to nothing.
  /// Sàn tuyệt đối cho kích thước block, tính bằng điểm. Bề rộng thật sự cho
  /// phép được tính theo cỡ chữ trong `minimumWidth` — 24 điểm ở chữ 11pt là
  /// hai ký tự, ở chữ 40pt thì chưa đủ một.
  static let minimumBlockSize = CGSize(width: 24, height: 10)

  /// Bề rộng tối thiểu tính theo cỡ chữ. Hẹp hơn thì ô nhập xuống dòng sau mỗi
  /// chữ và không còn dùng được.
  static let minimumWidthInEms: CGFloat = 4

  private weak var pdfView: PDFView?
  private let highlightLayer = CAShapeLayer()

  /// The outlines drawn over every editable block while the mode is on.
  private let blockLayer = CAShapeLayer()
  private var blockCache: [Int: [TextBlock]] = [:]

  /// Operator vẽ chữ của trang, quét một lần. Sửa chữ không làm cũ nó.
  private var runCache: [Int: [PdfContentStreamReader.Run]] = [:]
  /// Counts requests to read a page's blocks, so only the newest survives a
  /// burst of them.
  private var readRequest = 0

  /// Lần yêu cầu tắt bàn phím gần nhất. Mở ô nhập lại sẽ tăng số này và lần
  /// tắt đang chờ tự bỏ đi.
  private var keyboardDismissRequest = 0

  /// Các chỉnh sửa đã commit, chưa ghi vào file. `invalidateBlocks()` dọn sạch
  /// sau khi save đã tiêu thụ chúng.
  private(set) var committedEdits: [CommittedEdit] = []

  /// Vẽ các chỉnh sửa đó đè lên trang trong lúc chờ.
  private let editPreview = EditPreviewView()

  /// Viền quanh block đang sửa. Xem `configureEditor`.
  private let fieldBorder = CAShapeLayer()
  private var viewportObservations: [NSKeyValueObservation] = []
  private var viewportNotifications: [NSObjectProtocol] = []
  private var isEnabled = false

  /// The tapped line, turned into the field the user types in.
  ///
  /// Sat over the line at its own size, in its own font and colours, on its own
  /// paper colour — so the page appears to become editable rather than sprout a
  /// form somewhere else. A separate input box elsewhere on screen makes the
  /// user hold two places in their head: the line they meant and the box that
  /// stands for it.
  private let editor = UITextView()
  private var editingStyle: PdfTextEditRequest?
  private weak var editingPage: PDFPage?

  /// The block being edited, in page coordinates, as the handle has left it.
  private var editingBounds: CGRect?
  /// The run this edit covers. Fixed for the life of the edit: the handle
  /// resizes the words, never the hole.
  private var editingCover: CGRect?
  /// Where that block started, used to tell the block being edited apart from
  /// the neighbours a resize has to keep clear of.
  private var editingOriginalBounds: CGRect?
  private var resizeStartBounds: CGRect?

  /// Tracking the page sets its glyphs with, in page points per gap between
  /// characters. Zero for a block this manager wrote, whose text was never set
  /// by anyone but the field.
  private var editingKern: CGFloat = 0
  /// What the field's text is currently styled with, so the attributes are
  /// rebuilt on a zoom change and not on every frame of a scroll.
  private var editingTypography: (name: String?, size: CGFloat, kern: CGFloat)?

  /// Trần cho chiều cao ô nhập, toạ độ trang. Tính lúc mở ô nhập và mỗi lần
  /// kéo nút — không tính khi gõ, vì hỏi nó là đọc lại block cả trang.
  private var editingFloor: CGFloat?

  /// Chữ gốc của lần sửa này đã bị giấu trong tài liệu chưa. Quyết định có dựng
  /// miếng vá không, và có phải lùi lại khi bấm Huỷ không.
  private var editingHidOriginal = false

  /// Nhớ câu trả lời gần nhất của `sizeThatFits` kèm dữ kiện đã hỏi. Ô nhập
  /// được bố cục lại mỗi lần cuộn/zoom/gõ, mà chỉ gõ mới đổi chiều cao.
  private var editingFit: (text: String, width: CGFloat, top: CGFloat, height: CGFloat)?

  /// Grip on the block's bottom-right corner, dragged to give the replacement
  /// more room than the text it replaces had.
  /// Một góc của block. Hai cạnh gặp nhau ở đó là hai cạnh sẽ dịch khi kéo,
  /// hai cạnh còn lại là neo. "Top" là `maxY` của trang (PDF hướng lên).
  private enum Corner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    var movesLeftEdge: Bool { self == .topLeft || self == .bottomLeft }
    var movesTopEdge: Bool { self == .topLeft || self == .topRight }
  }

  private let resizeHandles: [Corner: UIView] = Dictionary(
    uniqueKeysWithValues: Corner.allCases.map { ($0, UIView()) }
  )

  /// Paper-coloured patch over the run being replaced, under the field.
  ///
  /// The field itself is transparent. Painting the paper colour on the field
  /// meant the patch grew with it: drag the handle out and a slab of the
  /// heading's red spread across the page, over ground the edit was never going
  /// to cover. The two rectangles are different things — the run that has to be
  /// hidden, and the room the new words are given — and only the first is
  /// painted.

  private lazy var tapGesture: UITapGestureRecognizer = {
    let gesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
    gesture.delegate = self
    gesture.isEnabled = false
    return gesture
  }()

  init(pdfView: PDFView) {
    self.pdfView = pdfView
    super.init()

    // Faint, and dashed: these sit over readable text the whole time the mode
    // is on, so they have to say "this is a block you can tap" without becoming
    // the thing the eye reads instead of the words.
    blockLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.06).cgColor
    blockLayer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.55).cgColor
    blockLayer.lineWidth = 1
    blockLayer.lineDashPattern = [3, 2]
    pdfView.layer.addSublayer(blockLayer)

    highlightLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.22).cgColor
    highlightLayer.strokeColor = UIColor.systemBlue.cgColor
    highlightLayer.lineWidth = 1
    pdfView.layer.addSublayer(highlightLayer)
    pdfView.layer.addSublayer(fieldBorder)
    pdfView.addGestureRecognizer(tapGesture)
    configureEditor()
    configureResizeHandle()
  }

  deinit {
    stopTrackingViewport()
  }

  private func configureEditor() {
    editor.isHidden = true
    editor.isScrollEnabled = false
    editor.textContainerInset = .zero
    editor.textContainer.lineFragmentPadding = 0
    editor.autocorrectionType = .no
    editor.autocapitalizationType = .none
    editor.spellCheckingType = .no
    // Không viền trên chính ô nhập: frame của nó vươn lên trên block một khoảng
    // headroom cho dấu thanh và thò xuống theo độ dài chữ. `fieldBorder` vẽ thay.
    fieldBorder.fillColor = nil
    fieldBorder.strokeColor = UIColor.systemBlue.cgColor
    fieldBorder.lineWidth = 1
    fieldBorder.isHidden = true
    editor.delegate = self

    // Phải có chiều rộng thật ngay từ đầu: dựng với width 0 thì UIKit trả về
    // không gian âm, và âm là chỗ NaN sinh ra.
    let toolbar = UIToolbar(
      frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 44)
    )
    toolbar.autoresizingMask = .flexibleWidth
    toolbar.items = [
      UIBarButtonItem(
        title: "Huỷ",
        style: .plain,
        target: self,
        action: #selector(cancelEditing)
      ),
      UIBarButtonItem(
        image: UIImage(systemName: "trash"),
        style: .plain,
        target: self,
        action: #selector(deleteEditing)
      ),
      UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
      UIBarButtonItem(
        title: "Xong",
        style: .done,
        target: self,
        action: #selector(commitEditing)
      ),
    ]
    toolbar.sizeToFit()
    editor.inputAccessoryView = toolbar
  }

  private func configureResizeHandle() {
    let grip = CGRect(
      origin: .zero,
      size: CGSize(width: Self.resizeHandleSize, height: Self.resizeHandleSize)
    )
    let dotSize = Self.resizeHandleDotSize
    let inset = (Self.resizeHandleSize - dotSize) / 2

    for handle in resizeHandles.values {
      handle.isHidden = true
      // Bản thân nút không vẽ gì — nó chỉ là chỗ bắt ngón tay. Chấm nhìn thấy
      // là view con ở giữa, nên thu nhỏ chấm không thu nhỏ vùng chạm.
      handle.backgroundColor = .clear
      handle.frame = grip

      let dot = UIView(
        frame: CGRect(x: inset, y: inset, width: dotSize, height: dotSize)
      )
      dot.backgroundColor = .systemBlue
      dot.layer.cornerRadius = dotSize / 2
      dot.layer.borderWidth = 1.5
      dot.layer.borderColor = UIColor.white.cgColor
      // Chạm rơi xuống nút cha, không dừng ở chấm.
      dot.isUserInteractionEnabled = false
      // Giữ chấm ở giữa nếu vùng chạm đổi cỡ.
      dot.autoresizingMask = [
        .flexibleTopMargin, .flexibleBottomMargin,
        .flexibleLeftMargin, .flexibleRightMargin,
      ]
      handle.addSubview(dot)

      // One recogniser each. Which corner is being dragged is read back off
      // `gesture.view`, so the four share a single handler.
      handle.addGestureRecognizer(
        UIPanGestureRecognizer(target: self, action: #selector(handleResize(_:)))
      )
    }
  }

  func setEnabled(_ enabled: Bool) {
    isEnabled = enabled
    tapGesture.isEnabled = enabled
    if enabled {
      startTrackingViewport()
      // After the current layout pass: the mode is usually turned on while the
      // view is still settling, and rects converted before that land wrong.
      DispatchQueue.main.async { [weak self] in
        self?.refreshBlockOutlines()
      }
    } else {
      stopTrackingViewport()
      dismissEditor()
      clearHighlight()
      blockLayer.path = nil
      }
    logPdfEvent("set_text_edit_mode", "enabled=\(enabled)")
  }

  func clearHighlight() {
    highlightLayer.path = nil
  }

  /// Drops everything read off the old document. Called when the document
  /// behind the view is replaced, at which point a cached page index names a
  /// page that is no longer there.
  func reset() {
    dismissEditor()
    clearHighlight()
    blockCache.removeAll()
    runCache.removeAll()
    committedEdits.removeAll()
    blockLayer.path = nil
  }

  /// Drops the blocks read off the pages. For when the document object is
  /// replaced by an equivalent one — a save and reopen — where the cached
  /// selections point at pages that are no longer in it.
  /// Trỏ các chỉnh sửa đang chờ sang trang của tài liệu mới.
  ///
  /// `CommittedEdit` giữ chính đối tượng trang, mà mở lại tài liệu làm mọi đối
  /// tượng cũ thành rác. Chỉ số trang thì không đổi — cùng file, cùng thứ tự —
  /// nên nó là cầu nối duy nhất còn dùng được.
  ///
  /// `changedPage` là trang mà nội dung thật sự đổi. Chỉ nó bị xoá khỏi cache.
  ///
  /// Cách cũ xoá sạch cả hai cache ở đây, và đó là lý do cú chạm thứ hai đắt y
  /// như cú đầu: mỗi lần giấu chữ là một lần đọc lại mọi trang đã đọc. Nhưng
  /// giấu chỉ đụng vào **một** trang, và cache đánh khoá bằng chỉ số trang chứ
  /// không phải bằng đối tượng trang.
  ///
  /// `PDFSelection` trong `blockCache` thì vẫn trỏ vào trang của tài liệu cũ —
  /// và vẫn dùng được, vì từ lúc được cache trở đi chúng chỉ còn bị hỏi chữ và
  /// font (`select` đọc `.string` và `.attributedString`). Hình học đã được
  /// chốt thành `CGRect` ngay lúc đọc, nên không có toạ độ nào phải quy chiếu
  /// về tài liệu mới. Cái giá là trang cũ sống thêm chừng nào cache còn giữ —
  /// bị chặn trên bởi số trang đã đọc, và `reset()` buông hết.
  func remapPages(to document: PDFDocument, from previous: PDFDocument, changedPage: Int?) {
    committedEdits = committedEdits.compactMap { edit in
      let index = previous.index(for: edit.page)
      guard index != NSNotFound, let page = document.page(at: index) else { return nil }
      var moved = edit
      moved.page = page
      return moved
    }
    guard let changedPage else { return }
    // Chỉ `runCache`. `runs()` lọc bỏ render mode 3, nên giấu chữ đổi hẳn kết
    // quả của nó.
    //
    // `blockCache` thì không: giấu không dời và không bỏ ký tự nào, PDFKit vẫn
    // trích được chữ đang ở `3 Tr`, nên đọc lại trang cho ra đúng những block
    // vừa xoá đi. Và có người hỏi nó ngay trong cùng cú chạm — `beginEditing`
    // gọi `typingFloor` để biết trần của block dưới — nên xoá ở đây là mua một
    // lượt `selectionsByLine` nữa, đổi lấy đúng cái đã có.
    runCache[changedPage] = nil
  }

  func invalidateBlocks() {
    blockCache.removeAll()
    runCache.removeAll()
    committedEdits.removeAll()
    refreshBlockOutlines()
  }

  // MARK: - Picking

  @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
    guard isEnabled, let pdfView else { return }

    // Ô nhập đang mở thì đóng nó trước — và `dismissEditor` lo phần trả chữ gốc
    // về. Không làm vậy thì chạm sang block khác sẽ bỏ lại lần giấu cũ mồ côi.
    if editingStyle != nil { dismissEditor() }
    let viewPoint = gesture.location(in: pdfView)
    guard let page = pdfView.page(for: viewPoint, nearest: true) else {
      report(nil)
      return
    }

    let pagePoint = pdfView.convert(viewPoint, to: page)
    let index = pdfView.document?.index(for: page) ?? 0

    // Block đã được vẽ viền sẵn nên cú chạm chỉ cần gọi tên một cái. Khớp cuối
    // thắng: block đã sửa được thêm vào sau block đọc từ trang.
    let listed = CFAbsoluteTimeGetCurrent()
    let candidates = blocks(on: page, pageIndex: index)
    logPdfEvent("text_blocks_listed", "count=\(candidates.count) in=\(Self.since(listed))ms")

    guard let block = candidates.last(
      where: { $0.bounds.insetBy(dx: -6, dy: -6).contains(pagePoint) }
    ) else {
      report(nil)
      return
    }

    let started = CFAbsoluteTimeGetCurrent()
    select(block, on: page, pageIndex: index, near: pagePoint)
    logPdfEvent("text_block_tap", "total=\(Self.since(started))ms")
  }

  /// Turns a block into the field the user types in.
  private func select(
    _ block: TextBlock,
    on page: PDFPage,
    pageIndex: Int,
    near point: CGPoint
  ) {
    guard !block.text.isEmpty || block.edit != nil else {
      report(nil)
      return
    }

    // Đo tách pha: đường này chạy đúng một lần cho mỗi block chưa sửa, và nó
    // render trang ba lần — mẫu màu, độ đậm mực, và dò dấu thanh phía trên.
    var mark = CFAbsoluteTimeGetCurrent()
    var timings: [String] = []
    func phase(_ name: String) {
      timings.append("\(name)=\(Self.since(mark))")
      mark = CFAbsoluteTimeGetCurrent()
    }

    let style: (name: String?, size: Double, ink: PdfColor, paper: PdfColor)
    var kern: CGFloat = 0
    if let edit = block.edit {
      // Đọc từ chính chỉnh sửa, không đo lại trang: trang vẫn còn chữ cũ dưới
      // miếng vá, đo lại sẽ ra font/màu cũ hoặc pha trộn, và mỗi lần sửa lại
      // trôi thêm một nấc.
      style = (
        usableName(of: edit.font),
        Double(edit.font.pointSize),
        PdfColor(argb: edit.ink.argb),
        // Không còn ai sơn nền nữa, nhưng `PdfTextBlock` vẫn có ô này và Dart
        // vẫn đọc — trả trắng cho xong.
        PdfColor(argb: UIColor.white.argb)
      )
      // Khôi phục luôn tracking — annotation trước đây không mang được, nên chữ
      // cứ xích lại gần nhau sau mỗi lần sửa.
      kern = edit.kern
      logPdfEvent(
        "text_block_reselected",
        "pageIndex=\(pageIndex) length=\(block.text.count) font=\(style.name ?? "system")"
      )
    } else {
      // Đo trên một dòng, không phải cả block: lấy mẫu màu cần chiều cao một
      // dòng mới phân giải được lõi nét chữ.
      guard let line = block.lines.min(by: {
        abs($0.bounds.midY - point.y) < abs($1.bounds.midY - point.y)
      }) else {
        report(nil)
        return
      }

      // Ưu tiên những gì content stream nói thẳng ra: màu, font, tracking,
      // render mode. Suy từ pixel dễ đọc ngược tiêu đề trắng trên nền đỏ.
      let stream = PdfContentStreamReader.attributes(
        in: line.bounds,
        among: runs(on: page, pageIndex: pageIndex)
      )

      phase("stream")
      let measured = measuredFont(of: line.selection, lineHeight: line.bounds.height)
      phase("font")
      // Đo màu bằng pixel là một lượt render trang, nên chỉ đo khi thật sự
      // phải đo. Content stream khai màu mực thì không phải; còn màu giấy thì
      // không còn ai dùng từ khi bỏ lớp che.
      var sampled: (ink: UIColor, paper: UIColor)?
      func colours() -> (ink: UIColor, paper: UIColor) {
        if let sampled { return sampled }
        let result = sampledColours(of: line.bounds, on: page)
        sampled = result
        return result
      }

      let font = resolvedFont(
        measured: measured,
        stream: stream,
        text: line.selection.string ?? "",
        bounds: line.bounds,
        on: page,
        colours: colours
      )
      phase("weight")

      let ink = stream?.fill.map {
        UIColor(red: $0.red, green: $0.green, blue: $0.blue, alpha: 1)
      } ?? colours().ink

      let candidate = font.name.flatMap { UIFont(name: $0, size: font.size) }
        ?? UIFont.systemFont(ofSize: font.size)
      kern = stream?.characterSpacing ?? measuredKern(
        for: line.selection.string ?? "",
        font: candidate,
        width: line.bounds.width
      )

      style = (
        font.name,
        Double(font.size),
        PdfColor(argb: ink.argb),
        // Không ai sơn nền nữa. Báo màu đã đo nếu tình cờ có, trắng nếu không.
        PdfColor(argb: (sampled?.paper ?? .white).argb)
      )
      logPdfEvent(
        "text_block_selected",
        "pageIndex=\(pageIndex) lines=\(block.lines.count) length=\(block.text.count) "
          + "font=\(font.name ?? "system") size=\(font.size) "
          + "kern=\(String(format: "%.2f", kern)) "
          + "source=\(stream == nil ? "pixels" : "stream")"
      )
    }

    // Chốt ở đây chứ không ở commit, để ô nhập gõ đúng face sẽ ghi vào file.
    // Đổi muộn hơn sẽ cắt ngang tổ hợp Telex và mất âm tiết đang gõ.
    let styleName = style.name
      .flatMap { UIFont(name: $0, size: CGFloat(style.size)) }
      .map { embeddable($0, for: block.text).fontName } ?? style.name

    let selected = PdfTextBlock(
      pageIndex: Int64(pageIndex),
      bounds: PdfRect(
        x: block.bounds.origin.x,
        y: block.bounds.origin.y,
        width: block.bounds.width,
        height: block.bounds.height
      ),
      text: block.text,
      fontSize: style.size,
      textColor: style.ink,
      backgroundColor: style.paper,
      fontName: styleName
    )

    // Đo một lần ở đây rồi mang theo suốt: hộp dòng của PDFKit là font metrics,
    // mà dấu thanh chồng trên dấu mũ vươn cao hơn nó.
    let cover = block.cover ?? raisedOverMarks(
      block.bounds,
      on: page,
      size: CGFloat(style.size),
      paperLuma: luma(of: UIColor(argb: style.paper.argb)),
      cut: max(abs(luma(of: UIColor(argb: style.paper.argb))
        - luma(of: UIColor(argb: style.ink.argb))) / 2, 0.1)
    )

    // Giấu chữ gốc — sau khi đo xong, và chỉ với block chưa từng sửa.
    //
    // Thứ tự này bắt buộc: `3 Tr` làm `runs()` bỏ qua chính mấy operator đó, mà
    // pixel cũng không còn chữ để đo, nên giấu trước là mất sạch dữ liệu đo
    // style. Đo xong rồi mới giấu.
    //
    // Tài liệu bị ghi lại và mở lại, nên `page` từ đây trở đi là trang mới.
    var page = page
    editingHidOriginal = false
    if block.edit == nil, let replacement = onHideOriginal?(pageIndex, cover) {
      page = replacement
      editingHidOriginal = true
    }

    phase("cover")
    logPdfEvent("text_block_select_phases", timings.joined(separator: " "))

    beginEditing(
      selected,
      text: block.text,
      on: page,
      bounds: block.bounds,
      // A block edited before keeps the cover it already has.
      cover: cover,
      kern: kern
    )
    onSelection?(selected)
  }

  // MARK: - Finding the blocks on a page

  /// An editable block of text: a paragraph's worth of lines and the flowing
  /// text they carry.
  private struct TextBlock {
    var bounds: CGRect
    var text: String
    var lines: [(selection: PDFSelection, bounds: CGRect)]
    /// The committed edit covering this block, when there is one. Its presence
    /// is what says the style comes from the edit rather than from the page.
    var edit: CommittedEdit?
    /// What that cover covers — the original run, not the box the replacement
    /// was given. Nil for a block that has not been edited yet, whose own
    /// bounds are the run.
    var cover: CGRect?

    /// Every part of the page this block speaks for: the box its words sit in
    /// and, for an edit, the run painted out underneath them.
    ///
    /// The two come apart as soon as the handle is dragged, and the union is
    /// what the rest of the class has to reason with. Shrinking the words'
    /// box below the run it replaced must not let that run be read as a
    /// separate block again — it is still there under the cover, and treating
    /// it as a neighbour would make it fence in the very edit covering it.
    var occupied: CGRect { cover.map { $0.union(bounds) } ?? bounds }
  }

  /// Block của một trang, có cache — cần mỗi frame khi cuộn, mà đọc chữ của
  /// trang thì quá chậm để làm ở nhịp đó.
  private func blocks(on page: PDFPage, pageIndex: Int) -> [TextBlock] {
    if let cached = blockCache[pageIndex] { return cached }

    var result = readBlocks(on: page)

    // An edited block replaces whatever the page reports over the same area:
    // what it reports there is the run hidden under the cover.
    let edited = editedBlocks(on: page)
    if !edited.isEmpty {
      result.removeAll { block in
        edited.contains { $0.occupied.intersects(block.bounds) }
      }
      result.append(contentsOf: edited)
    }

    blockCache[pageIndex] = result
    return result
  }

// Warming the keyboard was tried here and taken back out. Raising a throwaway
// text field and dropping it inside one runloop turn — the trick that works so
// well on PDFKit's annotations — measured 6545ms on device and logged
// `RTIInputSystemClient ... requires a valid sessionID` while it did: tearing
// the input session down mid-setup makes UIKit pay far more than simply letting
// the field come up when the user asks for it. Taps measure 70-92ms as they
// stand. If first-caret latency ever needs attacking again, it needs a
// technique that lets the session finish, not a faster place to put this one.

  /// The page's text-drawing operators, cached.
  private func runs(on page: PDFPage, pageIndex: Int) -> [PdfContentStreamReader.Run] {
    if let cached = runCache[pageIndex] { return cached }
    let runs = PdfContentStreamReader.runs(on: page)
    runCache[pageIndex] = runs
    logPdfEvent("content_stream_scanned", "pageIndex=\(pageIndex) runs=\(runs.count)")
    return runs
  }

  /// Gom dòng của trang thành đoạn văn.
  ///
  /// PDF lưu glyph đã đặt chỗ, không lưu cấu trúc — không có "đoạn văn". Nên
  /// đoạn được dựng lại từ hình học: dòng nào cùng cỡ chữ, đủ gần phía dưới, và
  /// nằm chồng cột với dòng trước thì thuộc cùng một đoạn.
  private func readBlocks(on page: PDFPage) -> [TextBlock] {
    guard let whole = page.selection(for: page.bounds(for: .cropBox)) else { return [] }

    let lines: [(selection: PDFSelection, bounds: CGRect)] = whole.selectionsByLine()
      .compactMap { line in
        let bounds = line.bounds(for: page)
        let text = line.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard Self.isDrawable(bounds), bounds.width > 1, bounds.height > 1,
              !text.isEmpty else { return nil }
        return (line, bounds)
      }
    guard !lines.isEmpty else { return [] }

    // Cắt trước khi gộp: một hàng chữ có khoảng trống rộng ở giữa phải thành hai
    // dòng riêng, rồi mới tới lượt `continues()` quyết định chúng có cùng đoạn.
    let pieces = lines.flatMap { self.split($0, on: page) }
    guard !pieces.isEmpty else { return [] }

    return grouped(pieces).map { group in
      TextBlock(
        bounds: group.dropFirst().reduce(group[0].bounds) { $0.union($1.bounds) },
        text: joined(group.map { $0.selection.string ?? "" }),
        lines: group,
        edit: nil,
        cover: nil
      )
    }
  }

  /// Gom các mảnh dòng thành block, theo hình học chứ không theo thứ tự đọc.
  ///
  /// Cách cũ so mỗi mảnh với mảnh **ngay trước nó** trong thứ tự đọc. Với văn
  /// bản một cột thì đúng, với bảng thì sai hẳn: thứ tự đọc chạy ngang hết một
  /// hàng rồi mới xuống hàng sau, nên ô cột 1 bị đem so với ô cột cuối cùng của
  /// hàng trên nó, còn ô ngay bên dưới nó thì không bao giờ được so.
  ///
  /// Ở đây hai mảnh nối với nhau khi `continues` nói chúng cùng đoạn, **bất kể
  /// nằm đâu trong thứ tự đọc**, rồi block là các thành phần liên thông. Cột
  /// của bảng tự gom dọc với nhau vì cùng khoảng x và sát nhau theo y; ô bên
  /// cạnh không gom vì không chồng lấn ngang.
  ///
  /// So từng cặp, `n²` phép so hình chữ nhật. Một trang dày cỡ vài trăm mảnh
  /// thì vẫn rẻ hơn nhiều so với `selectionsByLine` sinh ra chúng.
  private func grouped(
    _ pieces: [(selection: PDFSelection, bounds: CGRect)]
  ) -> [[(selection: PDFSelection, bounds: CGRect)]] {
    var parent = Array(0..<pieces.count)
    var size = Array(repeating: 1, count: pieces.count)

    func root(_ index: Int) -> Int {
      var current = index
      while parent[current] != current {
        parent[current] = parent[parent[current]]
        current = parent[current]
      }
      return current
    }

    for i in 0..<pieces.count {
      for j in (i + 1)..<pieces.count {
        let a = root(i), b = root(j)
        guard a != b else { continue }
        // Chặn trên cho một block. Không phải để tiết kiệm mà để một trang thân
        // bài liền mạch không thành một block duy nhất — chạm vào đâu cũng chọn
        // cả trang thì không sửa được gì.
        guard size[a] + size[b] <= Self.paragraphLineLimit else { continue }
        guard continues(from: pieces[i].bounds, to: pieces[j].bounds) else { continue }
        if size[a] < size[b] {
          parent[a] = b
          size[b] += size[a]
        } else {
          parent[b] = a
          size[a] += size[b]
        }
      }
    }

    var groups: [Int: [(selection: PDFSelection, bounds: CGRect)]] = [:]
    for index in pieces.indices { groups[root(index), default: []].append(pieces[index]) }

    // Trong mỗi block, sắp lại theo thứ tự đọc: trên xuống dưới, trái sang
    // phải. `joined()` nối chuỗi theo thứ tự này.
    return groups.values.map { group in
      group.sorted {
        abs($0.bounds.midY - $1.bounds.midY) > 1
          ? $0.bounds.midY > $1.bounds.midY
          : $0.bounds.minX < $1.bounds.minX
      }
    }
  }

  /// Block của các chỉnh sửa đã commit, đọc từ bộ nhớ.
  ///
  /// Block là hộp của chính chỉnh sửa nên kích thước đã kéo được giữ lại; `cover`
  /// đi kèm nguyên vẹn vì nó là chỗ chữ gốc nằm — suy lại từ hộp đã bị kéo sẽ
  /// khiến vùng sơn lấn xuống dòng dưới.
  private func editedBlocks(on page: PDFPage) -> [TextBlock] {
    committedEdits
      .filter { $0.page === page && Self.isDrawable($0.bounds) }
      .map { edit in
        TextBlock(
          bounds: edit.bounds,
          text: edit.text,
          lines: [],
          edit: edit,
          cover: edit.cover
        )
      }
  }

  /// Whether a rect can be handed to CoreGraphics.
  ///
  /// `CGRect.null` and `.infinite` are ordinary results here — `intersection`
  /// returns null when two rects miss, and PDFKit hands back null bounds for a
  /// selection it cannot place — and passing either into a path or an
  /// annotation is what produces the "invalid numeric value (NaN)" the console
  /// fills with.
  private static func isDrawable(_ rect: CGRect) -> Bool {
    !rect.isNull && !rect.isInfinite
      && rect.origin.x.isFinite && rect.origin.y.isFinite
      && rect.width.isFinite && rect.height.isFinite
      && rect.width > 0 && rect.height > 0
  }


  /// The font's PostScript name when it will round-trip through
  /// `UIFont(name:size:)`, and nil when it will not — the system font reports a
  /// name that cannot be used to ask for it back.
  /// 14 font dựng sẵn của PDF, theo tên PostScript.
  ///
  /// Không ai nhúng chúng, nên chúng bị khoá vào WinAnsiEncoding = Latin-1.
  /// `à é ô` có, `ắ ế ộ ư đ` không — không có mã nào trong bảng để đặt. Chữ sẽ
  /// rụng lặng lẽ. TextKit thì tự tìm font khác có glyph; PDF không có cơ chế đó.
  private static let standardFourteen: Set<String> = [
    "Helvetica", "Helvetica-Bold", "Helvetica-Oblique", "Helvetica-BoldOblique",
    "Courier", "Courier-Bold", "Courier-Oblique", "Courier-BoldOblique",
    "Times-Roman", "Times-Bold", "Times-Italic", "Times-BoldItalic",
    "Symbol", "ZapfDingbats",
  ]

  /// Font thay thế theo họ. Chọn face gần nhất máy có mà **không** thuộc bộ 14,
  /// để buộc PDFKit phải nhúng — nhúng là thứ mang encoding đi theo.
  private static let embeddableSubstitutes: [String: String] = [
    "Helvetica": "Helvetica Neue",
    "Courier": "Courier New",
    "Times": "Times New Roman",
  ]

  /// Font thật sự ghi được chuỗi này.
  ///
  /// Chỉ đổi khi font thuộc bộ 14 **và** chuỗi có ký tự trên U+00FF — đổi face
  /// mà trang đã chọn là thay đổi nhìn thấy được, chỉ đáng khi không đổi thì mất
  /// ký tự. WinAnsi dừng ở U+00FF, mọi chữ riêng của tiếng Việt nằm phía trên.
  private func embeddable(_ font: UIFont, for text: String) -> UIFont {
    guard Self.standardFourteen.contains(font.fontName),
          text.unicodeScalars.contains(where: { $0.value > 0xFF }) else { return font }

    let family = font.fontName.split(separator: "-").first.map(String.init) ?? font.fontName
    let substitute = Self.embeddableSubstitutes[family]
      ?? UIFont.systemFont(ofSize: font.pointSize).familyName

    var descriptor = UIFontDescriptor(fontAttributes: [.family: substitute])
    // Giữ nguyên đậm/nghiêng: trang đã quyết rồi, việc đổi font chỉ vì encoding.
    let traits = font.fontDescriptor.symbolicTraits.intersection([.traitBold, .traitItalic])
    if !traits.isEmpty, let withTraits = descriptor.withSymbolicTraits(traits) {
      descriptor = withTraits
    }

    let replacement = UIFont(descriptor: descriptor, size: font.pointSize)
    logPdfEvent(
      "font_substituted",
      "from=\(font.fontName) to=\(replacement.fontName) reason=win_ansi_cannot_encode"
    )
    return replacement
  }

  private func usableName(of font: UIFont?) -> String? {
    guard let font, UIFont(name: font.fontName, size: font.pointSize) != nil else { return nil }
    return font.fontName
  }

  // MARK: - Showing the blocks

  /// Vẽ viền mọi block sửa được trên các trang đang thấy. Vẽ ngay khi bật chế
  /// độ, để người dùng thấy được chỗ nào sửa được thay vì phải chạm mò.
  private func refreshBlockOutlines() {
    guard isEnabled, let pdfView, let document = pdfView.document else {
      blockLayer.path = nil
      return
    }

    let path = CGMutablePath()
    var missing: [(page: PDFPage, index: Int)] = []

    for page in pdfView.visiblePages {
      let index = document.index(for: page)
      // Chỉ dùng cái đã đọc. `selectionsByLine` trên trang dày chạy hàng giây,
      // mà hàm này chạy mỗi frame cuộn. Trang chưa đọc thì xếp hàng bên dưới.
      guard let cached = blockCache[index] else {
        missing.append((page, index))
        continue
      }
      for block in cached {
        // Block đang có ô nhập thì không vẽ viền — ô nhập đã chỉ ra chỗ rồi.
        if isUnderField(block.occupied, pageIndex: index) { continue }
        guard Self.isDrawable(block.bounds) else { continue }
        let rect = pdfView.convert(block.bounds, from: page).insetBy(dx: -2, dy: -2)
        guard Self.isDrawable(rect), rect.width > 6, rect.height > 6,
              rect.intersects(pdfView.bounds) else { continue }
        path.addPath(UIBezierPath(roundedRect: rect, cornerRadius: 3).cgPath)
      }
    }

    blockLayer.frame = pdfView.bounds
    blockLayer.path = path.isEmpty ? nil : path

    // The field and the committed edits live in view coordinates too, so
    // whatever moved the outlines moved them as well.
    layoutEditingViews()
    refreshEditPreview()

    guard let next = missing.first else { return }
    scheduleRead(of: next.page, pageIndex: next.index)
  }

  /// Đọc block của một trang khi người dùng đã ngừng yêu cầu gì khác.
  ///
  /// `selectionsByLine` chạy trên main thread và tốn hàng giây trên trang dày —
  /// rơi vào giữa hai lần gõ là ô nhập đứng hình. Nên nó chờ lúc yên, và tránh
  /// hẳn khi đang có ô nhập mở, nhưng **tự hẹn lại** thay vì bỏ cuộc.
  private func scheduleRead(of page: PDFPage, pageIndex: Int) {
    readRequest += 1
    let request = readRequest

    DispatchQueue.main.asyncAfter(deadline: .now() + Self.blockReadDelay) { [weak self] in
      guard let self, self.isEnabled, self.readRequest == request else { return }

      // Đang có ô nhập mở nên chưa phải lúc — nhưng đẩy lại vào hàng đợi chứ
      // không vứt đi.
      guard self.editingStyle == nil else {
        self.scheduleRead(of: page, pageIndex: pageIndex)
        return
      }

      if self.blockCache[pageIndex] == nil {
        let started = CFAbsoluteTimeGetCurrent()
        _ = self.blocks(on: page, pageIndex: pageIndex)
        logPdfEvent("text_blocks_read", "pageIndex=\(pageIndex) in=\(Self.since(started))ms")
      }
      // Quét cả content stream, không chỉ block: `select` cần nó ở cú chạm đầu
      // tiên vào mỗi trang.
      _ = self.runs(on: page, pageIndex: pageIndex)

      self.refreshBlockOutlines()
    }
  }

  /// Giữ viền bám đúng block khi trang di chuyển bên dưới.
  ///
  /// Viền sống trong toạ độ view nên mọi lần cuộn/zoom đều làm lệch. Quan sát
  /// `contentOffset` thay vì hỏi liên tục — nó là giá trị đổi mỗi frame cuộn.
  private func startTrackingViewport() {
    stopTrackingViewport()
    guard let pdfView else { return }

    if let scrollView = Self.scrollView(in: pdfView) {
      viewportObservations.append(
        scrollView.observe(\.contentOffset) { [weak self] _, _ in
          self?.refreshBlockOutlines()
        }
      )
      viewportObservations.append(
        scrollView.observe(\.bounds) { [weak self] _, _ in
          self?.refreshBlockOutlines()
        }
      )
    }

    for name: Notification.Name in [
      .PDFViewScaleChanged,
      .PDFViewPageChanged,
      .PDFViewVisiblePagesChanged,
    ] {
      viewportNotifications.append(
        NotificationCenter.default.addObserver(
          forName: name,
          object: pdfView,
          queue: .main
        ) { [weak self] _ in
          self?.refreshBlockOutlines()
        }
      )
    }
  }

  private func stopTrackingViewport() {
    viewportObservations.removeAll()
    for observer in viewportNotifications {
      NotificationCenter.default.removeObserver(observer)
    }
    viewportNotifications.removeAll()
  }

  private static func scrollView(in view: UIView) -> UIScrollView? {
    if let scrollView = view as? UIScrollView { return scrollView }
    for subview in view.subviews {
      if let found = scrollView(in: subview) { return found }
    }
    return nil
  }

  /// Cắt một dòng ở những chỗ trống ngang đủ rộng.
  ///
  /// Đi theo hộp của từng ký tự chứ không theo hộp của cả dòng, vì hộp dòng đã
  /// nuốt mất khoảng trống rồi. Bỏ qua ký tự trắng: chỗ trống trong bố cục kiểu
  /// cột thường do lệnh định vị tạo ra, nhưng khi nó là một chuỗi dấu cách thật
  /// thì chính mấy dấu cách đó sẽ bắc cầu qua khe và che mất nó.
  private func split(
    _ line: (selection: PDFSelection, bounds: CGRect),
    on page: PDFPage
  ) -> [(selection: PDFSelection, bounds: CGRect)] {
    let count = line.selection.numberOfTextRanges(on: page)
    guard count > 0, let text = page.string as NSString? else { return [line] }

    // Hộp của từng ký tự không phải khoảng trắng, theo thứ tự.
    var boxes: [CGRect] = []
    for slot in 0..<count {
      let range = line.selection.range(at: slot, on: page)
      guard range.location != NSNotFound else { continue }
      for index in range.location..<min(range.location + range.length, text.length) {
        let character = text.substring(with: NSRange(location: index, length: 1))
        guard character.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { continue }
        let box = page.characterBounds(at: index)
        guard Self.isDrawable(box) else { continue }
        boxes.append(box)
      }
    }
    guard boxes.count > 1 else { return [line] }

    // Khe giữa các ký tự liền nhau. Trong một từ thì gần bằng 0; giữa hai từ là
    // bề rộng dấu cách; giữa hai ô bảng thì lớn hơn hẳn.
    var gaps: [CGFloat] = []
    for index in 1..<boxes.count {
      gaps.append(boxes[index].minX - boxes[index - 1].maxX)
    }

    // Dấu cách của chính dòng này, ước lượng bằng trung vị các khe thật sự có
    // bề rộng. Bỏ khe trong từ ra, nếu không trung vị sẽ về 0 và mọi thứ đều
    // thành ranh giới cột.
    let spaced = gaps.filter { $0 > 0.5 }.sorted()
    let space = spaced.isEmpty ? 0 : spaced[spaced.count / 2]
    let threshold = max(
      space * Self.columnGapInSpaces,
      line.bounds.height * Self.paragraphColumnGap
    )

    var pieces: [CGRect] = []
    var open = boxes[0]
    for index in 1..<boxes.count {
      if gaps[index - 1] > threshold {
        pieces.append(open)
        open = boxes[index]
      } else {
        open = open.union(boxes[index])
      }
    }
    pieces.append(open)

    guard pieces.count > 1 else {
      // Không cắt, nhưng vẫn ghi lại khe lớn nhất: nếu bảng bị gộp thì con số
      // này với ngưỡng đứng cạnh nhau nói ngay phải chỉnh bao nhiêu.
      if let widest = gaps.max(), widest > 1 {
        logPdfVerbose(
          "text_line_intact",
          "widest=\(String(format: "%.1f", widest)) threshold=\(String(format: "%.1f", threshold)) "
            + "space=\(String(format: "%.1f", space)) height=\(Int(line.bounds.height))"
        )
      }
      return [line]
    }

    logPdfVerbose(
      "text_line_split",
      "pieces=\(pieces.count) threshold=\(String(format: "%.1f", threshold)) "
        + "space=\(String(format: "%.1f", space)) width=\(Int(line.bounds.width))"
    )

    // Chiều cao lấy từ dòng gốc, không lấy từ hộp ký tự: mấy phép kiểm gộp đoạn
    // so chiều cao với nhau, mà hộp ký tự cao thấp tuỳ chữ có dấu hay không.
    return pieces.compactMap { piece in
      let bounds = CGRect(
        x: piece.minX,
        y: line.bounds.minY,
        width: piece.width,
        height: line.bounds.height
      )
      guard let selection = page.selection(for: bounds.insetBy(dx: -1, dy: -1)),
            !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { return nil }
      return (selection, bounds)
    }
  }

  /// Hai mảnh dòng có thuộc cùng một block không.
  ///
  /// Đối xứng — không có mảnh nào là "trước", vì `grouped` gọi nó theo cặp chứ
  /// không theo thứ tự đọc.
  private func continues(from current: CGRect, to next: CGRect) -> Bool {
    let gap = next.maxY < current.maxY
      ? current.minY - next.maxY
      : next.minY - current.maxY
    // Đo theo dòng **thấp hơn**, không theo `current`. Một tiêu đề cỡ lớn cấp
    // cho thứ nằm dưới nó một khoảng dôi rất rộng, và dòng thân bài cách đó cả
    // một hàng trống vẫn lọt vào cùng block với tiêu đề.
    let leading = min(current.height, next.height)
    guard gap <= leading * Self.paragraphLineGap else { return false }

    let ratio = next.height / max(current.height, 0.01)
    guard Self.paragraphHeightRatio.contains(ratio) else { return false }

    let overlap = min(current.maxX, next.maxX) - max(current.minX, next.minX)
    guard overlap >= min(current.width, next.width) * Self.paragraphOverlapShare else {
      return false
    }

    // Và không được nằm lệch hẳn sang bên: hợp của hai dòng phải xấp xỉ dòng
    // rộng nhất. Kiểm tra chồng lấn ở trên không bắt được chuyện này vì nó tính
    // theo dòng hẹp hơn.
    let spread = max(current.maxX, next.maxX) - min(current.minX, next.minX)
    return spread <= max(current.width, next.width) * Self.paragraphSpreadShare
  }

  /// Nối các dòng của block thành chữ liền.
  ///
  /// Ngắt dòng là của người dàn trang, không phải của tác giả — giữ lại sẽ đóng
  /// băng cách xuống dòng cũ vào một đoạn chữ có độ dài khác. Từ bị gạch nối
  /// cắt ngang cũng được ghép lại.
  private func joined(_ lines: [String]) -> String {
    var result = ""
    for raw in lines {
      let piece = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !piece.isEmpty else { continue }
      if result.isEmpty {
        result = piece
      } else if result.hasSuffix("-") {
        result.removeLast()
        result += piece
      } else {
        result += " " + piece
      }
    }
    return result
  }

  // MARK: - Editing in place

  /// Puts the field over the block and opens the keyboard.
  private func beginEditing(
    _ block: PdfTextBlock,
    text: String,
    on page: PDFPage,
    bounds: CGRect,
    cover: CGRect,
    kern: CGFloat
  ) {
    guard let pdfView else { return }

    // Ô nhập mở lại: lần tắt bàn phím đang chờ không còn nghĩa lý gì. Cùng một
    // text view, nên nó vẫn đang là first responder và bàn phím vẫn đang lên —
    // không có gì phải làm, và đó chính là chỗ tiết kiệm được 2717ms.
    keyboardDismissRequest += 1

    editingPage = page
    editingBounds = bounds
    editingOriginalBounds = bounds
    editingCover = cover
    editingKern = kern
    editingFloor = typingFloor(for: bounds, on: page)
    editingTypography = nil
    editingStyle = PdfTextEditRequest(
      pageIndex: block.pageIndex,
      bounds: block.bounds,
      text: text,
      fontSize: block.fontSize,
      textColor: block.textColor,
      backgroundColor: block.backgroundColor,
      fontName: block.fontName
    )

    // Kéo lên nửa trên trước: bàn phím sắp che nửa dưới. Đây là lần dịch trang
    // **duy nhất** của một cú chạm — lần đổi document lúc giấu chữ gốc đã đặt
    // lại đúng chỗ cũ rồi, nên nó không tính.
    pdfView.go(to: bounds.insetBy(dx: 0, dy: -min(bounds.height * 2, 240)), on: page)
    // Ép cuộn xong ngay tại đây. `go(to:on:)` mới chỉ đặt offset; chưa layout
    // thì `pdfView.convert` ở `showEditor` còn đọc toạ độ của chỗ trang vừa
    // rời đi, và ô nhập mở ra lệch đúng bằng quãng vừa cuộn.
    pdfView.layoutIfNeeded()

    // Sau khi cuộn xong, để đổi toạ độ theo chỗ trang thật sự dừng lại.
    DispatchQueue.main.async { [weak self] in
      self?.showEditor(text: text, block: block)
    }
  }

  private func showEditor(text: String, block: PdfTextBlock) {
    guard let pdfView, editingPage != nil, editingBounds != nil else { return }

    editor.text = text
    editor.backgroundColor = .clear
    editor.tintColor = .systemBlue
    editingTypography = nil


    if editor.superview == nil {
      pdfView.addSubview(editor)
    }
    for handle in resizeHandles.values where handle.superview == nil {
      pdfView.addSubview(handle)
    }
    editor.isHidden = false
    for handle in resizeHandles.values { handle.isHidden = false }
    // Xếp chồng có chủ đích, dưới lên trên: chữ đang gõ, viền, nút.
    //
    // `fieldBorder` phải nâng ở đây: nó là layer gắn lúc setup, còn miếng vá là
    // subview được đưa lên trước mỗi lần mở ô nhập, nên vá đục sẽ phủ mất viền.
    // Gắn lại một sublayer đã gắn sẽ đẩy nó lên đầu — cách duy nhất để layer
    // vượt qua subview thêm sau.
    pdfView.bringSubviewToFront(editor)
    pdfView.layer.addSublayer(fieldBorder)
    for handle in resizeHandles.values { pdfView.bringSubviewToFront(handle) }

    layoutEditingViews()
    clearHighlight()
    // Trước khi vẽ viền: con trỏ mới là thứ cú chạm cần.
    editor.becomeFirstResponder()
    editor.selectedRange = NSRange(location: text.count, length: 0)
    refreshBlockOutlines()
  }

  /// Đặt ô nhập, nút kéo và cỡ chữ theo chỗ block đang hiện trên màn hình.
  ///
  /// Bốn nguyên nhân làm ô nhập phải dịch — cuộn, zoom, gõ chữ, kéo nút — đều
  /// đổ về đây, nên chỉ có một chỗ quyết định vị trí.
  private func layoutEditingViews() {
    guard let pdfView,
          let page = editingPage,
          let bounds = editingBounds,
          let style = editingStyle,
          !editor.isHidden else { return }

    let rect = pdfView.convert(bounds, from: page)
    guard Self.isDrawable(rect), rect.width > 1, rect.height > 1 else { return }

    // Cỡ chữ đo được là đơn vị trang; nhân với zoom để ra đúng cỡ trên màn hình.
    let zoom = rect.height / max(bounds.height, 0.01)
    let size = max(CGFloat(style.fontSize) * zoom, 1)
    let font = style.fontName.flatMap { UIFont(name: $0, size: size) }
      ?? UIFont.systemFont(ofSize: size)
    restyleEditor(
      font: font,
      kern: editingKern * zoom,
      colour: UIColor(argb: style.textColor.argb)
    )

    // Chừa chỗ phía trên dòng đầu cho dấu thanh chồng.
    //
    // Ô nhập không có container inset nên ascender dòng đầu nằm đúng cạnh trên,
    // mà text view thì cắt theo bounds — dấu bị cụt. Đưa vào bằng inset rồi lấy
    // lại bằng frame ở dưới, để chữ không dịch.
    let headroom = (size * Self.diacriticHeadroom).rounded(.up)
    let inset = UIEdgeInsets(top: headroom, left: 0, bottom: 0, right: 0)
    if editor.textContainerInset != inset {
      editor.textContainerInset = inset
    }

    // Dài xuống dưới khi chữ gõ vào vượt block.
    //
    // `sizeThatFits` sắp chữ toàn chuỗi, mà phần lớn lần gọi tới đây chỉ là cuộn
    // hoặc zoom — nên chỉ hỏi lại khi câu trả lời có thể đã đổi. Inset là một
    // phần câu trả lời nên cũng là một phần khoá.
    let typed = editor.text ?? ""
    if editingFit?.text != typed
        || abs((editingFit?.width ?? -1) - rect.width) > 0.5
        || abs((editingFit?.top ?? -1) - headroom) > 0.5 {
      editingFit = (
        text: typed,
        width: rect.width,
        top: headroom,
        height: editor.sizeThatFits(
          CGSize(width: rect.width, height: Self.unboundedHeight)
        ).height
      )
    }

    // Chỉ gán khi frame thật sự đổi. Gán frame kéo theo một lượt sắp chữ toàn
    // chuỗi (text view không cuộn), nên gán vô điều kiện trong `textViewDidChange`
    // là trả hai lượt cho mỗi phím. Phần lớn phím không đổi bốn con số này.
    // Nâng lên đúng headroom rồi trả lại bằng chiều cao: đáy block giữ nguyên.
    let wanted = max(rect.height + headroom, editingFit?.height ?? rect.height + headroom)

    // Khung dừng ở block kế tiếp phía dưới — nhưng chỉ *khung* dừng, không phải
    // bàn phím. Chạm trần thì ô nhập chuyển sang cuộn bên trong, gõ tiếp bình
    // thường. Bản trước chặn luôn phím và thành ra không gõ nổi dòng thứ hai
    // nếu chưa kéo khung to.
    // Trần lấy từ giá trị tính sẵn, không tính lại mỗi phím.
    //
    // `typingFloor` phải hỏi `blocks()`, mà sau lần giấu chữ thì tài liệu được
    // mở lại và cache block bị xoá sạch — nên gọi ở đây là mỗi phím một lượt
    // `selectionsByLine` cộng `characterBounds` toàn trang. Đó là chỗ bàn phím
    // đơ. Trần chỉ đổi khi kéo nút, nên tính lại ở đó là đủ.
    let floorInView = pdfView.convert(
      CGPoint(x: bounds.minX, y: editingFloor ?? page.bounds(for: .cropBox).minY), from: page
    ).y
    let capped = floorInView.isFinite
      ? max(min(wanted, floorInView - (rect.minY - headroom)), rect.height + headroom)
      : wanted

    let target = CGRect(x: rect.minX, y: rect.minY - headroom, width: rect.width, height: capped)
    if editor.frame != target {
      editor.frame = target
    }
    // Chỉ bật cuộn khi đã chạm trần: text view không cuộn thì mỗi lần bố cục là
    // sắp chữ toàn chuỗi, không đáng trả khi chưa cần.
    let overflowing = capped < wanted - 0.5
    if editor.isScrollEnabled != overflowing {
      editor.isScrollEnabled = overflowing
      if overflowing {
        logPdfEvent(
          "text_block_typing_capped",
          "wanted=\(Int(wanted)) capped=\(Int(capped))"
        )
      }
    }

    let grip = CGRect(
      origin: .zero,
      size: CGSize(width: Self.resizeHandleSize, height: Self.resizeHandleSize)
    )
    // Theo ô nhập chứ không theo block: ô nhập là thứ người dùng nhìn thấy.
    let box = editor.frame
    for (corner, handle) in resizeHandles {
      if handle.bounds != grip { handle.bounds = grip }
      // Hai nút trên bám cạnh block: trần ô nhập giờ là phần headroom trống.
      let centre = CGPoint(
        x: corner.movesLeftEdge ? box.minX : box.maxX,
        y: corner.movesTopEdge ? rect.minY : box.maxY
      )
      if handle.center != centre { handle.center = centre }
    }

    // Viền: đúng hình chữ nhật bốn nút vừa đứng vào bốn góc.
    //
    // Không phải `editor.frame` — trần ô nhập cao hơn cạnh trên block một khoảng
    // headroom chừa cho dấu thanh, mà khoảng đó trống. Vẽ theo nó thì viền
    // không đi qua hai nút trên.
    //
    // Nét liền, khác nét đứt của `blockLayer`: đứt là "chỗ này sửa được", liền
    // là "chỗ này đang sửa".
    let frame = CGRect(
      x: box.minX,
      y: rect.minY,
      width: box.width,
      height: max(box.maxY - rect.minY, 1)
    )
    fieldBorder.frame = pdfView.bounds
    fieldBorder.path = UIBezierPath(roundedRect: frame, cornerRadius: 3).cgPath
    fieldBorder.isHidden = false
  }

  /// Đặt style cho ô nhập, và đặt lại khi zoom làm đổi cỡ chữ.
  ///
  /// Phải set cả `typingAttributes`: text view giữ riêng thuộc tính cho ký tự sẽ
  /// gõ, chỉ set chuỗi thì phím sau đó quay về font hệ thống.
  private func restyleEditor(font: UIFont, kern: CGFloat, colour: UIColor) {
    let typography = (name: font.fontName, size: font.pointSize, kern: kern)
    if let current = editingTypography,
       current.name == typography.name,
       abs(current.size - typography.size) < 0.01,
       abs(current.kern - typography.kern) < 0.01 {
      return
    }
    editingTypography = typography

    // Cùng dictionary với lớp xem trước và trang giấy — dựng một chỗ để ba nơi
    // không lệch nhau.
    let attributes = PdfTextOverlay.attributes(font: font, colour: colour, kern: kern)
    editor.typingAttributes = attributes

    let text = editor.text ?? ""
    guard !text.isEmpty else { return }
    // Trả con trỏ về chỗ cũ: gán lại `attributedText` đẩy nó về đầu.
    let selected = editor.selectedRange
    editor.attributedText = NSAttributedString(string: text, attributes: attributes)
    editor.selectedRange = selected
  }

  // MARK: - Resizing the block

  /// Kéo bốn góc của block.
  @objc private func handleResize(_ gesture: UIPanGestureRecognizer) {
    guard let pdfView, let page = editingPage,
          let corner = resizeHandles.first(where: { $0.value === gesture.view })?.key
    else { return }

    switch gesture.state {
    case .began:
      resizeStartBounds = editingBounds
    case .changed, .ended, .cancelled, .failed:
      guard let start = resizeStartBounds else { return }
      let translation = gesture.translation(in: pdfView)
      let zoom = max(pdfView.scaleFactor, 0.01)
      guard translation.x.isFinite, translation.y.isFinite, zoom.isFinite else { return }

      // PDF user space points up and the view points down, so a drag downward
      // is a fall in page coordinates.
      let dx = translation.x / zoom
      let dy = -translation.y / zoom

      // Chỉ hai cạnh gặp ở góc đang kéo là dịch. Tính từ `resizeStartBounds`
      // chứ không cộng dồn theo frame — cộng dồn sẽ trôi.
      var minX = start.minX, maxX = start.maxX
      var minY = start.minY, maxY = start.maxY
      if corner.movesLeftEdge { minX += dx } else { maxX += dx }
      if corner.movesTopEdge { maxY += dy } else { minY += dy }

      // Không cho vượt qua cạnh neo: lật ngược hình là chỗ NaN bắt đầu.
      (minX, maxX) = Self.separated(minX, maxX, moving: corner.movesLeftEdge, by: minimumWidth)
      (minY, maxY) = Self.separated(minY, maxY, moving: !corner.movesTopEdge, by: Self.minimumBlockSize.height)

      let proposed = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
      let allowed = allowedBounds(proposed, from: corner, anchoredAt: start, on: page)
      editingBounds = allowed
      // Bề ngang đổi thì hàng xóm chặn đường cũng đổi.
      editingFloor = typingFloor(for: allowed, on: page)
      editingStyle?.bounds = PdfRect(
        x: allowed.origin.x,
        y: allowed.origin.y,
        width: allowed.width,
        height: allowed.height
      )
      layoutEditingViews()
      refreshBlockOutlines()

      if gesture.state != .changed {
        resizeStartBounds = nil
        logPdfEvent(
          "text_block_resized",
          "corner=\(corner) width=\(Int(allowed.width)) height=\(Int(allowed.height))"
        )
      }
    default:
      break
    }
  }

  /// Kẹp block đề xuất vào khổ giấy và vào các block hàng xóm.
  ///
  /// Cho nó lấn sang block bên cạnh là sơn đè lên block đó rồi đặt chữ mình lên
  /// trên — hai đoạn văn cùng một chỗ.
  private func allowedBounds(
    _ proposed: CGRect,
    from corner: Corner,
    anchoredAt origin: CGRect,
    on page: PDFPage
  ) -> CGRect {
    guard Self.isDrawable(proposed) else { return origin }

    var minX = proposed.minX, maxX = proposed.maxX
    var minY = proposed.minY, maxY = proposed.maxY

    // Kẹp giấy, chỉ với hai cạnh đã dịch: cặp neo vốn đã nằm trong trang.
    let paper = page.bounds(for: .cropBox)
    if corner.movesLeftEdge { minX = max(minX, paper.minX) } else { maxX = min(maxX, paper.maxX) }
    if corner.movesTopEdge { maxY = min(maxY, paper.maxY) } else { minY = max(minY, paper.minY) }

    let own = editingCover.map { origin.union($0) } ?? origin
    let others = neighbours(of: own, on: page)

    // Rộng trước, cao sau — hai giới hạn phụ thuộc nhau, cố định thứ tự để cú
    // kéo không dao động giữa hai đáp án.
    for other in others where overlaps(Self.span(minY, maxY), Self.span(other.minY, other.maxY)) {
      // Chỉ hàng xóm nằm **ngoài** block, về phía đang kéo, mới chặn được.
      //
      // Có lúc điều kiện này được nới thành "bắt đầu sau cạnh trái của ta", và
      // một block nằm ngay phía trên cùng lề trái lập tức kẹp bề rộng về 0 rồi
      // rơi xuống kích thước tối thiểu — kéo góc trên-phải là khung sập còn 24
      // điểm.
      if corner.movesLeftEdge {
        guard other.maxX <= own.minX + Self.blockGutter else { continue }
        minX = max(minX, other.maxX + Self.blockGutter)
      } else {
        guard other.minX >= own.maxX - Self.blockGutter else { continue }
        maxX = min(maxX, other.minX - Self.blockGutter)
      }
    }
    for other in others where overlaps(Self.span(minX, maxX), Self.span(other.minX, other.maxX)) {
      if corner.movesTopEdge {
        guard other.minY >= own.maxY - Self.blockGutter else { continue }
        maxY = min(maxY, other.minY - Self.blockGutter)
      } else {
        guard other.maxY <= own.minY + Self.blockGutter else { continue }
        minY = max(minY, other.maxY + Self.blockGutter)
      }
    }

    // Kích thước tối thiểu do cạnh đang kéo nhường, không phải cạnh neo.
    (minX, maxX) = Self.separated(minX, maxX, moving: corner.movesLeftEdge, by: minimumWidth)
    (minY, maxY) = Self.separated(minY, maxY, moving: !corner.movesTopEdge, by: Self.minimumBlockSize.height)

    let allowed = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    if allowed.width < proposed.width - 0.5 || allowed.height < proposed.height - 0.5 {
      logPdfEvent(
        "text_block_resize_clamped",
        "asked=\(proposed.integral.debugDescription) got=\(allowed.integral.debugDescription) "
          + "corner=\(corner)"
      )
    }
    return allowed
  }

  /// Bề rộng hẹp nhất block được phép có, theo cỡ chữ đang sửa.
  private var minimumWidth: CGFloat {
    max(Self.minimumBlockSize.width, CGFloat(editingStyle?.fontSize ?? 0) * Self.minimumWidthInEms)
  }

  /// Vùng này có đang nằm dưới ô nhập không.
  ///
  /// Một hàm cho cả hai chỗ cần biết — vẽ viền và vẽ xem trước. Trước đây mỗi
  /// chỗ tự viết, và chỗ vẽ xem trước quên mất, nên chữ bị vẽ chồng hai lần.
  private func isUnderField(_ rect: CGRect, pageIndex: Int) -> Bool {
    guard let style = editingStyle, Int(style.pageIndex) == pageIndex,
          let editing = editingOriginalBounds else { return false }
    return rect.intersects(editingCover.map { editing.union($0) } ?? editing)
  }

  /// Các block khác trên trang, trừ chính block đang sửa và chữ gốc dưới miếng vá.
  private func neighbours(of own: CGRect, on page: PDFPage) -> [CGRect] {
    guard let pdfView, let document = pdfView.document else { return [] }
    return blocks(on: page, pageIndex: document.index(for: page))
      .map { $0.occupied }
      .filter { Self.isDrawable($0) && !$0.intersects(own.insetBy(dx: -1, dy: -1)) }
  }

  /// Khung được phép dài xuống tới đâu, toạ độ trang.
  ///
  /// Cùng danh sách hàng xóm và cùng khe hở như lúc kéo nút, nên hai đường
  /// không thể lệch định nghĩa "chạm".
  private func typingFloor(for bounds: CGRect, on page: PDFPage) -> CGFloat {
    let own = editingCover.map { bounds.union($0) } ?? bounds
    var floor = page.bounds(for: .cropBox).minY
    for other in neighbours(of: own, on: page)
    where overlaps(Self.span(bounds.minX, bounds.maxX), Self.span(other.minX, other.maxX)) {
      guard other.maxY <= own.maxY else { continue }
      floor = max(floor, other.maxY + Self.blockGutter)
    }
    return floor
  }

  private func overlaps(_ lhs: ClosedRange<CGFloat>, _ rhs: ClosedRange<CGFloat>) -> Bool {
    min(lhs.upperBound, rhs.upperBound) - max(lhs.lowerBound, rhs.lowerBound) > 0
  }

  /// Dựng range từ hai biên theo thứ tự nào cũng được. `a...b` sẽ trap khi
  /// `a > b`, mà block bị hàng xóm ép mỏng hơn mức tối thiểu là chuyện thường.
  private static func span(_ a: CGFloat, _ b: CGFloat) -> ClosedRange<CGFloat> {
    min(a, b)...max(a, b)
  }

  /// Giữ hai biên cách nhau ít nhất `gap`, bên đang kéo là bên nhường.
  private static func separated(
    _ lower: CGFloat,
    _ upper: CGFloat,
    moving lowerMoves: Bool,
    by gap: CGFloat
  ) -> (CGFloat, CGFloat) {
    guard upper - lower < gap else { return (lower, upper) }
    return lowerMoves ? (upper - gap, upper) : (lower, lower + gap)
  }

  // MARK: - Finishing

  @objc private func commitEditing() {
    guard var request = editingStyle, let cover = editingCover else { return }
    // Đo tách pha. `apply` tự đo và ra 3ms, nên chỗ chậm — nếu có — nằm ở một
    // trong ba pha còn lại, và cả ba đều nằm ngoài nó.
    let started = CFAbsoluteTimeGetCurrent()
    var mark = started
    var timings: [String] = []
    func phase(_ name: String) {
      timings.append("\(name)=\(Self.since(mark))")
      mark = CFAbsoluteTimeGetCurrent()
    }

    request.text = editor.text ?? ""
    // Đọc trước khi `dismissEditor` xoá.
    let kern = editingKern
    // Lần giấu này được giữ: chữ mới sắp thế chỗ chữ cũ.
    editingHidOriginal = false
    dismissEditor()
    phase("dismiss")
    onCommit?(PdfTextEditCommit(request: request, cover: cover, kern: kern))
    phase("commit")
    onSelection?(nil)
    phase("notify")

    logPdfEvent(
      "text_edit_commit_phases",
      timings.joined(separator: " ") + " total=\(Self.since(started))ms"
    )
  }

  @objc private func deleteEditing() {
    guard var request = editingStyle, let cover = editingCover else { return }
    request.text = ""
    let kern = editingKern
    // Xoá chữ: chữ gốc phải ở nguyên trạng thái bị giấu.
    editingHidOriginal = false
    dismissEditor()
    onCommit?(PdfTextEditCommit(request: request, cover: cover, kern: kern))
    onSelection?(nil)
  }

  @objc private func cancelEditing() {
    dismissEditor()
    onSelection?(nil)
  }

  func dismissEditor() {
    // Đóng mà không commit thì phải trả chữ gốc về. Chỗ này chứ không phải
    // trong `cancelEditing`: nút Huỷ chỉ là một trong nhiều đường đóng — tap ra
    // ngoài, tap sang block khác, tắt chế độ sửa đều đi qua đây, và trước đây
    // ba đường đó để chữ gốc bị giấu vĩnh viễn mà không có gì thay thế.
    //
    // `commitEditing` tắt cờ trước khi gọi vào đây, vì lần giấu đó phải giữ.
    if editingHidOriginal {
      editingHidOriginal = false
      onRestoreOriginal?()
    }
    // Bàn phím tắt ở lượt runloop sau, không phải ngay đây.
    //
    // `resignFirstResponder` đo được **2717ms** trên máy thật. Nó chặn main
    // thread: UIKit trả first responder về cho tầng nhập liệu của Flutter, và
    // phiên nhập từ xa bị dựng lại — cùng thứ đẻ ra `RTIInputSystemClient ...
    // requires a valid sessionID` rải khắp log. Gọi đồng bộ ở đây nghĩa là bấm
    // Xong xong phải chờ gần ba giây mới thấy chữ mới, dù việc ghi chữ chỉ tốn
    // 6ms.
    //
    // Hoãn không làm nó nhanh hơn. Nhưng nó đổi thứ tự: chữ mới, viền, và bốn
    // nút xong hết trước, rồi bàn phím mới trượt xuống.
    //
    // Và nó bỏ hẳn được một lần, ở đường tốn nhất: chạm từ block này sang block
    // khác. `editor` là **một** text view dùng lại, nên ở đó buông first
    // responder rồi giành lại ngay là trả giá cho đúng cái mình vừa có.
    // `beginEditing` tăng token, và lần tắt đang chờ tự huỷ.
    keyboardDismissRequest += 1
    let dismissRequest = keyboardDismissRequest
    DispatchQueue.main.async { [weak self] in
      guard let self, self.keyboardDismissRequest == dismissRequest else { return }
      let resignStarted = CFAbsoluteTimeGetCurrent()
      self.editor.resignFirstResponder()
      logPdfEvent("text_edit_keyboard_dismissed", "in=\(Self.since(resignStarted))ms")
    }
    editor.isHidden = true
    // Trả về mặc định: ô nhập sau mở ra chưa chạm trần nào.
    editor.isScrollEnabled = false
    fieldBorder.isHidden = true
    fieldBorder.path = nil
    editor.text = ""
    for handle in resizeHandles.values { handle.isHidden = true }
    editingStyle = nil
    editingPage = nil
    editingBounds = nil
    editingOriginalBounds = nil
    editingCover = nil
    editingKern = 0
    editingFloor = nil
    editingTypography = nil
    editingHidOriginal = false
    editingFit = nil
    resizeStartBounds = nil
    refreshBlockOutlines()

    // Ô nhập đã đóng, việc đang chờ nó có thể chạy.
    if let pdfView, let document = pdfView.document,
       let page = pdfView.visiblePages.first(where: { blockCache[document.index(for: $0)] == nil }) {
      scheduleRead(of: page, pageIndex: document.index(for: page))
    }
  }

  // MARK: - Reading the style back off the page

  /// Point size and PostScript name of the run.
  ///
  /// `PDFSelection.attributedString` is the only place PDFKit exposes a run's
  /// font. It reports the font it *resolved* — a substitute when the document's
  /// own font is not embedded or not installed — so the size can be trusted
  /// further than the name. The name is dropped when it will not round-trip
  /// through `UIFont(name:size:)`, which is exactly the case where keeping it
  /// would silently produce a different typeface than the one named.
  private func measuredFont(of selection: PDFSelection, lineHeight: CGFloat) -> (name: String?, size: CGFloat) {
    let fallback = lineHeight * Self.fontSizeFromLineHeight

    guard let attributed = selection.attributedString, attributed.length > 0 else {
      return (nil, fallback)
    }

    // The first run's font, not an average: a line is usually one typeface, and
    // where it is not, the opening of the line is the better guess than a blend
    // of everything in it.
    var range = NSRange(location: 0, length: 0)
    let attributes = attributed.attributes(at: 0, effectiveRange: &range)
    guard let font = attributes[.font] as? UIFont else {
      return (nil, fallback)
    }

    let name = font.fontName
    let usable = UIFont(name: name, size: font.pointSize) != nil
    return (usable ? name : nil, font.pointSize > 1 ? font.pointSize : fallback)
  }

  private typealias ColourSample = (luma: CGFloat, r: CGFloat, g: CGFloat, b: CGFloat)

  /// Ink and paper colours of a run.
  ///
  /// Rendering rather than reading: a PDF's text colour lives in the content
  /// stream's graphics state, which PDFKit does not expose, and the background
  /// may be anything from plain paper to a table cell fill. The pixels already
  /// contain both answers.
  ///
  /// Which answer is which is settled by *majority*. Glyphs cover about a
  /// quarter of their own line box, so the background is simply the colour most
  /// of that box is — whatever colour that turns out to be. The ink is then
  /// whatever is *least like* the background just measured. Neither step asks
  /// which of the two is darker, and that is the point: ranking by brightness
  /// assumes dark text on light paper and comes out exactly inside out on a
  /// white heading in a red band, painting the cover in the colour of the
  /// letters.
  ///
  /// Glyph geometry looks like a better answer than a majority and is not:
  /// `PDFPage.characterBounds(at:)` reports a box of advance width by full line
  /// height, so in body copy the boxes of consecutive lines touch and tile the
  /// whole column — asking for the pixels *outside* every box returns nothing
  /// at all, even from a margin drawn around the line.
  private func sampledColours(of bounds: CGRect, on page: PDFPage) -> (ink: UIColor, paper: UIColor) {
    let defaults = (UIColor.black, UIColor.white)
    guard Self.isDrawable(bounds) else { return defaults }

    // Scaled off the line height rather than the long edge: the long edge is
    // how *wide* the run is, which says nothing about how thick its strokes
    // are, and stroke thickness is what has to be resolved. At a low sampling
    // scale a stroke is about a pixel wide, so every pixel of the glyph is a
    // blend of ink and paper and the measured colour comes out washed toward
    // the paper — text that should be black reads as grey, a saturated colour
    // reads as a pastel.
    let scale = min(
      max(Self.colourSampleLineHeight / bounds.height, Self.colourSampleScaleRange.lowerBound),
      Self.colourSampleScaleRange.upperBound
    )
    let size = CGSize(
      width: max((bounds.width * scale).rounded(), 1),
      height: max((bounds.height * scale).rounded(), 1)
    )

    guard let pixels = renderedPixels(of: bounds, on: page, size: size, scale: scale) else {
      logPdfEvent("colour_sample_failed", "reason=render bounds=\(bounds)")
      return defaults
    }

    // One pass into a fixed histogram. The colours are quantised to five bits a
    // channel and accumulated straight off the pixels: at full depth a flat
    // background is hundreds of near-identical values and nothing holds a
    // majority, and materialising the samples to sort them was the single
    // largest cost of a tap — a couple of hundred thousand tuples through a
    // comparison sort, to keep half a percent of them.
    var counts = [Int32](repeating: 0, count: Self.histogramBuckets)
    var sums = [Float](repeating: 0, count: Self.histogramBuckets * 3)
    var total = 0

    let pixelCount = pixels.count / 4
    let step = max(1, pixelCount / Self.colourSampleBudget)
    for pixel in Swift.stride(from: 0, to: pixelCount, by: step) {
      let index = pixel * 4
      let r = Float(pixels[index]) / 255
      let g = Float(pixels[index + 1]) / 255
      let b = Float(pixels[index + 2]) / 255
      let bucket = (Int(r * 31) << 10) | (Int(g * 31) << 5) | Int(b * 31)
      counts[bucket] += 1
      sums[bucket * 3] += r
      sums[bucket * 3 + 1] += g
      sums[bucket * 3 + 2] += b
      total += 1
    }
    guard total > 0 else {
      logPdfEvent("colour_sample_failed", "reason=no_pixels")
      return defaults
    }

    func sample(ofBucket bucket: Int) -> ColourSample {
      let count = CGFloat(counts[bucket])
      let r = CGFloat(sums[bucket * 3]) / count
      let g = CGFloat(sums[bucket * 3 + 1]) / count
      let b = CGFloat(sums[bucket * 3 + 2]) / count
      return (0.2126 * r + 0.7152 * g + 0.0722 * b, r, g, b)
    }

    // The paper is the colour most of the run is, whatever colour that is.
    var paperBucket = -1
    for bucket in 0..<Self.histogramBuckets
    where paperBucket < 0 || counts[bucket] > counts[paperBucket] {
      paperBucket = bucket
    }
    guard paperBucket >= 0, counts[paperBucket] > 0 else {
      logPdfEvent("colour_sample_failed", "reason=no_pixels")
      return defaults
    }
    let paper = sample(ofBucket: paperBucket)

    // The ink is the colour least like the paper — least like, not darkest,
    // which is what makes white letters on a red band come out the right way
    // round. Only colours with a real share of the pixels are eligible: a
    // stroke core is thousands of pixels, a speck of noise is not.
    let floor = Int32(max(Self.minimumInkSamples, Int(Double(total) * Self.inkPixelShare)))
    var inkBucket = -1
    var inkDistance: CGFloat = 0
    for bucket in 0..<Self.histogramBuckets where counts[bucket] >= floor {
      let distance = abs(sample(ofBucket: bucket).luma - paper.luma)
      if distance > inkDistance {
        inkDistance = distance
        inkBucket = bucket
      }
    }
    guard inkBucket >= 0 else {
      logPdfEvent("colour_sample_flat", "pixels=\(total) reason=no_ink")
      return defaults
    }
    let ink = sample(ofBucket: inkBucket)

    guard inkDistance > Self.minimumContrast else {
      // Not text on a background: the run probably crosses an image or a solid
      // fill, and inventing an ink colour from it would produce invisible text.
      logPdfEvent(
        "colour_sample_flat",
        "pixels=\(total) contrast=\(String(format: "%.3f", inkDistance)) "
          + "ink=\(Self.hex(colour(of: ink))) paper=\(Self.hex(colour(of: paper)))"
      )
      return defaults
    }

    logPdfEvent(
      "colour_sample",
      "pixels=\(total) step=\(step) "
        + "contrast=\(String(format: "%.3f", inkDistance)) "
        + "ink=\(Self.hex(colour(of: ink))) paper=\(Self.hex(colour(of: paper)))"
    )
    return (colour(of: ink), colour(of: paper))
  }

  /// Milliseconds since a mark, for the phase timings below.
  ///
  /// Kept in the shipped code rather than reached for when something is slow:
  /// what makes a tap or a commit expensive changes as the page does, and a
  /// number in the log costs nothing to read and everything to go without.
  private static func since(_ mark: CFAbsoluteTime) -> String {
    String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - mark) * 1000)
  }

  private static func hex(_ colour: UIColor) -> String {
    String(format: "%08llX", colour.argb)
  }

  /// The page over a rectangle, rendered and read back as pixels.
  private func renderedPixels(
    of bounds: CGRect,
    on page: PDFPage,
    size: CGSize,
    scale: CGFloat
  ) -> [UInt8]? {
    renderedPixels(of: bounds, size: size, scale: scale) { cg in
      if let sourcePage = page.pageRef {
        cg.drawPDFPage(sourcePage)
      } else {
        page.draw(with: .cropBox, to: cg)
      }
    }
  }

  /// A rectangle of page space, rendered into a bitmap and read back as pixels.
  ///
  /// `draw` runs with the context already transformed, so it works in page
  /// coordinates whether it is drawing the page or a line of type being
  /// measured against it.
  private func renderedPixels(
    of bounds: CGRect,
    size: CGSize,
    scale: CGFloat,
    draw: (CGContext) -> Void
  ) -> [UInt8]? {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    // Standard range, not extended: on a wide-gamut device the renderer would
    // otherwise hand back extended-sRGB components that get converted on the
    // way into the sampling bitmap — another conversion, another shift.
    format.preferredRange = .standard

    let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
      let cg = context.cgContext
      cg.setFillColor(UIColor.white.cgColor)
      cg.fill(CGRect(origin: .zero, size: size))
      // PDF user space has y pointing up; this puts the run's own rect over the
      // bitmap. Drawn raw, without `/Rotate`, to stay in the same unrotated
      // space the selection was measured in and the edit is applied in.
      cg.translateBy(x: 0, y: size.height)
      cg.scaleBy(x: scale, y: -scale)
      cg.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
      draw(cg)
    }

    guard let cgImage = image.cgImage else { return nil }
    let width = cgImage.width
    let height = cgImage.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
      data: &pixels,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      // sRGB throughout, not device RGB. The renderer above works in sRGB and
      // the colour goes back out through `UIColor(red:green:blue:)`, which is
      // also sRGB — a device-RGB stop in the middle is a conversion each way
      // and a visible shift on a saturated colour.
      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      return nil
    }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    return pixels
  }

  /// The most common colour in a population, averaged over the pixels that
  /// voted for it.
  ///
  /// Quantised to five bits a channel before counting: at full depth a flat
  /// background is still hundreds of near-identical values and nothing holds a
  /// majority. Five bits puts those in one bucket while keeping apart colours a
  /// person would call different. Averaging within the winning bucket gives
  /// back the precision the quantisation took away.
  private func dominant(_ samples: [ColourSample]) -> ColourSample? {
    guard !samples.isEmpty else { return nil }

    var buckets: [Int: (count: Int, r: CGFloat, g: CGFloat, b: CGFloat)] = [:]
    for sample in samples {
      let key = (Int(sample.r * 31) << 10) | (Int(sample.g * 31) << 5) | Int(sample.b * 31)
      var bucket = buckets[key] ?? (0, 0, 0, 0)
      bucket.count += 1
      bucket.r += sample.r
      bucket.g += sample.g
      bucket.b += sample.b
      buckets[key] = bucket
    }

    guard let winner = buckets.values.max(by: { $0.count < $1.count }) else { return nil }
    let count = CGFloat(winner.count)
    let r = winner.r / count
    let g = winner.g / count
    let b = winner.b / count
    return (0.2126 * r + 0.7152 * g + 0.0722 * b, r, g, b)
  }

  /// Tracking the page sets a line with: the difference between how wide the
  /// line actually is and how wide the font would set it, divided between the
  /// gaps between its characters.
  ///
  /// A PDF places every glyph itself and usually adds to the font's advances —
  /// `Tc`, `Tw`, a horizontal scale — none of which survives into
  /// `PDFSelection`. Without this the field's copy of a line ends short of the
  /// words underneath it, which reads as the text having changed the moment it
  /// was tapped.
  private func measuredKern(for text: String, font: UIFont, width: CGFloat) -> CGFloat {
    let string = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let gaps = CGFloat(string.count - 1)
    guard gaps >= 1, width > 1, font.pointSize > 1 else { return 0 }

    let natural = (string as NSString).size(withAttributes: [.font: font]).width
    guard natural > 1 else { return 0 }

    let kern = (width - natural) / gaps
    let bounds = Self.kernRange.lowerBound * font.pointSize...Self.kernRange.upperBound * font.pointSize
    return min(max(kern, bounds.lowerBound), bounds.upperBound)
  }

  /// Relative luminance of a colour, on the same scale the samples use.
  private func luma(of colour: UIColor) -> CGFloat {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    colour.getRed(&r, green: &g, blue: &b, alpha: &a)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b
  }

  private func colour(of sample: ColourSample) -> UIColor {
    UIColor(red: sample.r, green: sample.g, blue: sample.b, alpha: 1)
  }

  /// Sampling scale for a run of this height. Shared so a measurement taken on
  /// the page and the one it is compared against are made of the same pixels.
  /// Nền của một vùng, một pixel mỗi hàng, trên xuống dưới.
  ///
  /// Render vùng đó **nới rộng sang hai bên**, rồi mỗi hàng lấy trung bình các
  /// cột ở mép trái và mép phải. Chữ nằm giữa nên hai mép là nền thật.
  ///
  /// Nướng sẵn thành ảnh 1×N ngay tại đây: nền không đổi trong suốt lần sửa, và
  /// tính lại mỗi frame là trả tiền cho một thứ đứng yên.
  private func sampleScale(for height: CGFloat) -> CGFloat {
    min(
      max(Self.colourSampleLineHeight / max(height, 1), Self.colourSampleScaleRange.lowerBound),
      Self.colourSampleScaleRange.upperBound
    )
  }

  /// Where the ink above a run stops, in page coordinates.
  ///
  /// The line box PDFKit reports is font metrics, and a stacked Vietnamese mark
  /// on a capital clears it — so a cover fitted to that box leaves the tips of
  /// the marks showing above it. This asks the page instead: it renders the
  /// band just above the run and walks up it a row at a time, taking the
  /// highest row that has ink in it.
  ///
  /// Two things stop the walk. The band is never taller than
  /// `diacriticHeadroom`, and a row inked across `crowdedRowShare` of its width
  /// ends it — that is another line of type, not a mark on this one, and
  /// covering it would paint out a line nobody asked to edit. Blank rows are
  /// crossed: a mark sits above its letter with clear space between them.
  private func inkCeiling(
    above run: CGRect,
    on page: PDFPage,
    paperLuma: CGFloat,
    cut: CGFloat,
    limit: CGFloat
  ) -> CGFloat {
    guard limit > 0.5, Self.isDrawable(run) else { return run.maxY }

    let band = CGRect(x: run.minX, y: run.maxY, width: run.width, height: limit)
      .intersection(page.bounds(for: .cropBox))
    guard Self.isDrawable(band) else { return run.maxY }

    let scale = sampleScale(for: run.height)
    let size = CGSize(
      width: max((band.width * scale).rounded(), 1),
      height: max((band.height * scale).rounded(), 1)
    )
    guard let pixels = renderedPixels(of: band, on: page, size: size, scale: scale) else {
      return run.maxY
    }

    let width = Int(size.width)
    let height = Int(size.height)
    guard pixels.count >= width * height * 4 else { return run.maxY }

    var ceiling = run.maxY
    // Row 0 is the top of the band; the row next to the run is the last one, so
    // the walk runs backwards.
    for row in stride(from: height - 1, through: 0, by: -1) {
      var inked = 0
      for column in 0..<width {
        let index = (row * width + column) * 4
        let r = CGFloat(pixels[index]) / 255
        let g = CGFloat(pixels[index + 1]) / 255
        let b = CGFloat(pixels[index + 2]) / 255
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        if abs(luma - paperLuma) > cut { inked += 1 }
      }
      if Double(inked) / Double(width) > Self.crowdedRowShare { break }
      if inked > 0 {
        ceiling = band.maxY - CGFloat(row) / scale
      }
    }
    return max(ceiling, run.maxY)
  }

  /// The run's rectangle with its ceiling lifted to where the page's ink
  /// actually stops above it.
  private func raisedOverMarks(
    _ run: CGRect,
    on page: PDFPage,
    size: CGFloat,
    paperLuma: CGFloat,
    cut: CGFloat
  ) -> CGRect {
    let ceiling = inkCeiling(
      above: run,
      on: page,
      paperLuma: paperLuma,
      cut: cut,
      limit: size * Self.diacriticHeadroom
    )
    guard ceiling > run.maxY else { return run }
    logPdfEvent(
      "text_block_raised",
      "by=\(String(format: "%.1f", ceiling - run.maxY))pt size=\(String(format: "%.1f", size))"
    )
    return CGRect(x: run.minX, y: run.minY, width: run.width, height: ceiling - run.minY)
  }

  /// Area of ink in a rectangle, in square points.
  ///
  /// Ink is anything far enough from the paper colour, in either direction:
  /// white letters on a red band are as much ink as black ones on white.
  private func inkArea(
    in rect: CGRect,
    scale: CGFloat,
    paperLuma: CGFloat,
    cut: CGFloat,
    draw: (CGContext) -> Void
  ) -> Double? {
    guard Self.isDrawable(rect) else { return nil }
    let size = CGSize(
      width: max((rect.width * scale).rounded(), 1),
      height: max((rect.height * scale).rounded(), 1)
    )
    guard let pixels = renderedPixels(of: rect, size: size, scale: scale, draw: draw) else {
      return nil
    }

    var inked = 0
    for index in stride(from: 0, to: pixels.count, by: 4) {
      let r = CGFloat(pixels[index]) / 255
      let g = CGFloat(pixels[index + 1]) / 255
      let b = CGFloat(pixels[index + 2]) / 255
      let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
      if abs(luma - paperLuma) > cut { inked += 1 }
    }
    return Double(inked) / Double(scale * scale)
  }

  /// The font to set the replacement in.
  ///
  /// The page's own operators are believed over anything measured from it: `Tf`
  /// names the font that was asked for, where `PDFSelection` reports the one
  /// PDFKit resolved — a difference that costs the weight of every bold face a
  /// document does not embed. Two of them settle boldness outright: a render
  /// mode that strokes the glyphs as well as filling them is how a page makes
  /// bold out of a regular face, and `ForceBold` in the descriptor says the
  /// same in the font's own words.
  ///
  /// Each answer is taken only if it survives contact with the device — a name
  /// has to round-trip through `UIFont(name:size:)`, a size has to be within
  /// reach of the one measured off the glyphs — and where the stream says
  /// nothing at all, which is a scanned page or a stream this reader does not
  /// follow, everything falls back to the measurement it replaced.
  private func resolvedFont(
    measured: (name: String?, size: CGFloat),
    stream: PdfContentStreamReader.Attributes?,
    text: String,
    bounds: CGRect,
    on page: PDFPage,
    colours: () -> (ink: UIColor, paper: UIColor)
  ) -> (name: String?, size: CGFloat) {
    guard let stream else {
      // Không đọc được gì: lùi về so mật độ mực trang đặt xuống với mật độ mà
      // font được báo sẽ đặt. Đây là chỗ duy nhất cần tới pixel, nên `colours`
      // là closure — nhánh dưới không gọi thì không ai render gì cả.
      return weighted(measured, text: text, bounds: bounds, on: page, colours: colours())
    }

    // A size that disagrees wildly with the glyphs on the page is a text matrix
    // this reader followed wrong, not a document that means it.
    var size = measured.size
    if let stated = stream.fontSize, stated > 1 {
      let ratio = stated / max(measured.size, 0.01)
      if measured.size <= 1 || (0.5...2).contains(ratio) {
        size = stated
      }
    }

    var name = measured.name
    if let stated = stream.fontName, UIFont(name: stated, size: size) != nil {
      name = stated
    }

    let face = name.flatMap { UIFont(name: $0, size: size) } ?? UIFont.systemFont(ofSize: size)
    let alreadyBold = face.fontDescriptor.symbolicTraits.contains(.traitBold)
    guard stream.stroked || stream.forceBold, !alreadyBold,
          let descriptor = face.fontDescriptor.withSymbolicTraits(.traitBold) else {
      return (name, size)
    }

    let bold = UIFont(descriptor: descriptor, size: size)
    guard UIFont(name: bold.fontName, size: size) != nil else { return (name, size) }
    logPdfEvent(
      "text_weight_upgraded",
      "from=\(face.fontName) to=\(bold.fontName) "
        + "reason=\(stream.stroked ? "render_mode" : "force_bold")"
    )
    return (bold.fontName, size)
  }

  /// The measured font, set bold when the page's own ink is heavier than that
  /// font draws.
  ///
  /// `PDFSelection.attributedString` reports the font PDFKit *resolved*. For a
  /// bold face that is not embedded, that resolution loses the weight; for a
  /// heading "bolded" by stroking its glyphs there was never a bold font to
  /// find. Either way the reported name draws thinner than the page does, and
  /// the replacement comes out visibly lighter than what it replaced.
  ///
  /// So the page settles it. The same string is set in the reported font and
  /// the two areas of ink are compared — a bold face lays down about 40% more.
  /// Only ever an upgrade: nothing here can make a bold report thinner.
  private func weighted(
    _ font: (name: String?, size: CGFloat),
    text: String,
    bounds: CGRect,
    on page: PDFPage,
    colours: (ink: UIColor, paper: UIColor)
  ) -> (name: String?, size: CGFloat) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 2, font.size > 1, Self.isDrawable(bounds) else { return font }

    let candidate = font.name.flatMap { UIFont(name: $0, size: font.size) }
      ?? UIFont.systemFont(ofSize: font.size)
    guard !candidate.fontDescriptor.symbolicTraits.contains(.traitBold) else { return font }

    let paperLuma = luma(of: colours.paper)
    let cut = max(abs(paperLuma - luma(of: colours.ink)) / 2, 0.1)
    let scale = sampleScale(for: bounds.height)

    guard let pageInk = inkArea(
      in: bounds,
      scale: scale,
      paperLuma: paperLuma,
      cut: cut,
      draw: { cg in
        if let sourcePage = page.pageRef {
          cg.drawPDFPage(sourcePage)
        } else {
          page.draw(with: .cropBox, to: cg)
        }
      }
    ), pageInk > 0 else { return font }

    let attributed = NSAttributedString(
      string: trimmed,
      attributes: [.font: candidate, .foregroundColor: UIColor.black]
    )
    let line = CTLineCreateWithAttributedString(attributed)
    // Its own box, wide enough that nothing is clipped: the page may set the
    // same string looser or tighter than the font's own advances, and a clipped
    // comparison would read as extra weight.
    let box = CGRect(
      x: 0,
      y: 0,
      width: CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) + candidate.pointSize,
      height: max(bounds.height, candidate.lineHeight)
    )
    guard let candidateInk = inkArea(
      in: box,
      scale: scale,
      paperLuma: 1,
      cut: 0.5,
      draw: { cg in
        cg.textPosition = CGPoint(x: 0, y: box.height * 0.25)
        UIColor.black.setFill()
        CTLineDraw(line, cg)
      }
    ), candidateInk > 0 else { return font }

    let ratio = pageInk / candidateInk
    guard ratio > Self.boldInkRatio,
          let descriptor = candidate.fontDescriptor.withSymbolicTraits(.traitBold) else {
      return font
    }
    let bold = UIFont(descriptor: descriptor, size: font.size)
    guard UIFont(name: bold.fontName, size: font.size) != nil else { return font }

    logPdfEvent(
      "text_weight_upgraded",
      "from=\(candidate.fontName) to=\(bold.fontName) ratio=\(String(format: "%.2f", ratio))"
    )
    return (bold.fontName, font.size)
  }

  private func report(_ block: PdfTextBlock?) {
    if block == nil {
      // Chạm ra ngoài là bỏ, y như bấm Huỷ — nên chữ gốc đã giấu phải trả lại.
      // Không trả thì nó ở lại vô hình mà chẳng có chữ mới nào thay.
      if editingHidOriginal { onRestoreOriginal?() }
      dismissEditor()
      clearHighlight()
    }
    onSelection?(block)
  }

  private func highlight(_ bounds: CGRect, on page: PDFPage) {
    guard let pdfView else { return }
    let rect = pdfView.convert(bounds, from: page)
    let path = UIBezierPath(roundedRect: rect.insetBy(dx: -2, dy: -2), cornerRadius: 3)
    highlightLayer.frame = pdfView.bounds
    highlightLayer.path = path.cgPath
  }

  // MARK: - Applying

  /// The rectangle actually painted out for a run.
  ///
  /// Grown a hair past the run it hides: glyph antialiasing spills past the
  /// bounds PDFKit reports, and a patch fitted exactly to them leaves a grey
  /// ghost of the original line standing along its edges.
  ///
  /// One function because two callers have to agree on it — the field paints
  /// this live while the user types, and `apply(_:to:)` hands it to the cover
  /// annotation. When only the second grew the run, the ghost was there for
  /// the whole time the field was open and disappeared on commit, which read
  /// as the old text showing through whenever the block was being resized.
  private static func coverRect(for run: CGRect, in cropBox: CGRect) -> CGRect {
    run.insetBy(dx: -coverPadding, dy: -coverPadding).intersection(cropBox)
  }

  /// Covers the block, then lays the replacement over it. Two annotations, in
  /// that order.
  ///
  /// The cover is a filled rectangle in the paper colour measured off the block
  /// itself, so the run being replaced disappears into the page rather than
  /// under a white patch on tinted paper. The replacement is a free-text
  /// annotation — the same object the free-text tool produces, so one rendering
  /// path serves both and flattening on export bakes them in together.
  ///
  /// What this cannot do is *remove* the original glyphs. They are in the
  /// page's content stream, and taking them out means parsing and re-emitting
  /// that stream operator by operator, which PDFKit gives no help with. They
  /// stay under the cover: invisible, but still found by text search until the
  /// document is exported flattened.
  func apply(_ commit: PdfTextEditCommit, to page: PDFPage) throws {
    let started = CFAbsoluteTimeGetCurrent()
    let request = commit.request
    let index = Int(request.pageIndex)

    // Where the replacement is laid out — the box the handles size.
    let bounds = CGRect(
      x: request.bounds.x,
      y: request.bounds.y,
      width: request.bounds.width,
      height: request.bounds.height
    )
    let cropBox = page.bounds(for: .cropBox)

    // Vùng bị sơn: đúng chữ gốc, không hơn. Đã đo cả dấu lúc chọn block, ở đây
    // chỉ thêm biên cho khử răng cưa.
    let cover = Self.coverRect(for: commit.cover, in: cropBox)

    guard Self.isDrawable(cover), Self.isDrawable(bounds),
          cover.width > 1, cover.height > 1 else {
      throw PdfPocError(
        code: "invalid_text_edit_bounds",
        message: "The text block does not intersect the page.",
        details: "bounds=\(bounds), cropBox=\(cropBox)"
      )
    }

    let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let size = CGFloat(request.fontSize)
    // Kiểm lại theo chữ thật sự gõ: block toàn ASCII giữ font dựng sẵn lúc chọn,
    // mà chữ thay thế có thể là tiếng Việt đầu tiên trên trang.
    let font = embeddable(
      request.fontName.flatMap { UIFont(name: $0, size: size) }
        ?? UIFont.systemFont(ofSize: size),
      for: text
    )
    let ink = UIColor(argb: request.textColor.argb)

    // Khung nở ra bằng đúng chỗ chữ chiếm.
    //
    // Lúc gõ chỉ `editor.frame` cao lên, `editingBounds` đứng yên — nên nếu lưu
    // nguyên `bounds` thì nét đứt vẽ theo khung cũ còn viền lúc tap lại chạy
    // tới đáy chữ, và hai cái lệch nhau. Đo bằng đúng bộ thuộc tính sẽ dùng để
    // vẽ, ở đơn vị trang, rồi kẹp ở trần hàng xóm y như lúc gõ.
    let floor = typingFloor(for: bounds, on: page)
    let textHeight = text.isEmpty ? 0 : NSAttributedString(
      string: text,
      attributes: PdfTextOverlay.attributes(font: font, colour: ink, kern: commit.kern)
    ).boundingRect(
      with: CGSize(width: bounds.width, height: PdfTextOverlay.unboundedHeight),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil
    ).height.rounded(.up)

    let ceiling = max(bounds.maxY - floor, bounds.height)
    let height = min(max(bounds.height, textHeight), ceiling)
    let occupied = CGRect(
      x: bounds.minX,
      y: bounds.maxY - height,
      width: bounds.width,
      height: height
    )

    // Giữ cả khi chữ rỗng — đó là một lần xoá. Nó mang miếng vá, và là thứ báo
    // cho cú chạm sau biết chỗ này đã xử lý rồi.
    let edit = CommittedEdit(
      page: page,
      cover: cover,
      bounds: occupied,
      text: text,
      font: font,
      ink: ink,
      kern: commit.kern,
      // Bằng đúng chiều cao khung: khung đã nở theo chữ nên lưới cắt chỉ còn
      // việc gì khi khung bị kéo nhỏ lại sau đó.
      maxHeight: height
    )

    // Lần sửa trước của block này bị thay, không chồng lên.
    committedEdits.removeAll { $0.page === page && $0.occupied.intersects(edit.occupied) }
    committedEdits.append(edit)

    // Sửa cache chứ không xoá: xoá là lần vẽ viền sau phải đọc lại chữ cả trang
    // qua PDFKit, thứ chậm nhất lớp này làm — mà chỉ đúng một block vừa đổi.
    if var cached = blockCache[index] {
      cached.removeAll { $0.occupied.intersects(edit.occupied) }
      cached.append(
        TextBlock(
          bounds: occupied,
          text: text,
          lines: [],
          edit: edit,
          cover: cover
        )
      )
      blockCache[index] = cached
    }

    refreshEditPreview()
    refreshBlockOutlines()

    logPdfEvent(
      text.isEmpty ? "text_edit_delete" : "text_edit_apply",
      "pageIndex=\(request.pageIndex) length=\(text.count) "
        + "font=\(font.fontName) size=\(request.fontSize) kern=\(String(format: "%.2f", commit.kern)) "
        + "cover=\(cover.integral.debugDescription) bounds=\(occupied.integral.debugDescription) "
        + "pending=\(committedEdits.count) | total=\(Self.since(started))ms"
    )
  }

  /// Vẽ lại các chỉnh sửa đã commit lên trang.
  ///
  /// Vẽ chứ không thêm vào document — đây là thứ thay cho hai annotation cũ.
  /// Không có gì được ghi cho tới `save()`, và `save()` dùng đúng
  /// `PdfTextOverlay.draw` đang vẽ ở đây.
  private func refreshEditPreview() {
    guard let pdfView else { return }
    if editPreview.superview == nil {
      // Phải nằm trên scroll view của `PDFView` — đặt dưới là sơn chui xuống
      // dưới tờ giấy. Thêm một lần, không bao giờ đưa lên trước lần nữa, để nó
      // ở dưới ô nhập và bốn nút.
      pdfView.addSubview(editPreview)
      // Cùng cái bẫy, thấp hơn một tầng: miếng vá của edit đã commit che mất
      // viền block, nên nâng viền lên trên nó.
      pdfView.layer.addSublayer(blockLayer)
      pdfView.layer.addSublayer(highlightLayer)
      editPreview.render = { [weak self] context, bounds in
        self?.drawCommittedEdits(into: context, bounds: bounds)
      }
    }
    // Khung bằng đúng chỗ các chỉnh sửa đang chiếm trên màn hình, không phải cả
    // màn hình.
    //
    // `refreshBlockOutlines` gọi hàm này qua KVO trên `contentOffset`, tức là
    // **mỗi frame cuộn**. Trước lần commit đầu tiên thì lớp này ẩn nên không tốn
    // gì; ngay sau đó nó hiện, và một khung cỡ màn hình nghĩa là mỗi frame cấp
    // phát rồi sơn lại một bitmap cả màn hình để vẽ vài dòng chữ. Đó là lý do
    // tài liệu chỉ bắt đầu ì sau khi sửa xong block đầu tiên.
    let area = previewArea()
    editPreview.isHidden = area == nil
    guard let area else {
      editPreview.frame = .zero
      return
    }
    editPreview.frame = area
    editPreview.setNeedsDisplay()
  }

  /// Vùng màn hình mà các chỉnh sửa đã commit đang chiếm. Nil khi không có gì
  /// để vẽ.
  private func previewArea() -> CGRect? {
    guard let pdfView, let document = pdfView.document, !committedEdits.isEmpty else {
      return nil
    }

    var area: CGRect?
    for page in pdfView.visiblePages {
      let index = document.index(for: page)
      for edit in committedEdits where edit.page === page {
        guard !edit.text.isEmpty, !isUnderField(edit.occupied, pageIndex: index) else { continue }
        let box = pdfView.convert(edit.bounds, from: page)
        guard Self.isDrawable(box) else { continue }
        // Nới ra một chút: chữ có thể tràn khỏi hộp bố cục của nó — dấu thanh ở
        // trên, phần đuôi chữ ở dưới — và `draw` chỉ kẹp theo `maxHeight`.
        let padded = box.insetBy(dx: -4, dy: -4)
        area = area.map { $0.union(padded) } ?? padded
      }
    }

    guard let area else { return nil }
    let visible = area.intersection(pdfView.bounds)
    return Self.isDrawable(visible) ? visible : nil
  }

  /// Vẽ từng chỉnh sửa đang chờ: miếng vá trước, chữ sau.
  private func drawCommittedEdits(into context: CGContext, bounds: CGRect) {
    guard let pdfView, let document = pdfView.document else { return }

    // Mọi toạ độ dưới đây là toạ độ của `pdfView`, còn context này gốc ở góc
    // trên-trái của `editPreview`. Dời một lần cho cả lượt vẽ.
    let origin = editPreview.frame.origin
    context.saveGState()
    defer { context.restoreGState() }
    context.translateBy(x: -origin.x, y: -origin.y)

    for page in pdfView.visiblePages {
      let index = document.index(for: page)
      for edit in committedEdits where edit.page === page {
        // Chỉnh sửa đang mở ô nhập thì để ô nhập vẽ. Không bỏ qua thì chữ hiện
        // hai lần: một bản đứng ở chỗ lần sửa trước, một bản chạy theo tay khi
        // đang kéo.
        if isUnderField(edit.occupied, pageIndex: index) { continue }
        // Không sơn gì cả: chữ gốc đã bị `3 Tr` giấu trong tài liệu, nền dưới
        // đó là nền thật và không ai được đụng vào.
        guard !edit.text.isEmpty else { continue }
        let box = pdfView.convert(edit.bounds, from: page)
        guard Self.isDrawable(box) else { continue }
        let zoom = box.height / max(edit.bounds.height, 0.01)
        guard zoom.isFinite, zoom > 0 else { continue }

        // Đưa thẳng, không biến đổi: `draw` đọc rect kiểu view (`minY` là cạnh
        // trên), đúng hệ toạ độ context này đang có.
        PdfTextOverlay.draw(
          PdfTextOverlay.Request(
            pageIndex: index,
            bounds: box,
            text: edit.text,
            font: edit.font.withSize(max(edit.font.pointSize * zoom, 1)),
            colour: edit.ink,
            kern: edit.kern * zoom,
            maxHeight: edit.maxHeight * zoom
          ),
          into: context
        )
      }
    }
  }


  /// `/NM` is meant to be unique on its page, so each annotation gets its own
  /// while still starting with the prefix that says whose it is.

  // MARK: - UITextViewDelegate

  func textViewDidChange(_ textView: UITextView) {
    // Grows with what is typed so long replacements stay readable while being
    // written, rather than scrolling inside a one-line box.
    //
    // Đo, vì đây là đường duy nhất chạy mỗi phím. Chỉ ghi log khi vượt ngưỡng —
    // mỗi phím một dòng log còn tốn hơn thứ nó đo.
    let started = CFAbsoluteTimeGetCurrent()
    layoutEditingViews()
    guard CFAbsoluteTimeGetCurrent() - started > Self.keystrokeBudget else { return }
    logPdfEvent(
      "text_edit_keystroke_slow",
      "length=\(textView.text?.count ?? 0) in=\(Self.since(started))ms"
    )
  }

  // MARK: - UIGestureRecognizerDelegate

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
  ) -> Bool {
    // Coexists with the scroll view's own gestures: tapping to pick must not
    // cost the user panning and zooming the page.
    true
  }
}

/// Lớp trong suốt phủ lên trang, vẽ bất cứ thứ gì được giao.
///
/// Là view chứ không phải `CAShapeLayer` vì thứ vẽ lên là glyph, cần graphics
/// context. Không nhận chạm: block bên dưới vẫn phải bấm được.
private final class EditPreviewView: UIView {
  var render: ((CGContext, CGRect) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    isUserInteractionEnabled = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("not used") }

  override func draw(_ rect: CGRect) {
    guard let context = UIGraphicsGetCurrentContext() else { return }
    render?(context, bounds)
  }
}
