import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/hwp_viewer_cubit.dart';
import '../hwp_api.g.dart';
import '../widgets/hwp_editor_tool_bar.dart';

enum _ViewerMenuAction { search, details, share }

/// Đặt trình xem HWP native trong một route Flutter bình thường, nên cả màn
/// hình quanh tài liệu là của ta: app bar, menu, thanh tìm kiếm.
///
/// Native chỉ vẽ; mọi thứ bấm được ở đây là Flutter. Trạng thái nằm trong
/// [HwpViewerCubit]; `State` ở đây chỉ giữ controller, focus node và key đo
/// thanh công cụ.
class HwpViewerPage extends StatefulWidget {
  const HwpViewerPage({super.key, required this.document});

  final HwpDocument document;

  @override
  State<HwpViewerPage> createState() => _HwpViewerPageState();
}

class _HwpViewerPageState extends State<HwpViewerPage> {
  // Captured while the element tree is still stable: `dispose` runs after this
  // widget is deactivated, when ancestor lookups are no longer allowed.
  HwpViewerCubit? _cubit;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  /// Đo chiều cao thật của thanh công cụ thay vì đoán: nó đổi theo vùng an
  /// toàn của máy, và khi đang lưu thì có thêm thanh tiến trình.
  final GlobalKey _toolBarKey = GlobalKey();

  /// Số đã báo xuống native lần gần nhất, để không bắn lại cùng một giá trị.
  double _reportedChromeInset = -1;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _cubit = context.read<HwpViewerCubit>();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    if (_cubit?.isClosed == false) {
      _cubit?.closeViewer();
    }
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
    final editing = _cubit?.state.editing ?? false;
    final inset = editing && box != null && box.hasSize ? box.size.height : 0.0;
    if ((inset - _reportedChromeInset).abs() < 0.5) return;
    _reportedChromeInset = inset;
    _cubit?.setChromeInset(inset);
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncChromeInset());
    return BlocBuilder<HwpViewerCubit, HwpViewerState>(
      builder: (context, state) {
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
          appBar: state.searching ? _buildSearchAppBar(state) : _buildDefaultAppBar(state),
          // Thanh công cụ **nổi** trên web view, không phải `bottomNavigationBar`.
          // Đáy Scaffold không nhúc nhích khi bàn phím lên, nên đặt ở đó là bị
          // bàn phím phủ mất. Ở đây nó tự nâng theo `viewInsets`.
          body: Stack(
            children: <Widget>[
              Column(
                children: <Widget>[
                  if (state.showDetails) _DetailsBar(document: widget.document),
                  Expanded(child: const _NativeHwpViewer()),
                ],
              ),
              if (state.editing)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: MediaQuery.of(context).viewInsets.bottom,
                  child: HwpEditorToolBar(
                    key: _toolBarKey,
                    state: state.editor,
                    busy: state.busy,
                    onCharFormat: (format) => _cubit?.applyCharFormat(format),
                    onParaFormat: (format) => _cubit?.applyParaFormat(format),
                    onUndo: () => _cubit?.undo(),
                    onRedo: () => _cubit?.redo(),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  PreferredSizeWidget _buildDefaultAppBar(HwpViewerState state) {
    final dirty = state.dirty;
    return AppBar(
      title: Text(
        dirty ? '${widget.document.fileName} •' : widget.document.fileName,
        overflow: TextOverflow.ellipsis,
      ),
      actions: <Widget>[
        if (state.editing) ...<Widget>[
          IconButton(
            tooltip: 'Lưu',
            onPressed: state.busy || !dirty ? null : _saveEdits,
            icon: const Icon(Icons.save_outlined),
          ),
          TextButton(
            onPressed: state.busy ? null : () => _leaveEditing(dirty),
            child: const Text('Xong'),
          ),
        ] else
          IconButton(
            tooltip: 'Sửa',
            onPressed: state.busy ? null : () => _cubit?.setEditing(true),
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
                leading: Icon(state.showDetails ? Icons.info : Icons.info_outline),
                title: Text(state.showDetails ? 'Hide details' : 'File details'),
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

  PreferredSizeWidget _buildSearchAppBar(HwpViewerState state) {
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
          errorText: state.lastSearchFound == false ? 'No match' : null,
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
        _cubit?.startSearch();
      case _ViewerMenuAction.details:
        _cubit?.toggleDetails();
      case _ViewerMenuAction.share:
        _cubit?.share();
    }
  }

  Future<void> _saveEdits() async {
    try {
      final result = await _cubit?.saveEdits();
      if (!mounted || result == null) return;
      _showSaveResult(result);
    } on Object catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Không gửi được yêu cầu lưu.')));
      }
    }
  }

  void _showSaveResult(HwpSaveResult result) {
    final messenger = ScaffoldMessenger.of(context);
    if (!result.ok) {
      messenger.showSnackBar(
        SnackBar(content: Text('Lưu hỏng: ${result.error ?? "không rõ lý do"}')),
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
          content: const Text('Đã lưu, nhưng một phần nội dung không ghi được.'),
          action: SnackBarAction(label: 'Chi tiết', onPressed: () => _showContentLoss(loss)),
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
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Đóng')),
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
          content: const Text('Có thay đổi chưa lưu. Thoát chế độ sửa sẽ bỏ hết.'),
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
    await _cubit?.setEditing(false);
  }

  Future<void> _find({required bool forward}) {
    return _cubit?.find(_searchController.text, forward: forward) ?? Future<void>.value();
  }

  void _stopSearching() {
    _searchFocusNode.unfocus();
    _searchController.clear();
    _cubit?.stopSearch();
  }
}

class _DetailsBar extends StatelessWidget {
  const _DetailsBar({required this.document});

  final HwpDocument document;

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

class _NativeHwpViewer extends StatelessWidget {
  const _NativeHwpViewer();

  @override
  Widget build(BuildContext context) {
    if (!Platform.isIOS) {
      return const Center(child: Text('This technical POC supports iOS only.'));
    }
    return UiKitView(
      viewType: 'hwp_viewer_view',
      // View native chỉ tồn tại sau khi platform view được dựng, nên tài liệu
      // nạp từ callback này chứ không phải từ `initState`.
      onPlatformViewCreated: (_) {
        context.read<HwpViewerCubit>().loadIntoViewer();
      },
    );
  }
}
