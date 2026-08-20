import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/pdf_viewer_bloc.dart';
import '../data/pdf_assets.dart';
import '../widgets/free_text_area_composer.dart';
import '../widgets/native_pdf_workspace.dart';
import '../widgets/pdf_bottom_tool_bar.dart';
import '../widgets/pdf_control_panel.dart';
import 'document_viewer_page.dart';
import 'pdf_page_reorder_page.dart';

class PdfViewerPage extends StatefulWidget {
  const PdfViewerPage({
    super.key,
    required this.assetKey,
    this.initialFilePath,
  });

  final String assetKey;

  /// When set, the workspace opens this file instead of the bundled asset.
  final String? initialFilePath;

  @override
  State<PdfViewerPage> createState() => _PdfViewerPageState();
}

class _PdfViewerPageState extends State<PdfViewerPage> {
  late final PdfViewerBloc _bloc;
  final TextEditingController _searchController = TextEditingController(
    text: 'document',
  );
  final TextEditingController _pageController = TextEditingController(
    text: '0',
  );
  final TextEditingController _freeTextController = TextEditingController(
    text: 'POC 0 free-text annotation',
  );
  final TextEditingController _selectedAreaTextController =
      TextEditingController();
  final FocusNode _selectedAreaTextFocusNode = FocusNode();
  PdfControlPanelMode? _activePanelMode;

