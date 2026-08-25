import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../cubit/hwp_reader_cubit.dart';
import '../cubit/hwp_reader_state.dart';
import '../data/hwp_event_log.dart';
import '../widgets/hwp_document_summary.dart';
import '../widgets/hwp_page_surface.dart';

const String _inputAnchor = '\u200b';

class HwpReaderPage extends StatefulWidget {
  const HwpReaderPage.asset({required this.assetKey, super.key})
    : filePath = null;

  const HwpReaderPage.file({required this.filePath, super.key})
    : assetKey = null;

  final String? assetKey;
  final String? filePath;

  @override
  State<HwpReaderPage> createState() => _HwpReaderPageState();
}

class _HwpReaderPageState extends State<HwpReaderPage> with TextInputClient {
  late final HwpReaderCubit _cubit;
  final TextEditingController _searchController = TextEditingController();

  List<GlobalKey> _pageKeys = <GlobalKey>[];
  bool _pageTrackingScheduled = false;

  TextInputConnection? _textInputConnection;
  TextEditingValue _imeValue = const TextEditingValue(
    text: _inputAnchor,
    selection: TextSelection.collapsed(offset: 1),
  );

  @override
  TextEditingValue? get currentTextEditingValue => _imeValue;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void initState() {
    super.initState();
    _cubit = HwpReaderCubit()
      ..openDocument(assetKey: widget.assetKey, filePath: widget.filePath);
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _closeTextInput();
    _searchController.dispose();
    _cubit.close();
    super.dispose();
  }

  void _onSearchChanged() {
    if (mounted && !_cubit.state.editing) {
      setState(() {});
    }
  }

  Future<void> _beginEdit() async {
    _closeTextInput();
    _updateVisibleReaderPage();
    await _cubit.beginEdit();
  }

  Future<void> _cancelEdit() async {
    _closeTextInput();
    await _cubit.cancelEdit(
      assetKey: widget.assetKey,
      filePath: widget.filePath,
    );
  }

  Future<void> _saveEdit() async {
    _closeTextInput();
    await _cubit.saveEdit();
  }

  Future<void> _placeCaret({
    required int pageIndex,
    required Offset localPosition,
    required Size pageSize,
    required String svg,
  }) async {
    final bool didPlaceCaret = await _runKeyboardEdit(
      () => _cubit.placeCaret(
        pageIndex: pageIndex,
        localPosition: localPosition,
        pageSize: pageSize,
        svg: svg,
      ),
    );
    if (didPlaceCaret) {
      _openTextInput();
    }
  }

  Future<T> _runKeyboardEdit<T>(Future<T> Function() action) async {
    try {
      return await action();
    } finally {
      _resetTextInputState();
    }
  }

  void _syncPageKeys(int pageCount) {
    if (_pageKeys.length != pageCount) {
      final List<GlobalKey> previous = _pageKeys;
      _pageKeys = List<GlobalKey>.generate(
        pageCount,
        (int index) => index < previous.length ? previous[index] : GlobalKey(),
      );
    }
  }

  bool _handleReaderScroll(ScrollNotification notification) {
    if (!_cubit.state.editing && _pageKeys.isNotEmpty) {
      _scheduleVisibleReaderPageUpdate();
    }
    return false;
  }

