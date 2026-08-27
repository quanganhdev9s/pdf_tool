import UIKit
import WebKit

/// Bỏ thanh phụ trợ bàn phím (`‹ › Done`) mà iOS gắn vào `WKWebView`.
///
/// Nó xuất hiện khi ô nhập ẩn của trình soạn thảo nhận focus, và gây hai chuyện:
/// đổ một khối cảnh báo `NSLayoutConstraint` mỗi lần bàn phím lên (nó được bố
/// cục khi bề rộng còn bằng 0), và chiếm một chiều cao mà cả native lẫn Flutter
/// đều không đo nên con trỏ có thể nằm dưới nó. Thanh này cũng thừa: nút bấm đã
/// ở thanh công cụ Flutter, còn `‹ ›` để nhảy giữa các ô biểu mẫu mà trang vỏ
/// chỉ có một ô.
///
/// `WKWebView` không có API công khai để tắt, nên phải đổi lớp của `WKContentView`
/// — **lớp riêng tư của WebKit** — sang một lớp con sinh lúc chạy. Không gọi
/// selector riêng tư nào, nhưng có dựa vào cấu trúc view bên trong WebKit: nếu
/// Apple đổi, mọi nhánh ở đây đều thoát an toàn và thanh phụ trợ quay lại.
extension WKWebView {
  /// Gọi được nhiều lần; lần sau là lệnh rỗng.
  func removeInputAccessoryView() {
    // View nhận bàn phím là con của scroll view, tên lớp bắt đầu bằng "WKContent".
    guard let target = scrollView.subviews.first(where: {
      String(describing: type(of: $0)).hasPrefix("WKContent")
    }) else {
      return
    }

    let targetClass: AnyClass = type(of: target)
    let subclassName = "\(NSStringFromClass(targetClass))_NoInputAccessory"

    // Đã đổi rồi thì thôi.
    if NSStringFromClass(targetClass).hasSuffix("_NoInputAccessory") {
      return
    }

    let makeSubclass: () -> AnyClass? = {
        guard let created = objc_allocateClassPair(targetClass, subclassName, 0) else {
          return nil
        }
        let selector = #selector(getter: UIResponder.inputAccessoryView)
        guard let method = class_getInstanceMethod(UIResponder.self, selector) else {
          objc_disposeClassPair(created)
          return nil
        }
        let empty: @convention(block) (AnyObject) -> UIView? = { _ in nil }
        class_addMethod(
          created,
          selector,
          imp_implementationWithBlock(empty),
          method_getTypeEncoding(method)
        )
        objc_registerClassPair(created)
        return created
    }
    let subclass: AnyClass = NSClassFromString(subclassName) ?? makeSubclass() ?? targetClass

    // Không đổi được thì để nguyên — thà còn thanh phụ trợ hơn là hỏng ô nhập.
    if subclass !== targetClass {
      object_setClass(target, subclass)
    }
  }
}
