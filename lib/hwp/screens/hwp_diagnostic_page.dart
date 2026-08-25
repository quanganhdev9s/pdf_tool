import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../hwp_api.g.dart';
import '../data/hwp_event_log.dart';
import '../services/hwp_document_service.dart';

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
  final HwpDocumentService _service = HwpDocumentService();
  final TextEditingController _searchController = TextEditingController();

  HwpDocumentInfo? _info;
  String _text = '';
  List<String?> _pageSvgs = <String?>[];
  String _status = 'Đang mở HWP...';
  bool _busy = false;
  bool _editing = false;
  int _editingPageIndex = 0;
  _DirectCaret? _caret;
  final Set<int> _renderingPages = <int>{};

  TextInputConnection? _textInputConnection;
  TextEditingValue _imeValue = const TextEditingValue(
    text: _inputAnchor,
    selection: TextSelection.collapsed(offset: 1),
  );
  Future<void> _directEditQueue = Future<void>.value();

  @override
  TextEditingValue? get currentTextEditingValue => _imeValue;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _openDocument();
  }

  @override
  void dispose() {
    _closeTextInput();
    _searchController.dispose();
    _service.close();
    super.dispose();
  }

  Future<void> _openDocument() async {
    await _run(() async {
      logHwpEvent('open_document_start', <String, Object?>{
        'asset': widget.assetKey,
        'file': widget.filePath,
      });
      setState(() {
        _status = 'Đang mở HWP...';
      });
      final HwpDocumentInfo info;
      final String? assetKey = widget.assetKey;
      if (assetKey != null) {
        info = await _service.openAsset(assetKey);
      } else {
        info = await _service.openFile(widget.filePath!);
      }

      setState(() {
        _status = 'Đang trích xuất text...';
      });
      final String text = await _service.extractText();
      setState(() {
        _info = info;
        _text = text;
        _caret = null;
        _editingPageIndex = 0;
        _pageSvgs = List<String?>.filled(info.pageCount, null);
        _status = info.pageCount > 0
            ? 'Đang dựng trang 1/${info.pageCount}'
            : 'Đã mở ${info.fileName}';
      });
      await _renderPage(
        0,
        force: true,
        reason: 'render_initial_page',
        loadingStatus: info.pageCount > 0
            ? 'Đang dựng trang 1/${info.pageCount}'
            : null,
        finalStatus: 'Đã mở ${info.fileName}',
      );
      logHwpEvent('open_document_done', <String, Object?>{
        'file': info.fileName,
        'pages': info.pageCount,
      });
    });
  }

  Future<void> _renderPage(
    int pageIndex, {
    bool force = false,
    String reason = 'render_page',
    String? loadingStatus,
    String? finalStatus,
  }) async {
    if (pageIndex < 0 || pageIndex >= _pageSvgs.length) {
      if (finalStatus != null && mounted) {
        setState(() {
          _status = finalStatus;
        });
      }
      return;
    }
    if (!force && _pageSvgs[pageIndex] != null) {
      if (finalStatus != null && mounted) {
        setState(() {
          _status = finalStatus;
        });
      }
      logHwpEvent('${reason}_cache_hit', <String, Object?>{
        'page': pageIndex + 1,
        'pages': _pageSvgs.length,
      });
      return;
    }
    if (_renderingPages.contains(pageIndex)) {
      return;
    }

    _renderingPages.add(pageIndex);
    if (loadingStatus != null && mounted) {
      setState(() {
        _status = loadingStatus;
      });
    }
    logHwpEvent('${reason}_start', <String, Object?>{
      'page': pageIndex + 1,
      'pages': _pageSvgs.length,
    });
    try {
      final String svg = await _service.renderPageSvg(pageIndex);
      if (!mounted) {
        return;
      }
      logHwpEvent('${reason}_done', <String, Object?>{
        'page': pageIndex + 1,
        'bytes': svg.length,
      });
      final List<String?> pages = List<String?>.from(_pageSvgs);
      if (pageIndex < pages.length) {
        pages[pageIndex] = svg;
      }
      setState(() {
        _pageSvgs = pages;
        if (finalStatus != null) {
          _status = finalStatus;
        }
      });
    } finally {
      _renderingPages.remove(pageIndex);
    }
  }

  void _onSearchChanged() {
    if (mounted && !_editing) {
      setState(() {});
    }
  }

  Future<void> _beginEdit() async {
    final HwpDocumentInfo? info = _info;
    if (_busy || info == null) {
      return;
    }
    _closeTextInput();
    await _run(() async {
      logHwpEvent('edit_prepare_start', <String, Object?>{
        'file': info.fileName,
        'source': info.sourcePath,
      });
      setState(() {
        _status = 'Đang vào chế độ chỉnh sửa...';
      });
      final int activePage = _activeEditPageIndex(info.pageCount);
      setState(() {
        _editing = true;
        _caret = null;
        _editingPageIndex = activePage;
        _status = 'Chạm vào nội dung để đặt con trỏ';
      });
      logHwpEvent('edit_prepare_done', <String, Object?>{
        'file': info.fileName,
        'source': info.sourcePath,
        'copyCreated': false,
      });
    });
  }

  Future<void> _cancelEdit() async {
    if (_busy) {
      return;
    }
    _closeTextInput();
    logHwpEvent('edit_cancel');
    setState(() {
      _editing = false;
      _caret = null;
      _editingPageIndex = 0;
      _status = 'Đã huỷ chỉnh sửa';
    });
    await _openDocument();
  }

  void _undo() {
    setState(() {
      _status = 'Undo trực tiếp trên HWP sẽ được nối ở bước tiếp theo.';
    });
  }

  void _redo() {
    setState(() {
      _status = 'Redo trực tiếp trên HWP sẽ được nối ở bước tiếp theo.';
    });
  }

  int _activeEditPageIndex([int? pageCount]) {
    final int count = pageCount ?? _pageSvgs.length;
    if (count <= 0) {
      return 0;
    }
    return math.min(math.max(_editingPageIndex, 0), count - 1);
  }

  Future<void> _showEditPage(int pageIndex) async {
    if (_busy || _pageSvgs.isEmpty) {
      return;
    }
    final int target = math.min(math.max(pageIndex, 0), _pageSvgs.length - 1);
    setState(() {
      _editingPageIndex = target;
      _caret = _caret?.pageIndex == target ? _caret : null;
      _status = _pageSvgs[target] == null
          ? 'Đang dựng trang ${target + 1}/${_pageSvgs.length}'
          : 'Chạm vào nội dung để đặt con trỏ';
    });
    await _renderPage(
      target,
      reason: 'edit_page_render',
      loadingStatus: 'Đang dựng trang ${target + 1}/${_pageSvgs.length}',
      finalStatus: 'Chạm vào nội dung để đặt con trỏ',
    );
  }

  Future<void> _saveEdit() async {
    final HwpDocumentInfo? info = _info;
    if (info == null || _busy) {
      return;
    }
    _closeTextInput();
    await _run(() async {
      logHwpEvent('save_edit_start', <String, Object?>{'file': info.fileName});
      setState(() {
        _status = 'Đang lưu HWP...';
      });
      final HwpSaveEditOutcome save = await _service.saveEditedDocument(info);
      final HwpDocumentInfo savedInfo = save.info;
      setState(() {
        _status = 'Đang trích xuất text sau khi lưu...';
      });
      final String text = await _service.extractText();
      setState(() {
        _info = savedInfo;
        _editing = false;
        _caret = null;
        _editingPageIndex = 0;
        _text = text;
        _pageSvgs = List<String?>.filled(savedInfo.pageCount, null);
        _status = savedInfo.pageCount > 0
            ? 'Đang dựng trang 1/${savedInfo.pageCount}'
            : 'Đã lưu ${save.result.fileSizeBytes} bytes';
      });
      final String finalStatus = save.createdWorkingCopy
          ? 'Đã lưu bản chỉnh sửa: ${savedInfo.fileName}'
          : 'Đã lưu ${save.result.fileSizeBytes} bytes';
      await _renderPage(
        0,
        force: true,
        reason: 'save_render_initial_page',
        loadingStatus: savedInfo.pageCount > 0
            ? 'Đang dựng trang 1/${savedInfo.pageCount}'
            : null,
        finalStatus: finalStatus,
      );
      logHwpEvent('save_edit_done', <String, Object?>{
        'file': savedInfo.fileName,
        'bytes': save.result.fileSizeBytes,
        'copyCreated': save.createdWorkingCopy,
      });
    });
  }

  Future<void> _placeCaret({
    required int pageIndex,
    required Offset localPosition,
    required Size pageSize,
    required String svg,
  }) async {
    try {
      if (_busy || !_editing) {
        return;
      }
      final _SvgViewport viewport = _SvgViewport.fromSvg(svg);
      final double x =
          viewport.x + localPosition.dx / pageSize.width * viewport.width;
      final double y =
          viewport.y + localPosition.dy / pageSize.height * viewport.height;

      await _runDirectEdit(() async {
        logHwpEvent('hit_test_start', <String, Object?>{
          'page': pageIndex + 1,
          'x': x.toStringAsFixed(2),
          'y': y.toStringAsFixed(2),
        });
        setState(() {
          _status = 'Đang đặt con trỏ...';
        });
        final String hitJson = await _service.hitTestPage(
          pageIndex: pageIndex,
          x: x,
          y: y,
        );
        final Map<String, dynamic> hit = _decodeObject(hitJson);
        final int? sectionIndex = _readInt(hit, 'sectionIndex', 'sec');
        final int? paragraphIndex = _readInt(hit, 'paragraphIndex', 'para');
        final int? charOffset = _readInt(hit, 'charOffset', 'offset');
        if (sectionIndex == null ||
            paragraphIndex == null ||
            charOffset == null) {
          throw StateError('Vị trí này chưa hỗ trợ chỉnh sửa trực tiếp.');
        }

        final _DirectCaret caret = await _cursorFor(
          sectionIndex: sectionIndex,
          paragraphIndex: paragraphIndex,
          charOffset: charOffset,
          fallbackPageIndex: pageIndex,
        );
        if (!mounted) {
          return;
        }
        setState(() {
          _caret = caret;
          _editingPageIndex = caret.pageIndex;
          _status = 'Đang chỉnh sửa';
        });
        logHwpEvent('hit_test_done', <String, Object?>{
          'page': caret.pageIndex + 1,
          'section': caret.sectionIndex,
          'paragraph': caret.paragraphIndex,
          'offset': caret.charOffset,
        });
        _openTextInput();
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Lỗi: ${e.toString()}';
      });
    }
  }

  Future<void> _insertAtCaret(String text) async {
    final _DirectCaret? caret = _caret;
    if (caret == null || text.isEmpty) {
      return;
    }
    if (text.contains('\n')) {
      await _insertTextWithParagraphBreaks(text);
      return;
    }
    await _runDirectEdit(() async {
      logHwpEvent('insert_text_start', <String, Object?>{
        'section': caret.sectionIndex,
        'paragraph': caret.paragraphIndex,
        'offset': caret.charOffset,
        'chars': text.runes.length,
      });
      setState(() {
        _status = 'Đang nhập text...';
      });
      final String editJson = await _service.insertText(
        sectionIndex: caret.sectionIndex,
        paragraphIndex: caret.paragraphIndex,
        charOffset: caret.charOffset,
        text: text,
      );
      final int nextOffset =
          _readInt(_decodeObject(editJson), 'charOffset') ??
          caret.charOffset + text.runes.length;
      await _refreshAfterDirectEdit(caret.copyWith(charOffset: nextOffset));
      logHwpEvent('insert_text_done', <String, Object?>{
        'nextOffset': nextOffset,
      });
    });
  }

  Future<void> _insertTextWithParagraphBreaks(String text) async {
    final List<String> parts = text.split('\n');
    for (int index = 0; index < parts.length; index += 1) {
      final String part = parts[index];
      if (part.isNotEmpty) {
        await _insertAtCaret(part);
      }
      if (index < parts.length - 1) {
        await _splitParagraphAtCaret();
      }
    }
  }

  Future<void> _splitParagraphAtCaret() async {
    final _DirectCaret? caret = _caret;
    if (caret == null) {
      return;
    }
    await _runDirectEdit(() async {
      logHwpEvent('split_paragraph_start', <String, Object?>{
        'section': caret.sectionIndex,
        'paragraph': caret.paragraphIndex,
        'offset': caret.charOffset,
      });
      setState(() {
        _status = 'Đang xuống dòng...';
      });
      final String editJson = await _service.splitParagraph(
        sectionIndex: caret.sectionIndex,
        paragraphIndex: caret.paragraphIndex,
        charOffset: caret.charOffset,
      );
      final Map<String, dynamic> edit = _decodeObject(editJson);
      final int nextParagraphIndex =
          _readInt(edit, 'paraIdx', 'paragraphIndex') ??
          caret.paragraphIndex + 1;
      final int nextOffset = _readInt(edit, 'charOffset') ?? 0;
      await _refreshAfterDirectEdit(
        caret.copyWith(
          paragraphIndex: nextParagraphIndex,
          charOffset: nextOffset,
        ),
      );
      logHwpEvent('split_paragraph_done', <String, Object?>{
        'paragraph': nextParagraphIndex,
        'offset': nextOffset,
      });
    });
  }

  Future<void> _deleteBackward() async {
    final _DirectCaret? caret = _caret;
    if (caret == null) {
      return;
    }
    if (caret.charOffset <= 0) {
      await _mergeParagraphAtCaret();
      return;
    }
    await _runDirectEdit(() async {
      final int nextOffset = math.max(0, caret.charOffset - 1);
      logHwpEvent('delete_text_start', <String, Object?>{
        'section': caret.sectionIndex,
        'paragraph': caret.paragraphIndex,
        'offset': nextOffset,
      });
      setState(() {
        _status = 'Đang xoá text...';
      });
      final String editJson = await _service.deleteText(
        sectionIndex: caret.sectionIndex,
        paragraphIndex: caret.paragraphIndex,
        charOffset: nextOffset,
        count: 1,
      );
      await _refreshAfterDirectEdit(
        caret.copyWith(
          charOffset:
              _readInt(_decodeObject(editJson), 'charOffset') ?? nextOffset,
        ),
      );
      logHwpEvent('delete_text_done', <String, Object?>{'offset': nextOffset});
    });
  }

  Future<void> _mergeParagraphAtCaret() async {
    final _DirectCaret? caret = _caret;
    if (caret == null || caret.paragraphIndex <= 0) {
      return;
    }
    await _runDirectEdit(() async {
      logHwpEvent('merge_paragraph_start', <String, Object?>{
        'section': caret.sectionIndex,
        'paragraph': caret.paragraphIndex,
      });
      setState(() {
        _status = 'Đang gộp dòng...';
      });
      final String editJson = await _service.mergeParagraph(
        sectionIndex: caret.sectionIndex,
        paragraphIndex: caret.paragraphIndex,
      );
      final Map<String, dynamic> edit = _decodeObject(editJson);
      final int mergedParagraphIndex =
          _readInt(edit, 'paraIdx', 'paragraphIndex') ??
          caret.paragraphIndex - 1;
      final int mergedOffset = _readInt(edit, 'charOffset') ?? 0;
      await _refreshAfterDirectEdit(
        caret.copyWith(
          paragraphIndex: mergedParagraphIndex,
          charOffset: mergedOffset,
        ),
      );
      logHwpEvent('merge_paragraph_done', <String, Object?>{
        'paragraph': mergedParagraphIndex,
        'offset': mergedOffset,
      });
    });
  }

  Future<void> _refreshAfterDirectEdit(_DirectCaret caret) async {
    logHwpEvent('edit_refresh_start', <String, Object?>{
      'section': caret.sectionIndex,
      'paragraph': caret.paragraphIndex,
      'offset': caret.charOffset,
    });
    if (mounted) {
      setState(() {
        _status = 'Đang cập nhật trang...';
      });
    }
    final _DirectCaret updatedCaret = await _cursorFor(
      sectionIndex: caret.sectionIndex,
      paragraphIndex: caret.paragraphIndex,
      charOffset: caret.charOffset,
      fallbackPageIndex: caret.pageIndex,
    );
    final HwpDocumentInfo info = await _service.currentInfo();
    final int activePage = math.min(
      math.max(updatedCaret.pageIndex, 0),
      math.max(info.pageCount - 1, 0),
    );
    final List<String?> pages = List<String?>.filled(info.pageCount, null);
    if (pages.isNotEmpty) {
      logHwpEvent('edit_invalidate_page_cache', <String, Object?>{
        'allPages': true,
        'pages': pages.length,
      });
    }
    if (pages.isNotEmpty) {
      logHwpEvent('edit_render_active_page_start', <String, Object?>{
        'page': activePage + 1,
        'pages': info.pageCount,
      });
      pages[activePage] = await _service.renderPageSvg(activePage);
      logHwpEvent('edit_render_active_page_done', <String, Object?>{
        'page': activePage + 1,
        'bytes': pages[activePage]?.length,
      });
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _info = info;
      _caret = updatedCaret;
      _editingPageIndex = activePage;
      _pageSvgs = pages;
      _status = 'Đang chỉnh sửa';
    });
    logHwpEvent('edit_refresh_done', <String, Object?>{
      'page': activePage + 1,
      'pages': info.pageCount,
      'caretOffset': updatedCaret.charOffset,
    });
  }

  Future<_DirectCaret> _cursorFor({
    required int sectionIndex,
    required int paragraphIndex,
    required int charOffset,
    required int fallbackPageIndex,
  }) async {
    final String rectJson = await _service.getCursorRect(
      sectionIndex: sectionIndex,
      paragraphIndex: paragraphIndex,
      charOffset: charOffset,
    );
    final Map<String, dynamic> rect = _decodeObject(rectJson);
    return _DirectCaret(
      pageIndex: _readInt(rect, 'pageIndex') ?? fallbackPageIndex,
      sectionIndex: sectionIndex,
      paragraphIndex: paragraphIndex,
      charOffset: charOffset,
      x: _readDouble(rect, 'x') ?? 0,
      y: _readDouble(rect, 'y') ?? 0,
      height: _readDouble(rect, 'height') ?? 16,
    );
  }

  Future<void> _runDirectEdit(Future<void> Function() action) async {
    _directEditQueue = _directEditQueue.then((_) async {
      try {
        await action();
      } on PlatformException catch (error) {
        logHwpEvent('direct_edit_failed', <String, Object?>{
          'code': error.code,
          'message': error.message,
        });
        if (!mounted) {
          return;
        }
        setState(() {
          _status = '${error.code}: ${error.message ?? 'Thao tác thất bại'}';
        });
      } catch (error) {
        logHwpEvent('direct_edit_failed', <String, Object?>{'error': error});
        if (!mounted) {
          return;
        }
        setState(() {
          _status = error.toString();
        });
      } finally {
        _resetTextInputState();
      }
    });
    await _directEditQueue;
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
    });
    try {
      await action();
    } on PlatformException catch (error) {
      logHwpEvent('operation_failed', <String, Object?>{
        'code': error.code,
        'message': error.message,
      });
      setState(() {
        _status = '${error.code}: ${error.message ?? 'Thao tác thất bại'}';
      });
    } catch (error) {
      logHwpEvent('operation_failed', <String, Object?>{'error': error});
      setState(() {
        _status = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
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
    if (!_editing || _caret == null) {
      _resetTextInputState();
      return;
    }
    if (value.text == _inputAnchor) {
      _imeValue = value;
      return;
    }
    if (value.text.isEmpty) {
      unawaited(_deleteBackward());
      return;
    }

    final String inserted = value.text.replaceAll(_inputAnchor, '');
    if (inserted.isNotEmpty) {
      unawaited(_insertAtCaret(inserted));
    } else {
      _resetTextInputState();
    }
  }

  @override
  void performAction(TextInputAction action) {
    if (action == TextInputAction.newline) {
      unawaited(_splitParagraphAtCaret());
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
      unawaited(_deleteBackward());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _editing ? _buildEditorAppBar() : _buildReaderAppBar(),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            if (_busy) const LinearProgressIndicator(),
            _DocumentSummary(info: _info, status: _status),
            const Divider(height: 1),
            Expanded(child: _buildReader(editing: _editing)),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildReaderAppBar() {
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
          onPressed: _busy || _text.isEmpty
              ? null
              : () => unawaited(_beginEdit()),
          icon: const Icon(Icons.edit_outlined),
        ),
      ],
    );
  }

  PreferredSizeWidget _buildEditorAppBar() {
    return AppBar(
      leading: IconButton(
        tooltip: 'Huỷ',
        onPressed: _busy ? null : () => unawaited(_cancelEdit()),
        icon: const Icon(Icons.close),
      ),
      title: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          IconButton(
            tooltip: 'Undo',
            onPressed: _busy ? null : _undo,
            icon: const Icon(Icons.undo),
          ),
          IconButton(
            tooltip: 'Redo',
            onPressed: _busy ? null : _redo,
            icon: const Icon(Icons.redo),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy ? null : _saveEdit,
          child: const Text('Save'),
        ),
      ],
    );
  }

  Widget _buildReader({required bool editing}) {
    final String query = _searchController.text;
    final int matches = _countMatches(_text, query);
    final HwpDocumentInfo? info = _info;
    if (_pageSvgs.isNotEmpty && !editing) {
      final bool showSearchSummary = query.isNotEmpty;
      return ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _pageSvgs.length + (showSearchSummary ? 1 : 0),
        itemBuilder: (BuildContext context, int rawIndex) {
          if (showSearchSummary && rawIndex == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                '$matches kết quả trong text trích xuất',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            );
          }
          final int index = rawIndex - (showSearchSummary ? 1 : 0);
          return _HwpPageSurface(
            pageIndex: index,
            pageNumber: index + 1,
            pageCount: info?.pageCount ?? _pageSvgs.length,
            svg: _pageSvgs[index],
            editing: false,
            caret: null,
            onNeedRender: _ensurePageRendered,
            onTapPage: _placeCaret,
          );
        },
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        if (!editing && query.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              '$matches kết quả trong text trích xuất',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (_pageSvgs.isEmpty)
          SelectableText.rich(
            TextSpan(
              style: Theme.of(context).textTheme.bodyMedium,
              children: _highlightSpans(context, _text, query),
            ),
          )
        else if (editing) ...<Widget>[
          _buildEditPageNavigator(_activeEditPageIndex(), _pageSvgs.length),
          _HwpPageSurface(
            pageIndex: _activeEditPageIndex(),
            pageNumber: _activeEditPageIndex() + 1,
            pageCount: info?.pageCount ?? _pageSvgs.length,
            svg: _pageSvgs[_activeEditPageIndex()],
            editing: true,
            caret: _caret?.pageIndex == _activeEditPageIndex() ? _caret : null,
            onNeedRender: _ensurePageRendered,
            onTapPage: _placeCaret,
          ),
        ],
      ],
    );
  }

  Future<void> _ensurePageRendered(int pageIndex) {
    return _renderPage(
      pageIndex,
      reason: 'lazy_render_page',
      loadingStatus: 'Đang dựng trang ${pageIndex + 1}/${_pageSvgs.length}',
    );
  }

  Widget _buildEditPageNavigator(int pageIndex, int pageCount) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: <Widget>[
          IconButton(
            tooltip: 'Trang trước',
            onPressed: _busy || pageIndex <= 0
                ? null
                : () => unawaited(_showEditPage(pageIndex - 1)),
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
            onPressed: _busy || pageIndex >= pageCount - 1
                ? null
                : () => unawaited(_showEditPage(pageIndex + 1)),
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }

  Map<String, dynamic> _decodeObject(String json) {
    final Object? decoded = jsonDecode(json);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    return <String, dynamic>{};
  }

  int? _readInt(Map<String, dynamic> value, String key, [String? fallback]) {
    final Object? raw =
        value[key] ?? (fallback == null ? null : value[fallback]);
    if (raw is int) {
      return raw;
    }
    if (raw is num) {
      return raw.toInt();
    }
    if (raw is String) {
      return int.tryParse(raw);
    }
    return null;
  }

  double? _readDouble(Map<String, dynamic> value, String key) {
    final Object? raw = value[key];
    if (raw is num) {
      return raw.toDouble();
    }
    if (raw is String) {
      return double.tryParse(raw);
    }
    return null;
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

class _HwpPageSurface extends StatefulWidget {
  const _HwpPageSurface({
    required this.pageIndex,
    required this.pageNumber,
    required this.pageCount,
    required this.svg,
    required this.editing,
    required this.caret,
    required this.onNeedRender,
    required this.onTapPage,
  });

  final int pageIndex;
  final int pageNumber;
  final int pageCount;
  final String? svg;
  final bool editing;
  final _DirectCaret? caret;
  final Future<void> Function(int pageIndex) onNeedRender;
  final Future<void> Function({
    required int pageIndex,
    required Offset localPosition,
    required Size pageSize,
    required String svg,
  })
  onTapPage;

  @override
  State<_HwpPageSurface> createState() => _HwpPageSurfaceState();
}

class _HwpPageSurfaceState extends State<_HwpPageSurface> {
  final TransformationController _transformController =
      TransformationController();
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _requestRenderIfNeeded();
  }

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _HwpPageSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pageIndex != widget.pageIndex) {
      _resetZoom();
    }
    _requestRenderIfNeeded();
  }

  void _syncZoomState() {
    final bool nextZoomed =
        _transformController.value.getMaxScaleOnAxis() > 1.01;
    if (nextZoomed != _zoomed && mounted) {
      setState(() {
        _zoomed = nextZoomed;
      });
    }
  }

  void _resetZoom() {
    _transformController.value = Matrix4.identity();
    if (_zoomed && mounted) {
      setState(() {
        _zoomed = false;
      });
    } else {
      _zoomed = false;
    }
  }

  void _settleZoom() {
    if (_transformController.value.getMaxScaleOnAxis() <= 1.01) {
      _resetZoom();
    } else {
      _syncZoomState();
    }
  }

  void _requestRenderIfNeeded() {
    if (widget.svg != null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.svg == null) {
        unawaited(widget.onNeedRender(widget.pageIndex));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final String? pageSvg = widget.svg;
    final _SvgViewport viewport = _SvgViewport.fromSvg(pageSvg);
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'Trang ${widget.pageNumber}/${widget.pageCount}',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(
                color: widget.editing
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).dividerColor,
              ),
              borderRadius: BorderRadius.circular(6),
              boxShadow: const <BoxShadow>[
                BoxShadow(
                  color: Color(0x14000000),
                  blurRadius: 12,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: AspectRatio(
                aspectRatio: viewport.aspectRatio,
                child: InteractiveViewer(
                  transformationController: _transformController,
                  minScale: 1,
                  maxScale: 5,
                  panEnabled: pageSvg != null && _zoomed,
                  scaleEnabled: pageSvg != null,
                  boundaryMargin: EdgeInsets.zero,
                  onInteractionUpdate: (_) => _syncZoomState(),
                  onInteractionEnd: (_) => _settleZoom(),
                  child: LayoutBuilder(
                    builder:
                        (BuildContext context, BoxConstraints constraints) {
                          final Size pageSize = Size(
                            constraints.maxWidth,
                            constraints.maxHeight,
                          );
                          return GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTapUp: widget.editing && pageSvg != null
                                ? (TapUpDetails details) => unawaited(
                                    widget.onTapPage(
                                      pageIndex: widget.pageIndex,
                                      localPosition: details.localPosition,
                                      pageSize: pageSize,
                                      svg: pageSvg,
                                    ),
                                  )
                                : null,
                            child: Stack(
                              fit: StackFit.expand,
                              children: <Widget>[
                                if (pageSvg == null)
                                  const Center(
                                    child: CircularProgressIndicator(),
                                  )
                                else
                                  SvgPicture.string(
                                    pageSvg,
                                    fit: BoxFit.contain,
                                    placeholderBuilder: (_) => const Center(
                                      child: CircularProgressIndicator(),
                                    ),
                                  ),
                                if (widget.editing && widget.caret != null)
                                  _CaretPainter(
                                    caret: widget.caret!,
                                    viewport: viewport,
                                    pageSize: pageSize,
                                  ),
                              ],
                            ),
                          );
                        },
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CaretPainter extends StatelessWidget {
  const _CaretPainter({
    required this.caret,
    required this.viewport,
    required this.pageSize,
  });

  final _DirectCaret caret;
  final _SvgViewport viewport;
  final Size pageSize;

  @override
  Widget build(BuildContext context) {
    final double left =
        (caret.x - viewport.x) / viewport.width * pageSize.width;
    final double top =
        (caret.y - viewport.y) / viewport.height * pageSize.height;
    final double height = caret.height / viewport.height * pageSize.height;
    return Positioned(
      left: left.clamp(0, pageSize.width - 2),
      top: top.clamp(0, pageSize.height),
      child: Container(
        width: 2,
        height: math.max(2, height),
        color: Theme.of(context).colorScheme.primary,
      ),
    );
  }
}

class _SvgViewport {
  const _SvgViewport({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  factory _SvgViewport.fromSvg(String? svg) {
    final String? value = svg;
    if (value == null) {
      return const _SvgViewport(x: 0, y: 0, width: 210, height: 297);
    }
    final RegExpMatch? match = RegExp(
      r'viewBox="[^"]*?([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)"',
    ).firstMatch(value);
    final double? x = double.tryParse(match?.group(1) ?? '');
    final double? y = double.tryParse(match?.group(2) ?? '');
    final double? width = double.tryParse(match?.group(3) ?? '');
    final double? height = double.tryParse(match?.group(4) ?? '');
    if (x == null ||
        y == null ||
        width == null ||
        height == null ||
        width <= 0 ||
        height <= 0) {
      return const _SvgViewport(x: 0, y: 0, width: 210, height: 297);
    }
    return _SvgViewport(x: x, y: y, width: width, height: height);
  }

  final double x;
  final double y;
  final double width;
  final double height;

  double get aspectRatio => width / height;
}

class _DirectCaret {
  const _DirectCaret({
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

  _DirectCaret copyWith({
    int? pageIndex,
    int? sectionIndex,
    int? paragraphIndex,
    int? charOffset,
    double? x,
    double? y,
    double? height,
  }) {
    return _DirectCaret(
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

class _DocumentSummary extends StatelessWidget {
  const _DocumentSummary({required this.info, required this.status});

  final HwpDocumentInfo? info;
  final String status;

  @override
  Widget build(BuildContext context) {
    final HwpDocumentInfo? document = info;
    return ListTile(
      dense: true,
      leading: const Icon(Icons.description_outlined),
      title: Text(document?.fileName ?? 'HWP'),
      subtitle: Text(
        document == null
            ? status
            : '${document.engineVersion} · ${document.pageCount} trang · $status',
      ),
    );
  }
}

typedef HwpDiagnosticPage = HwpReaderPage;