  void _scheduleVisibleReaderPageUpdate() {
    if (_pageTrackingScheduled) {
      return;
    }
    _pageTrackingScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pageTrackingScheduled = false;
      _updateVisibleReaderPage();
    });
  }

  void _updateVisibleReaderPage() {
    if (!mounted || _cubit.state.editing || _pageKeys.isEmpty) {
      return;
    }
    final double viewportTop = 0;
    final double viewportBottom = MediaQuery.sizeOf(context).height;
    int? bestPage;
    double bestOverlap = 0;
    for (int index = 0; index < _pageKeys.length; index += 1) {
      final BuildContext? pageContext = _pageKeys[index].currentContext;
      final RenderObject? renderObject = pageContext?.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.hasSize) {
        continue;
      }
      final Offset offset = renderObject.localToGlobal(Offset.zero);
      final double top = offset.dy;
      final double bottom = top + renderObject.size.height;
      final double overlap =
          math.min(bottom, viewportBottom) - math.max(top, viewportTop);
      if (overlap > bestOverlap) {
        bestOverlap = overlap;
        bestPage = index;
      }
    }
    if (bestPage != null && bestPage != _cubit.state.currentPageIndex) {
      _cubit.setCurrentPage(bestPage);
      logHwpEvent('reader_visible_page_changed', <String, Object?>{
        'page': bestPage + 1,
        'pages': _pageKeys.length,
      });
    }
  }

  void _scheduleScrollToCurrentPage(int pageIndex) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || pageIndex < 0 || pageIndex >= _pageKeys.length) {
        return;
      }
      final BuildContext? pageContext = _pageKeys[pageIndex].currentContext;
      if (pageContext == null) {
        return;
      }
      Scrollable.ensureVisible(
        pageContext,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        alignment: 0.02,
      );
    });
  }

  void _openTextInput() {
    if (_textInputConnection == null || !_textInputConnection!.attached) {
      logHwpEvent('keyboard_attach');
      _textInputConnection = TextInput.attach(
        this,
        const TextInputConfiguration(
          inputType: TextInputType.multiline,
          inputAction: TextInputAction.newline,
          autocorrect: false,
          enableSuggestions: false,
        ),
      );
    }
    _resetTextInputState();
    _textInputConnection?.show();
  }

  void _closeTextInput() {
    if (_textInputConnection != null) {
      logHwpEvent('keyboard_close');
    }
    _textInputConnection?.close();
    _textInputConnection = null;
  }

  void _resetTextInputState() {
    _imeValue = const TextEditingValue(
      text: _inputAnchor,
      selection: TextSelection.collapsed(offset: 1),
    );
    if (_textInputConnection?.attached ?? false) {
      _textInputConnection?.setEditingState(_imeValue);
    }
  }

  @override
  void updateEditingValue(TextEditingValue value) {
    final HwpReaderState state = _cubit.state;
    if (!state.editing || state.caret == null) {
      _resetTextInputState();
      return;
    }
    if (value.text == _inputAnchor) {
      _imeValue = value;
      return;
    }
    if (value.text.isEmpty) {
      unawaited(_runKeyboardEdit(_cubit.deleteBackward));
      return;
    }

    final String inserted = value.text.replaceAll(_inputAnchor, '');
    if (inserted.isNotEmpty) {
      unawaited(_runKeyboardEdit(() => _cubit.insertAtCaret(inserted)));
    } else {
      _resetTextInputState();
    }
  }

  @override
  void performAction(TextInputAction action) {
    if (action == TextInputAction.newline) {
      unawaited(_runKeyboardEdit(_cubit.splitParagraphAtCaret));
    }
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void connectionClosed() {
    _textInputConnection = null;
  }

  @override
  void performSelector(String selectorName) {
    if (selectorName.contains('delete')) {
      unawaited(_runKeyboardEdit(_cubit.deleteBackward));
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider<HwpReaderCubit>.value(
      value: _cubit,
      child: BlocConsumer<HwpReaderCubit, HwpReaderState>(
        listenWhen: (HwpReaderState previous, HwpReaderState current) {
          return previous.editing && !current.editing;
        },
        listener: (BuildContext context, HwpReaderState state) {
          _scheduleScrollToCurrentPage(state.activePageIndex());
        },
        builder: (BuildContext context, HwpReaderState state) {
          _syncPageKeys(state.pageSvgs.length);
          return Scaffold(
            appBar: state.editing
                ? _buildEditorAppBar(state)
                : _buildReaderAppBar(state),
            body: SafeArea(
              child: Column(
                children: <Widget>[
                  if (state.busy) const LinearProgressIndicator(),
                  HwpDocumentSummary(info: state.info, status: state.status),
                  const Divider(height: 1),
                  Expanded(child: _buildReader(state)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  PreferredSizeWidget _buildReaderAppBar(HwpReaderState state) {
    return AppBar(
      title: TextField(
        controller: _searchController,
        textInputAction: TextInputAction.search,
        decoration: const InputDecoration(
          hintText: 'Tìm trong HWP',
          border: InputBorder.none,
          prefixIcon: Icon(Icons.search),
        ),
      ),
      actions: <Widget>[
        IconButton(
          tooltip: 'Chỉnh sửa',
          onPressed: state.busy || state.text.isEmpty
              ? null
              : () => unawaited(_beginEdit()),
          icon: const Icon(Icons.edit_outlined),
        ),
      ],
    );
  }

  PreferredSizeWidget _buildEditorAppBar(HwpReaderState state) {
    return AppBar(
      leading: IconButton(
        tooltip: 'Huỷ',
        onPressed: state.busy ? null : () => unawaited(_cancelEdit()),
        icon: const Icon(Icons.close),
      ),
      title: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          IconButton(
            tooltip: 'Undo',
            onPressed: state.busy || !state.canUndo
                ? null
                : () => unawaited(_runKeyboardEdit(_cubit.undo)),
            icon: const Icon(Icons.undo),
          ),
          IconButton(
            tooltip: 'Redo',
            onPressed: state.busy || !state.canRedo
                ? null
                : () => unawaited(_runKeyboardEdit(_cubit.redo)),
            icon: const Icon(Icons.redo),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: state.busy ? null : () => unawaited(_saveEdit()),
          child: const Text('Save'),
        ),
      ],
    );
  }

  Widget _buildReader(HwpReaderState state) {
    final String query = _searchController.text;
    final int matches = _countMatches(state.text, query);
    if (state.pageSvgs.isNotEmpty && !state.editing) {
      final bool showSearchSummary = query.isNotEmpty;
      return NotificationListener<ScrollNotification>(
        onNotification: _handleReaderScroll,
        child: ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: state.pageSvgs.length + (showSearchSummary ? 1 : 0),
          itemBuilder: (BuildContext context, int rawIndex) {
            if (showSearchSummary && rawIndex == 0) {
              return _SearchSummary(matches: matches);
            }
            final int index = rawIndex - (showSearchSummary ? 1 : 0);
            return KeyedSubtree(
              key: index < _pageKeys.length ? _pageKeys[index] : null,
              child: HwpPageSurface(
                pageIndex: index,
                pageNumber: index + 1,
                pageCount: state.pageCount,
                svg: state.pageSvgs[index],
                editing: false,
                caret: null,
                onNeedRender: _cubit.renderPage,
                onTapPage: _placeCaret,
              ),
            );
          },
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        if (!state.editing && query.isNotEmpty)
          _SearchSummary(matches: matches),
        if (state.pageSvgs.isEmpty)
          SelectableText.rich(
            TextSpan(
              style: Theme.of(context).textTheme.bodyMedium,
              children: _highlightSpans(context, state.text, query),
            ),
          )
        else if (state.editing) ...<Widget>[
          _EditPageNavigator(
            pageIndex: state.activePageIndex(),
            pageCount: state.pageSvgs.length,
            busy: state.busy,
            onShowPage: _cubit.showEditPage,
          ),
          HwpPageSurface(
            pageIndex: state.activePageIndex(),
            pageNumber: state.activePageIndex() + 1,
            pageCount: state.pageCount,
            svg: state.pageSvgs[state.activePageIndex()],
            editing: true,
            caret: state.caret?.pageIndex == state.activePageIndex()
                ? state.caret
                : null,
            onNeedRender: _cubit.renderPage,
            onTapPage: _placeCaret,
          ),
        ],
      ],
    );
  }

  List<TextSpan> _highlightSpans(
    BuildContext context,
    String text,
    String query,
  ) {
    if (text.isEmpty) {
      return const <TextSpan>[TextSpan(text: 'Không có nội dung để hiển thị.')];
    }
    if (query.isEmpty) {
      return <TextSpan>[TextSpan(text: text)];
    }

    final String lowerText = text.toLowerCase();
    final String lowerQuery = query.toLowerCase();
    final Color highlight = Theme.of(context).colorScheme.secondaryContainer;
    final List<TextSpan> spans = <TextSpan>[];
    int cursor = 0;

    while (cursor < text.length) {
      final int index = lowerText.indexOf(lowerQuery, cursor);
      if (index < 0) {
        spans.add(TextSpan(text: text.substring(cursor)));
        break;
      }
      if (index > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, index)));
      }
      final int end = index + query.length;
      spans.add(
        TextSpan(
          text: text.substring(index, end),
          style: TextStyle(backgroundColor: highlight),
        ),
      );
      cursor = end;
    }

    return spans;
  }

  int _countMatches(String text, String query) {
    if (text.isEmpty || query.isEmpty) {
      return 0;
    }
    int count = 0;
    int cursor = 0;
    final String lowerText = text.toLowerCase();
    final String lowerQuery = query.toLowerCase();
    while (cursor < lowerText.length) {
      final int index = lowerText.indexOf(lowerQuery, cursor);
      if (index < 0) {
        break;
      }
      count += 1;
      cursor = index + lowerQuery.length;
    }
    return count;
  }
}

class _SearchSummary extends StatelessWidget {
  const _SearchSummary({required this.matches});

  final int matches;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        '$matches kết quả trong text trích xuất',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

class _EditPageNavigator extends StatelessWidget {
  const _EditPageNavigator({
    required this.pageIndex,
    required this.pageCount,
    required this.busy,
    required this.onShowPage,
  });

  final int pageIndex;
  final int pageCount;
  final bool busy;
  final Future<void> Function(int pageIndex) onShowPage;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: <Widget>[
          IconButton(
            tooltip: 'Trang trước',
            onPressed: busy || pageIndex <= 0
                ? null
                : () => unawaited(onShowPage(pageIndex - 1)),
            icon: const Icon(Icons.chevron_left),
          ),
          Expanded(
            child: Center(
              child: Text(
                'Trang ${pageIndex + 1}/$pageCount',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Trang sau',
            onPressed: busy || pageIndex >= pageCount - 1
                ? null
                : () => unawaited(onShowPage(pageIndex + 1)),
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }
}

typedef HwpDiagnosticPage = HwpReaderPage;
