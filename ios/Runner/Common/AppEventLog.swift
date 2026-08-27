import Foundation
import QuartzCore

// Dùng chung cho mọi phần của app — PDF, HWP, quét. Đặt ở `Common` chứ không
// nằm trong `PdfPoc` vì một dòng log duy nhất là thứ để đọc cả lượt mở tệp:
// tách log theo module là mất đúng cái nhìn đó.
let pdfEventTag = "PDF Event"

/// Trục thời gian của một lượt mở tệp. Mốc 0 là lúc chọn xong tệp, và mọi dòng
/// log của native tự đóng dấu `t=` theo nó. Chỉ chạm từ luồng chính.
enum PdfEventClock {
  private static var origin: CFTimeInterval = 0

  static func start() {
    origin = CACurrentMediaTime()
  }

  static var elapsedMs: Int? {
    guard origin > 0 else { return nil }
    return Int(((CACurrentMediaTime() - origin) * 1000).rounded())
  }

  static func stop() {
    origin = 0
  }
}

func logPdfEvent(_ event: String, _ details: String? = nil) {
  let suffix = details.map { " | \($0)" } ?? ""
  let stamp = PdfEventClock.elapsedMs.map { " | t=\($0)ms" } ?? ""
  print("\(pdfEventTag) | native | \(event)\(suffix)\(stamp)")
}
