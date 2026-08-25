import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../pdf_poc_api.g.dart';
import '../bloc/pdf_viewer_bloc.dart';
import '../widgets/hwp_editor_tool_bar.dart';
import '../widgets/hwp_page_bar.dart';

enum _ViewerMenuAction { search, details, share }

/// Đuôi tệp mà trình soạn thảo HWP nhận. Khớp với `HwpFileType` bên native.
const Set<String> _editableExtensions = <String>{'hwp', 'hwpx'};

/// Hosts the native document viewer inside a normal Flutter route, so the whole
/// screen around the document is ours to style: app bar, menu, search bar.
///
/// The native side only renders; every control here is Flutter.
class DocumentViewerPage extends StatefulWidget {
  const DocumentViewerPage({super.key, required this.document});

  final PdfViewableDocument document;

  @override
  State<DocumentViewerPage> createState() => _DocumentViewerPageState();
}

class _DocumentViewerPageState extends State<DocumentViewerPage> {
  // Captured while the element tree is still stable: `dispose` runs after this
  // widget is deactivated, when ancestor lookups are no longer allowed.
  PdfViewerBloc? _bloc;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  bool _showDetails = false;
  bool _searching = false;
  bool? _lastSearchFound;
  bool _editing = false;
  bool _busy = false;

  /// Đo chiều cao thật của thanh công cụ thay vì đoán: nó đổi theo vùng an
  /// toàn của máy, và khi đang lưu thì có thêm thanh tiến trình.
  final GlobalKey _toolBarKey = GlobalKey();

  /// Số đã báo xuống native lần gần nhất, để không bắn lại cùng một giá trị.
  double _reportedChromeInset = -1;

  /// Tệp này có sửa được không. Chỉ HWP — mọi định dạng khác chỉ xem.
  bool get _editable => _editableExtensions.contains(
    widget.document.fileName.split('.').last.toLowerCase(),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bloc = context.read<PdfViewerBloc>();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    _bloc?.add(const PdfViewerCloseDocumentViewerRequested());
    super.dispose();
  }

