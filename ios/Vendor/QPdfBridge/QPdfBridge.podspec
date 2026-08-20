#
# An Objective-C++ bridge over qpdf, vendored as a local pod so that adding it
# costs no edits to project.pbxproj and the C++ build settings stay scoped to
# this target instead of leaking into Runner.
#
# qpdf itself ships as a prebuilt static xcframework produced by
# tools/build_qpdf.sh. It is checked in deliberately: building it takes several
# minutes and needs CMake, and neither belongs in the path of a normal
# `flutter run`.
#
Pod::Spec.new do |s|
  s.name             = 'QPdfBridge'
  s.version          = '0.1.0'
  s.summary          = 'Content-stream level PDF text removal, backed by qpdf.'
  s.description      = <<~DESC
    PDFKit can add annotations but cannot rewrite the operators a page is drawn
    from, so text "edited" through PDFKit alone is only covered over and stays
    in the file. This pod wraps qpdf to delete the text-showing operators
    themselves.
  DESC
  s.homepage         = 'https://github.com/qpdf/qpdf'
  s.license          = { :type => 'Apache-2.0', :file => 'LICENSE-qpdf.txt' }
  s.author           = { 'pdf_tool' => 'dthinh.1024@gmail.com' }
  s.source           = { :path => '.' }

  s.platform         = :ios, '15.0'
  s.requires_arc     = true

  s.source_files        = 'Sources/QPdfBridge/**/*.{h,mm}'
  s.public_header_files = 'Sources/QPdfBridge/include/*.h'
  s.vendored_frameworks = 'qpdf.xcframework'

  # zlib comes from the SDK; qpdf was configured to link it rather than vendor
  # its own copy. libjpeg is already inside the xcframework.
  s.libraries = 'z'

  # Built as a static framework so the C++ runtime and qpdf's symbols are
  # resolved at link time into Runner rather than shipped as a second dylib.
  s.static_framework = true

  s.pod_target_xcconfig = {
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20',
    'CLANG_CXX_LIBRARY'           => 'libc++',
    'DEFINES_MODULE'              => 'YES',
    # qpdf's headers are C++ and must never end up in the Swift module map.
    'EXCLUDED_HEADERS'            => '*.hh',
  }

  s.user_target_xcconfig = {
    'OTHER_LDFLAGS' => '-lc++',
  }
end
