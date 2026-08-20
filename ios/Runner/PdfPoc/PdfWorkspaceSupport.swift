import PDFKit
import UIKit

/// Finds a view controller that can present a system picker. Conversion runs
/// without an attached workspace view, so presentation falls back to the key
/// window when no responder chain is available.
func pocPresentingViewController(from view: UIView? = nil) -> UIViewController? {
  var responder: UIResponder? = view
  while let current = responder {
    if let viewController = current as? UIViewController {
      return pocVisibleViewController(from: viewController)
    }
    responder = current.next
  }
  let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
  let root = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
  return pocVisibleViewController(from: root)
}

func pocVisibleViewController(from viewController: UIViewController?) -> UIViewController? {
  if let navigationController = viewController as? UINavigationController {
    return pocVisibleViewController(from: navigationController.visibleViewController)
  }
  if let tabController = viewController as? UITabBarController {
    return pocVisibleViewController(from: tabController.selectedViewController)
  }
  if let presented = viewController?.presentedViewController {
    return pocVisibleViewController(from: presented)
  }
  return viewController
}

final class PocPdfView: PDFView {
  override var canBecomeFirstResponder: Bool {
    true
  }

  override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
    if hasTextSelection {
      return false
    }
    return super.canPerformAction(action, withSender: sender)
  }

  func suppressSystemSelectionMenu() {
    _ = becomeFirstResponder()
    UIMenuController.shared.hideMenu()
    UIMenuSystem.main.setNeedsRebuild()
  }

  private var hasTextSelection: Bool {
    guard let text = currentSelection?.string else {
      return false
    }
    return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

final class PdfSelectionToolbar: UIView {
  var onCopy: (() -> Void)?
  var onMarkup: ((PdfMarkupType) -> Void)?

  private let stackView = UIStackView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    configure()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configure()
  }

  private func configure() {
    // Sized before anything is pinned inside it. A view built at zero and then
    // asked to hold a stack view with six-point margins is a set of constraints
    // that cannot all hold, which UIKit logs at length and then breaks one of
    // — and the layout it settles on passes negative widths to CoreGraphics.
    if bounds.isEmpty {
      frame = CGRect(x: 0, y: 0, width: 320, height: 44)
    }

    backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.98)
    layer.cornerRadius = 12
    layer.borderColor = UIColor.separator.cgColor
    layer.borderWidth = 1
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = 0.18
    layer.shadowRadius = 10
    layer.shadowOffset = CGSize(width: 0, height: 4)

    stackView.axis = .horizontal
    stackView.alignment = .center
    stackView.distribution = .fill
    stackView.spacing = 4
    stackView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stackView)

    NSLayoutConstraint.activate([
      stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
      stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      stackView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
      stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
    ])

    addButton(title: "Copy", action: #selector(copyTapped))
    addDivider()
    addButton(title: "Highlight", action: #selector(highlightTapped))
    addButton(title: "Underline", action: #selector(underlineTapped))
    addButton(title: "Strikeout", action: #selector(strikeoutTapped))
  }

  private func addButton(title: String, action: Selector) {
    let button = UIButton(type: .system)
    button.setTitle(title, for: .normal)
    button.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
    button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
    button.addTarget(self, action: action, for: .touchUpInside)
    stackView.addArrangedSubview(button)
  }

  private func addDivider() {
    let divider = UIView()
    divider.backgroundColor = .separator
    divider.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      divider.widthAnchor.constraint(equalToConstant: 1),
      divider.heightAnchor.constraint(equalToConstant: 22),
    ])
    stackView.addArrangedSubview(divider)
  }

  @objc private func copyTapped() {
    onCopy?()
  }

  @objc private func highlightTapped() {
    onMarkup?(.highlight)
  }

  @objc private func underlineTapped() {
    onMarkup?(.underline)
  }

  @objc private func strikeoutTapped() {
    onMarkup?(.strikeout)
  }
}

final class PdfDocumentSession {
  let assetKey: String
  let workingURL: URL
  let document: PDFDocument
  var isDirty: Bool

  init(assetKey: String, workingURL: URL, document: PDFDocument, isDirty: Bool = false) {
    self.assetKey = assetKey
    self.workingURL = workingURL
    self.document = document
    self.isDirty = isDirty
  }
}

extension UIColor {
  convenience init(argb: Int64) {
    let alpha = CGFloat((argb >> 24) & 0xFF) / 255.0
    let red = CGFloat((argb >> 16) & 0xFF) / 255.0
    let green = CGFloat((argb >> 8) & 0xFF) / 255.0
    let blue = CGFloat(argb & 0xFF) / 255.0
    self.init(red: red, green: green, blue: blue, alpha: alpha)
  }

  /// The inverse, for colours measured on the page rather than chosen in
  /// Flutter. Components are read in the device RGB space the sampler works in.
  var argb: Int64 {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
      return Int64(bitPattern: 0xFF00_0000)
    }
    func byte(_ value: CGFloat) -> Int64 { Int64(min(max(value, 0), 1) * 255) }
    return byte(alpha) << 24 | byte(red) << 16 | byte(green) << 8 | byte(blue)
  }
}