  /// Báo xuống native phần đáy web view mà Flutter đang che.
  ///
  /// Chiều cao thanh công cụ chỉ đo được sau khi bố cục xong, nên phải đợi hết
  /// khung hình. Không báo lại khi số không đổi — bàn phím trượt lên là hàng
  /// chục lần dựng khung hình liên tiếp.
  void _syncChromeInset() {
    if (!mounted) return;
    final box = _toolBarKey.currentContext?.findRenderObject() as RenderBox?;
    final inset = _editing && box != null && box.hasSize
        ? box.size.height
        : 0.0;
    if ((inset - _reportedChromeInset).abs() < 0.5) return;
    _reportedChromeInset = inset;
    _bloc?.setViewerChromeInset(inset);
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncChromeInset());
    return BlocBuilder<PdfViewerBloc, PdfViewerState>(
      buildWhen: (previous, current) => previous.hwpEditor != current.hwpEditor,
      builder: (context, state) {
        final editor = state.hwpEditor;
        return Scaffold(
          // Đừng co màn hình khi bàn phím lên.
          //
          // Co Scaffold là co `UiKitView`, tức là co cả `WKWebView` bên trong,
          // và mọi toạ độ chạm mà trình soạn thảo đã đo sẽ lệch đi — con trỏ
          // trông như đứng yên một chỗ.
          //
          // Cái giá của nó là đáy màn hình cũng đứng yên, nên thanh công cụ
          // phải tự nâng (xem `body` bên dưới) và con trỏ phải tự tránh: native
          // đo bàn phím, Flutter báo chiều cao thanh công cụ, trang vỏ cộng hai
          // số đó rồi cuộn.
          //
          // Màn PDF cũng đặt như vậy, cùng một lý do.
          resizeToAvoidBottomInset: false,
          appBar: _searching
              ? _buildSearchAppBar()
              : _buildDefaultAppBar(editor),
          // Thanh công cụ **nổi** trên web view, không phải `bottomNavigationBar`.
          // Đáy Scaffold không nhúc nhích khi bàn phím lên, nên đặt ở đó là bị
          // bàn phím phủ mất. Ở đây nó tự nâng theo `viewInsets`.
          body: Stack(
            children: <Widget>[
              Column(
                children: <Widget>[
                  if (_showDetails) _DetailsBar(document: widget.document),
                  // Chỉ tài liệu HWP mới dựng từng trang một; PDF vẫn cuộn liên
                  // tục nên không có gì để lật ở đây.
                  if (_editable)
                    HwpPageBar(
                      state: editor,
                      onGoToPage: (page) => _bloc?.hwpGoToPage(page),
                    ),
                  Expanded(
                    child: _NativeDocumentViewer(path: widget.document.path),
                  ),
                ],
              ),
              if (_editing)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: MediaQuery.of(context).viewInsets.bottom,
                  child: HwpEditorToolBar(
                    key: _toolBarKey,
                    state: editor,
                    busy: _busy,
                    onCharFormat: (format) => _bloc?.applyHwpCharFormat(format),
                    onParaFormat: (format) => _bloc?.applyHwpParaFormat(format),
                    onUndo: () => _bloc?.hwpUndo(),
                    onRedo: () => _bloc?.hwpRedo(),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  PreferredSizeWidget _buildDefaultAppBar(HwpEditorState? editor) {
    final dirty = editor?.dirty ?? false;
    return AppBar(
      title: Text(
        dirty ? '${widget.document.fileName} •' : widget.document.fileName,
        overflow: TextOverflow.ellipsis,
      ),
      actions: <Widget>[
        if (_editable && _editing) ...<Widget>[
          IconButton(
            tooltip: 'Lưu',
            onPressed: _busy || !dirty ? null : _saveEdits,
            icon: const Icon(Icons.save_outlined),
          ),
          TextButton(
            onPressed: _busy ? null : () => _leaveEditing(dirty),
            child: const Text('Xong'),
          ),
        ] else if (_editable)
          IconButton(
            tooltip: 'Sửa',
            onPressed: _busy ? null : () => _setEditing(true),
            icon: const Icon(Icons.edit_outlined),
          ),
        PopupMenuButton<_ViewerMenuAction>(
          tooltip: 'Options',
          icon: const Icon(Icons.more_vert),
          onSelected: _handleMenuAction,
          itemBuilder: (context) => <PopupMenuEntry<_ViewerMenuAction>>[
            const PopupMenuItem<_ViewerMenuAction>(
              value: _ViewerMenuAction.search,
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.search),
                title: Text('Search'),
              ),
            ),
            PopupMenuItem<_ViewerMenuAction>(
              value: _ViewerMenuAction.details,
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(_showDetails ? Icons.info : Icons.info_outline),
                title: Text(_showDetails ? 'Hide details' : 'File details'),
              ),
            ),
            const PopupMenuItem<_ViewerMenuAction>(
              value: _ViewerMenuAction.share,
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.ios_share),
                title: Text('Share'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  PreferredSizeWidget _buildSearchAppBar() {
    return AppBar(
      leading: IconButton(
        tooltip: 'Close search',
        icon: const Icon(Icons.arrow_back),
        onPressed: _stopSearching,
      ),
      titleSpacing: 0,
      title: TextField(
        controller: _searchController,
        focusNode: _searchFocusNode,
        autofocus: true,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Search in document',
          border: InputBorder.none,
          errorText: _lastSearchFound == false ? 'No match' : null,
        ),
        onSubmitted: (_) => _find(forward: true),
      ),
      actions: <Widget>[
        IconButton(
          tooltip: 'Previous match',
          icon: const Icon(Icons.keyboard_arrow_up),
          onPressed: () => _find(forward: false),
        ),
        IconButton(
          tooltip: 'Next match',
          icon: const Icon(Icons.keyboard_arrow_down),
          onPressed: () => _find(forward: true),
        ),
      ],
    );
  }

  void _handleMenuAction(_ViewerMenuAction action) {
    switch (action) {
      case _ViewerMenuAction.search:
        setState(() => _searching = true);
      case _ViewerMenuAction.details:
        setState(() => _showDetails = !_showDetails);
      case _ViewerMenuAction.share:
        _bloc?.shareViewerDocument();
    }
  }

  Future<void> _setEditing(bool editing) async {
    setState(() => _busy = true);
    try {
      await _bloc?.setViewerEditing(editing);
      if (mounted) setState(() => _editing = editing);
    } on Object catch (_) {
      // Lỗi đã vào log ở bloc; giữ nguyên trạng thái trước đó.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveEdits() async {
    setState(() => _busy = true);
    try {
      final result = await _bloc?.saveViewerEdits();
      if (!mounted || result == null) return;
      _showSaveResult(result);
    } on Object catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Không gửi được yêu cầu lưu.')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showSaveResult(HwpSaveResult result) {
    final messenger = ScaffoldMessenger.of(context);
    if (!result.ok) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Lưu hỏng: ${result.error ?? "không rõ lý do"}'),
        ),
      );
      return;
    }
    // Ghi được không có nghĩa là ghi đủ. `exportHwpWithReport` nói phần nào nó
    // phải bỏ lại, và đó là thứ duy nhất cho biết tệp vừa ghi có còn nguyên
    // tài liệu ban đầu hay không.
    final loss = result.contentLoss;
    if (loss != null && loss.isNotEmpty) {
      messenger.showSnackBar(
        SnackBar(
          content: const Text(
            'Đã lưu, nhưng một phần nội dung không ghi được.',
          ),
          action: SnackBarAction(
            label: 'Chi tiết',
            onPressed: () => _showContentLoss(loss),
          ),
        ),
      );
      return;
    }
    messenger.showSnackBar(const SnackBar(content: Text('Đã lưu.')));
  }

  void _showContentLoss(String report) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Nội dung không ghi được'),
        content: SingleChildScrollView(child: Text(report)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Đóng'),
          ),
        ],
      ),
    );
  }

  /// Tắt chế độ sửa là **bỏ mọi thay đổi chưa lưu** — chúng chỉ nằm trong
  /// trình soạn thảo, không nằm trong tệp. Nên phải hỏi.
  Future<void> _leaveEditing(bool dirty) async {
    if (dirty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Bỏ thay đổi?'),
          content: const Text(
            'Có thay đổi chưa lưu. Thoát chế độ sửa sẽ bỏ hết.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Ở lại'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Bỏ thay đổi'),
            ),
          ],
        ),
      );
      if (discard != true) return;
    }
    await _setEditing(false);
  }

  Future<void> _find({required bool forward}) async {
    final found = await _bloc?.findInViewer(
      _searchController.text,
      forward: forward,
    );
    if (mounted) {
      setState(() => _lastSearchFound = found);
    }
  }

  void _stopSearching() {
    _bloc?.clearViewerSearch();
    _searchFocusNode.unfocus();
    setState(() {
      _searching = false;
      _lastSearchFound = null;
      _searchController.clear();
    });
  }
}

class _DetailsBar extends StatelessWidget {
  const _DetailsBar({required this.document});

  final PdfViewableDocument document;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: <Widget>[
            const Icon(Icons.description_outlined, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${document.fileFormat.toUpperCase()} · '
                '${(document.fileSizeBytes / 1024).toStringAsFixed(0)} KB',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NativeDocumentViewer extends StatefulWidget {
  const _NativeDocumentViewer({required this.path});

  final String path;

  @override
  State<_NativeDocumentViewer> createState() => _NativeDocumentViewerState();
}

class _NativeDocumentViewerState extends State<_NativeDocumentViewer> {
  @override
  Widget build(BuildContext context) {
    if (!Platform.isIOS) {
      return const Center(child: Text('This technical POC supports iOS only.'));
    }
    return UiKitView(
      viewType: 'pdf_poc_document_viewer_view',
      // The native view only exists once the platform view is created, so the
      // document is loaded from this callback rather than from initState.
      onPlatformViewCreated: (_) {
        context.read<PdfViewerBloc>().loadPickedDocumentIntoViewer(widget.path);
      },
    );
  }
}