  @override
  void initState() {
    super.initState();
    _bloc = PdfViewerBloc(
      assetKey: widget.assetKey,
      initialFilePath: widget.initialFilePath,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _bloc.add(const PdfViewerOpenRequested());
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _pageController.dispose();
    _freeTextController.dispose();
    _selectedAreaTextController.dispose();
    _selectedAreaTextFocusNode.dispose();
    _bloc.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider<PdfViewerBloc>.value(
      value: _bloc,
      child: BlocListener<PdfViewerBloc, PdfViewerState>(
        listenWhen: (previous, current) {
          final pendingVisibilityChanged =
              (previous.pendingFreeTextArea == null) !=
              (current.pendingFreeTextArea == null);
          final pageChanged =
              previous.documentInfo?.currentPageIndex !=
              current.documentInfo?.currentPageIndex;
          return pendingVisibilityChanged ||
              (current.pendingFreeTextArea == null && pageChanged);
        },
        listener: _handleStateSideEffects,
        child: BlocBuilder<PdfViewerBloc, PdfViewerState>(
          builder: (context, state) {
            return _buildScaffold(context, state);
          },
        ),
      ),
    );
  }

  void _handleStateSideEffects(BuildContext context, PdfViewerState state) {
    final pageIndex = state.documentInfo?.currentPageIndex;
    if (pageIndex != null && _pageController.text != pageIndex.toString()) {
      _pageController.text = pageIndex.toString();
    }

    if (state.pendingFreeTextArea != null &&
        !_selectedAreaTextFocusNode.hasFocus) {
      _selectedAreaTextController.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _selectedAreaTextFocusNode.requestFocus();
        }
      });
    }

    if (state.pendingFreeTextArea == null &&
        _selectedAreaTextController.text.isNotEmpty) {
      _selectedAreaTextController.clear();
      _selectedAreaTextFocusNode.unfocus();
    }
  }

  Widget _buildScaffold(BuildContext context, PdfViewerState state) {
    final info = state.documentInfo;
    final searchText = state.searchState == null
        ? 'No search'
        : '${state.searchState!.totalResults} results'
              '${state.searchState!.activeResultIndex >= 0 ? ', active ${state.searchState!.activeResultIndex}' : ''}';

    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: Text(assetName(widget.assetKey)),
        actions: <Widget>[
          IconButton(
            tooltip: 'Reset writable copy',
            onPressed: state.busy
                ? null
                : () => _bloc.add(const PdfViewerResetRequested()),
            icon: const Icon(Icons.restore_page_outlined),
          ),
          IconButton(
            tooltip: 'Save',
            onPressed: state.busy
                ? null
                : () => _bloc.add(const PdfViewerSaveRequested()),
            icon: const Icon(Icons.save_outlined),
          ),
        ],
      ),
      bottomNavigationBar: PdfBottomToolBar(
        activeMode: _activePanelMode,
        busy: state.busy,
        onModePressed: _togglePanelMode,
      ),
      body: Stack(
        children: <Widget>[
          SafeArea(
            bottom: false,
            child: Column(
              children: <Widget>[
                Expanded(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: Theme.of(context).dividerColor),
                    ),
                    child: const NativePdfWorkspace(),
                  ),
                ),
                // Edit text has no panel: the page itself shows every block
                // it will let you edit, and the typing happens up there.
                if (_activePanelMode != null &&
                    _activePanelMode != PdfControlPanelMode.textEdit)
                  PdfControlPanel(
                    mode: _activePanelMode!,
                    state: state,
                    totalPages: info?.pageCount,
                    searchText: searchText,
                    pageController: _pageController,
                    searchController: _searchController,
                    freeTextController: _freeTextController,
                    onJumpToPage: () => _bloc.add(
                      PdfViewerJumpToPageRequested(_pageController.text),
                    ),
                    onSearch: () => _bloc.add(
                      PdfViewerSearchRequested(_searchController.text),
                    ),
                    onAddFreeText: () => _bloc.add(
                      PdfViewerAddFixedFreeTextRequested(
                        pageText: _pageController.text,
                        text: _freeTextController.text,
                      ),
                    ),
                    onBeginFreeTextAreaSelection:
                        _beginFreeTextAreaSelectionFromUi,
                    onOpenPageReorder: _openPageReorderScreen,
                    onOpenDocumentViewer: _openDocumentViewerScreen,
                  ),
              ],
            ),
          ),
          if (state.pendingFreeTextArea != null)
            FreeTextAreaComposer(
              controller: _selectedAreaTextController,
              focusNode: _selectedAreaTextFocusNode,
              busy: state.busy,
              bottomInset: MediaQuery.viewInsetsOf(context).bottom,
              onCancel: () => _bloc.add(
                const PdfViewerCancelSelectedFreeTextAreaRequested(),
              ),
              onSubmit: () => _bloc.add(
                PdfViewerCommitSelectedFreeTextAreaRequested(
                  _selectedAreaTextController.text,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _beginFreeTextAreaSelectionFromUi() async {
    _selectedAreaTextFocusNode.unfocus();
    _bloc.add(const PdfViewerBeginFreeTextAreaSelectionRequested());
  }

  void _togglePanelMode(PdfControlPanelMode mode) {
    FocusScope.of(context).unfocus();
    final PdfControlPanelMode? next = _activePanelMode == mode ? null : mode;
    setState(() {
      _activePanelMode = next;
    });
    // Edit text has no arming step of its own: picking it in the bar arms the
    // page, leaving it disarms it, so a tap on a line means "edit this line"
    // exactly while the tool is the one selected.
    final bool wantTextEdit = next == PdfControlPanelMode.textEdit;
    if (wantTextEdit != _bloc.state.textEditModeEnabled) {
      _bloc.add(PdfViewerTextEditModeChanged(wantTextEdit));
    }
  }

  Future<void> _openDocumentViewerScreen() async {
    final document = _bloc.state.viewableDocument;
    if (document == null) {
      return;
    }
    FocusScope.of(context).unfocus();
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => BlocProvider<PdfViewerBloc>.value(
          value: _bloc,
          child: DocumentViewerPage(document: document),
        ),
      ),
    );
  }

  Future<void> _openPageReorderScreen() async {
    _selectedAreaTextFocusNode.unfocus();
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => BlocProvider<PdfViewerBloc>.value(
          value: _bloc,
          child: const PdfPageReorderPage(),
        ),
      ),
    );
  }
}
