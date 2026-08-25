class HwpDirectCaret {
  const HwpDirectCaret({
    required this.pageIndex,
    required this.sectionIndex,
    required this.paragraphIndex,
    required this.charOffset,
    required this.x,
    required this.y,
    required this.height,
  });

  final int pageIndex;
  final int sectionIndex;
  final int paragraphIndex;
  final int charOffset;
  final double x;
  final double y;
  final double height;

  HwpDirectCaret copyWith({
    int? pageIndex,
    int? sectionIndex,
    int? paragraphIndex,
    int? charOffset,
    double? x,
    double? y,
    double? height,
  }) {
    return HwpDirectCaret(
      pageIndex: pageIndex ?? this.pageIndex,
      sectionIndex: sectionIndex ?? this.sectionIndex,
      paragraphIndex: paragraphIndex ?? this.paragraphIndex,
      charOffset: charOffset ?? this.charOffset,
      x: x ?? this.x,
      y: y ?? this.y,
      height: height ?? this.height,
    );
  }
}
