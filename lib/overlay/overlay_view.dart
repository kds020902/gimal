import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:gimal/services/app_state_store.dart';

// 실제 오버레이 화면을 구성하는 파일이다.
// 상단 버튼 바, URL/북마크/메모/메뉴 패널과 오버레이 WebView를 제어한다.

// 상단 버튼에서 어떤 패널을 열지 구분하기 위한 값이다.
enum OverlayMode { url, bookmarks, memos, menu }

// 오버레이 전용 Flutter 앱이다. 메인 앱과 별도로 overlayMain에서 실행된다.
class OverlayApp extends StatelessWidget {
  const OverlayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Material(color: Colors.transparent, child: OverlayView()),
    );
  }
}

class OverlayView extends StatefulWidget {
  const OverlayView({super.key});

  @override
  State<OverlayView> createState() => _OverlayViewState();
}

class _OverlayViewState extends State<OverlayView> with WidgetsBindingObserver {
  // Android 네이티브 코드와 통신해서 웹뷰 오버레이, 앱 복귀 같은 기능을 실행한다.
  static const MethodChannel _utilsChannel = MethodChannel(
    'com.example.gimal/utils',
  );

  static const int _launcherWindowSize = 48;
  static const double _launcherIconSize = 42;
  static const int _portraitOverlayPanelHeight = 600;
  static const int _landscapeOverlayPanelHeight = 500;

  // URL 검색창과 메모 입력창에서 사용하는 컨트롤러이다.
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _memoTitleController = TextEditingController();
  final TextEditingController _memoContentController = TextEditingController();
  final ScrollController _bookmarkScrollController = ScrollController();
  final ScrollController _memoScrollController = ScrollController();
  Offset? _launcherOffset;
  StreamSubscription<dynamic>? _overlaySubscription;

  // 오버레이 화면의 현재 상태를 기억하는 값들이다.
  OverlayMode? _activeMode;
  int? _memoEditIndex;
  bool _stateLoaded = false;
  bool _webOpen = false;
  bool _isDark = false;
  bool _isClosing = false;
  bool _isCollapsed = false;
  bool _isChangingSize = false;
  bool _isUpdatingWebBounds = false;
  bool _lastLandscape = false;
  bool _memoEditorOpen = false;
  int? _lastWebTopOffset;
  List<Map<String, String>> _bookmarks = [];
  List<Map<String, String>> _memos = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // 메인 앱이나 다른 화면에서 데이터가 바뀌면 오버레이도 새 데이터를 다시 읽는다.
    _overlaySubscription = AppStateStore.stateEvents.listen((event) {
      if (event == AppStateStore.stateUpdatedEvent) {
        _activateOverlayWindowIfNeeded();
        _loadState();
      }
    });
    _utilsChannel.setMethodCallHandler(_handleUtilsCall);

    _loadState();
  }

  @override
  void dispose() {
    _isClosing = true;
    WidgetsBinding.instance.removeObserver(this);
    _overlaySubscription?.cancel();
    _searchController.dispose();
    _memoTitleController.dispose();
    _memoContentController.dispose();
    _bookmarkScrollController.dispose();
    _memoScrollController.dispose();
    _utilsChannel.setMethodCallHandler(null);
    super.dispose();
  }

  Future<void> _handleUtilsCall(MethodCall call) async {
    if (call.method == 'webOverlayClosed') {
      await _handleNativeWebClosed();
    }
  }

  Future<void> _handleNativeWebClosed() async {
    if (_isClosing || !mounted) return;
    setState(() => _webOpen = false);
    _lastWebTopOffset = null;
    await WidgetsBinding.instance.endOfFrame;
    if (!_isClosing && mounted) {
      await _resizeToExpandedOverlay();
    }
  }

  // 앱으로 돌아갔다가 다시 오버레이를 켤 때 남아 있을 수 있는 "닫히는 중" 상태를 초기화한다.
  void _activateOverlayWindowIfNeeded() {
    if (!_isClosing) return;
    _isClosing = false;
    _isChangingSize = false;
    _isCollapsed = false;
    _webOpen = false;
    _activeMode = null;
    _memoEditorOpen = false;
    _memoEditIndex = null;
    _launcherOffset = null;
    _lastWebTopOffset = null;
  }

  @override
  void didChangeMetrics() {
    // 화면 회전처럼 크기가 바뀌면 웹뷰 오버레이 위치만 다시 맞춘다.
    if (_isClosing) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (_isClosing || !mounted) return;
      if (_isCollapsed) {
        await _moveLauncherOverlay();
        return;
      }
      if (_webOpen) {
        await _updateWebOverlayBounds();
        return;
      }
      await _resizeToExpandedOverlay();
      await _updateWebOverlayBounds();
    });
  }

  // 저장소에서 북마크, 메모, 다크모드 값을 읽어 오버레이 상태에 반영한다.
  Future<void> _loadState() async {
    if (_isClosing) return;

    var bookmarks = _bookmarks.isEmpty
        ? AppStateStore.defaultBookmarks()
        : _bookmarks;
    var memos = _memos;
    var isDark = _isDark;

    try {
      bookmarks = await AppStateStore.loadBookmarks();
      memos = await AppStateStore.loadMemos();
      isDark = await AppStateStore.loadDarkMode();
    } catch (error) {
      debugPrint('load overlay state failed: $error');
    }

    if (_isClosing || !mounted) return;
    setState(() {
      _bookmarks = bookmarks;
      _memos = memos;
      _isDark = isDark;
      _stateLoaded = true;
    });
  }

  // "앱으로" 버튼을 눌렀을 때 웹뷰를 닫고 메인 앱을 앞으로 가져온 뒤 오버레이를 종료한다.
  Future<void> _returnToApp() async {
    FocusManager.instance.primaryFocus?.unfocus();
    _isClosing = true;
    _webOpen = false;
    _activeMode = null;

    try {
      await _closeNativeWeb();
      try {
        await _utilsChannel.invokeMethod('bringToFront');
      } catch (error) {
        debugPrint('bringToFront failed: $error');
      }
    } finally {
      await WidgetsBinding.instance.endOfFrame;
      try {
        await FlutterOverlayWindow.closeOverlay();
      } catch (error) {
        _isClosing = false;
        debugPrint('closeOverlay failed: $error');
      }
    }
  }

  // "닫기" 버튼을 누르면 오버레이를 끄지 않고 작은 아이콘 모드로 접는다.
  Future<void> _collapseToLauncher() async {
    FocusManager.instance.primaryFocus?.unfocus();
    if (_isClosing || _isChangingSize) return;
    _isChangingSize = true;

    try {
      await _closeNativeWeb();
      if (!mounted || _isClosing) return;

      setState(() {
        _isCollapsed = true;
        _webOpen = false;
        _activeMode = null;
        _memoEditorOpen = false;
        _memoEditIndex = null;
      });
      _lastWebTopOffset = null;

      await WidgetsBinding.instance.endOfFrame;
      final launcherOffset = _launcherOffset ?? _defaultLauncherOffset();
      _launcherOffset = launcherOffset;
      await FlutterOverlayWindow.resizeOverlay(
        _launcherWindowSize,
        _launcherWindowSize,
        true,
      );
      await FlutterOverlayWindow.moveOverlay(
        _overlayPositionFor(launcherOffset),
      );
    } catch (error) {
      debugPrint('collapseToLauncher failed: $error');
    } finally {
      _isChangingSize = false;
    }
  }

  // 작은 아이콘을 누르면 같은 오버레이 창을 다시 상단 위젯 모드로 펼친다.
  Future<void> _expandFromLauncher() async {
    if (_isClosing || _isChangingSize) return;
    _isChangingSize = true;

    try {
      setState(() => _isCollapsed = false);
      _lastWebTopOffset = null;
      await WidgetsBinding.instance.endOfFrame;
      await FlutterOverlayWindow.moveOverlay(OverlayPosition(0, 0));
      await _resizeToExpandedOverlay();
      await FlutterOverlayWindow.moveOverlay(OverlayPosition(0, 0));
    } catch (error) {
      debugPrint('expandFromLauncher failed: $error');
    } finally {
      _isChangingSize = false;
    }
  }

  Future<void> _resizeToExpandedOverlay() async {
    _lastWebTopOffset = null;
    await FlutterOverlayWindow.resizeOverlay(
      WindowSize.matchParent,
      _expandedOverlayHeight(),
      false,
    );
  }

  Future<void> _moveLauncherOverlay() async {
    final launcherOffset = _launcherOffset ?? _defaultLauncherOffset();
    _launcherOffset = launcherOffset;
    await FlutterOverlayWindow.moveOverlay(_overlayPositionFor(launcherOffset));
  }

  int _expandedOverlayHeight() {
    return _lastLandscape
        ? _landscapeOverlayPanelHeight
        : _portraitOverlayPanelHeight;
  }

  Offset _defaultLauncherOffset() {
    final media = MediaQuery.of(context);
    final x = ((media.size.width - _launcherWindowSize) / 2).clamp(
      0.0,
      media.size.width,
    );
    final y = media.padding.top + 24.0;
    return Offset(x.toDouble(), y);
  }

  OverlayPosition _overlayPositionFor(Offset offset) {
    return OverlayPosition(offset.dx, offset.dy);
  }

  void _moveLauncherByDrag(DragUpdateDetails details) {
    if (!_isCollapsed || _isClosing) return;

    final current = _launcherOffset ?? _defaultLauncherOffset();
    final nextX = current.dx + details.delta.dx;
    final nextY = current.dy + details.delta.dy;
    final nextOffset = Offset(nextX < 0 ? 0.0 : nextX, nextY < 0 ? 0.0 : nextY);

    _launcherOffset = nextOffset;
    unawaited(
      FlutterOverlayWindow.moveOverlay(_overlayPositionFor(nextOffset)),
    );
  }

  // 오버레이에서 다크모드를 바꾸고 저장소에 저장한다.
  Future<void> _toggleDarkMode() async {
    if (_isClosing) return;

    final nextValue = !_isDark;
    setState(() => _isDark = nextValue);
    await AppStateStore.saveDarkMode(nextValue);
  }

  // 상단의 URL, 북마크, 메모, 메뉴 버튼을 눌렀을 때 열 패널을 정한다.
  Future<void> _selectMode(OverlayMode mode) async {
    if (_isClosing) return;

    await _loadState();
    if (_isClosing || !mounted) return;

    final nextMode = _activeMode == mode ? null : mode;
    setState(() {
      _activeMode = nextMode;
      if (nextMode != OverlayMode.memos) {
        _memoEditorOpen = false;
        _memoEditIndex = null;
        _memoTitleController.clear();
        _memoContentController.clear();
      }
    });
    await _updateWebOverlayBounds();
  }

  // 검색어, URL, 북마크 주소를 Android WebView 오버레이로 연다.
  Future<void> _openWeb(String value) async {
    if (_isClosing) return;

    final url = _makeWebUrl(value);
    if (url.isEmpty) return;

    try {
      _lastLandscape = _isLandscapeScreen();
      setState(() {
        _webOpen = true;
        _searchController.text = url;
      });

      await WidgetsBinding.instance.endOfFrame;
      if (_isClosing || !mounted) return;

      final topOffset = _webTopOffset();
      await _resizeOverlayForWeb(topOffset);
      await _utilsChannel.invokeMethod('openWebOverlay', {
        'url': url,
        ..._webBounds(topOffset),
      });
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() => _webOpen = false);
      }
      _lastWebTopOffset = null;
      debugPrint('openWebOverlay failed: ${error.message}');
    }
  }

  // 웹뷰를 닫을 때 Android WebView 창만 제거하고 Flutter 오버레이 높이를 원래대로 돌린다.
  Future<void> _closeWeb() async {
    await _closeNativeWeb();
    if (_isClosing || !mounted) return;
    setState(() => _webOpen = false);
    _lastWebTopOffset = null;
    await WidgetsBinding.instance.endOfFrame;
    if (!_isClosing && mounted) {
      await _resizeToExpandedOverlay();
    }
  }

  // Android 쪽에 만들어둔 WebView 창을 제거한다.
  Future<void> _closeNativeWeb() async {
    try {
      await _utilsChannel.invokeMethod('closeWebOverlay');
    } catch (error) {
      debugPrint('closeWebOverlay failed: $error');
    }
  }

  // 메모 추가 또는 수정 입력창을 오버레이 패널 안에 연다.
  Future<void> _openMemoEditor({int? index}) async {
    if (index != null && (index < 0 || index >= _memos.length)) {
      return;
    }

    final memo = index == null ? null : _memos[index];
    setState(() {
      _memoEditIndex = index;
      _memoEditorOpen = true;
      _memoTitleController.text = memo?['title'] ?? '';
      _memoContentController.text = memo?['content'] ?? '';
    });
    await _updateWebOverlayBounds();
  }

  // 메모 입력창을 닫고 입력값과 수정 위치를 초기화한다.
  void _closeMemoEditor() {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _memoEditorOpen = false;
      _memoEditIndex = null;
      _memoTitleController.clear();
      _memoContentController.clear();
    });
  }

  Future<void> _cancelMemoEditor() async {
    _closeMemoEditor();
    await _updateWebOverlayBounds();
  }

  // 메모 입력창의 내용을 새 메모로 추가하거나 기존 메모에 덮어쓴다.
  Future<void> _saveMemoEditor() async {
    final title = _memoTitleController.text.trim();
    final content = _memoContentController.text.trim();
    if (title.isEmpty && content.isEmpty) return;

    final nextMemos = List<Map<String, String>>.from(_memos);
    final savedMemo = {
      'title': title.isEmpty ? '메모' : title,
      'content': content,
    };

    final editIndex = _memoEditIndex;
    if (editIndex == null) {
      nextMemos.add(savedMemo);
    } else if (editIndex >= 0 && editIndex < nextMemos.length) {
      nextMemos[editIndex] = savedMemo;
    } else {
      _closeMemoEditor();
      return;
    }

    _closeMemoEditor();
    await _saveOverlayMemos(nextMemos);
  }

  // 수정 중이던 메모를 목록에서 삭제한다.
  Future<void> _deleteMemoEditor() async {
    final editIndex = _memoEditIndex;
    if (editIndex == null) {
      _closeMemoEditor();
      return;
    }
    if (editIndex < 0 || editIndex >= _memos.length) {
      _closeMemoEditor();
      return;
    }

    final nextMemos = List<Map<String, String>>.from(_memos)
      ..removeAt(editIndex);

    _closeMemoEditor();
    await _saveOverlayMemos(nextMemos);
  }

  // 오버레이 안의 메모 목록을 먼저 갱신하고, 저장소에도 같은 내용을 저장한다.
  Future<void> _saveOverlayMemos(List<Map<String, String>> memos) async {
    if (_isClosing || !mounted) return;
    setState(() => _memos = memos);
    await AppStateStore.saveMemos(memos);
    if (_isClosing || !mounted) return;
    await _updateWebOverlayBounds();
  }

  // 웹뷰가 열려 있을 때 상단 패널 높이에 맞춰 웹뷰 위치와 크기를 다시 계산한다.
  Future<void> _updateWebOverlayBounds() async {
    if (_isClosing || !_webOpen || !mounted || _isUpdatingWebBounds) return;
    _isUpdatingWebBounds = true;

    try {
      await WidgetsBinding.instance.endOfFrame;
      if (_isClosing || !_webOpen || !mounted) return;
      final topOffset = _webTopOffset();
      await _resizeOverlayForWeb(topOffset);
      await _utilsChannel.invokeMethod(
        'updateWebOverlayBounds',
        _webBounds(topOffset),
      );
    } catch (error) {
      debugPrint('updateWebOverlayBounds failed: $error');
    } finally {
      _isUpdatingWebBounds = false;
    }
  }

  Future<void> _resizeOverlayForWeb([int? topOffset]) async {
    final nextTopOffset = topOffset ?? _webTopOffset();
    if (_lastWebTopOffset != nextTopOffset) {
      await FlutterOverlayWindow.resizeOverlay(
        WindowSize.matchParent,
        nextTopOffset,
        false,
      );
      _lastWebTopOffset = nextTopOffset;
    }
    await FlutterOverlayWindow.moveOverlay(OverlayPosition(0, 0));
  }

  // Android WebView 오버레이에 넘겨줄 x, y, width, height 값을 만든다.
  Map<String, int> _webBounds([int? topOffset]) {
    final media = MediaQuery.of(context);

    return {
      'x': 0,
      'y': topOffset ?? _webTopOffset(),
      'width': media.size.width.ceil(),
      'height': -1,
    };
  }

  // 메인 위젯 바로 아래에서 Android WebView 창이 시작하도록 y 위치를 구한다.
  int _webTopOffset() {
    final media = MediaQuery.of(context);
    final isLandscape = _isLandscapeScreen();
    var height = media.padding.top + 8;
    height += _mainWidgetHeight(isLandscape);

    return height.ceil();
  }

  double _mainWidgetHeight(bool compact) {
    final buttonBarHeight = compact ? 54.0 : 58.0;
    var height = buttonBarHeight;
    if (_activeMode != null) {
      final panelPadding = compact ? 16.0 : 20.0;
      height += 1 + panelPadding + _activePanelHeight(compact);
    }
    return height;
  }

  double _activePanelHeight(bool compact) {
    if (_activeMode == OverlayMode.bookmarks) {
      return _bookmarkPanelHeight(compact);
    }
    if (_activeMode == OverlayMode.memos) {
      return _memoPanelHeight(compact);
    }
    return 42;
  }

  // 현재 화면이 가로 방향인지 세로 방향인지 판단한다.
  bool _isLandscapeScreen() {
    if (_webOpen) return _lastLandscape;
    final size = MediaQuery.sizeOf(context);
    return size.width > size.height;
  }

  double _bookmarkPanelHeight(bool compact) {
    return compact ? 120 : 188;
  }

  // 메모 목록과 메모 편집창은 필요한 높이가 달라서 상태에 따라 높이를 바꾼다.
  double _memoPanelHeight(bool compact) {
    if (_memoEditorOpen) {
      return compact ? 146 : 188;
    }
    return compact ? 120 : 188;
  }

  // URL 패널의 이동 버튼이나 키보드 제출이 눌렸을 때 웹을 연다.
  Future<void> _searchUrl() async {
    await _openWeb(_searchController.text);
  }

  // 입력값이 주소면 주소로, 일반 단어면 구글 검색 주소로 바꾼다.
  String _makeWebUrl(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }
    if (trimmed.contains('.') && !trimmed.contains(' ')) {
      return 'https://$trimmed';
    }
    return 'https://www.google.com/search?q=${Uri.encodeQueryComponent(trimmed)}';
  }

  @override
  Widget build(BuildContext context) {
    if (!_stateLoaded) {
      return const ColoredBox(
        color: Color(0xCC020617),
        child: Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
        ),
      );
    }

    if (_isCollapsed) {
      return Center(child: _buildLauncherIcon());
    }

    return _buildExpandedOverlay();
  }

  // 펼쳐진 오버레이에서는 배경을 깔지 않고 상단 탭 패널만 고정해서 보여준다.
  Widget _buildExpandedOverlay() {
    final isLandscape = _isLandscapeScreen();
    _lastLandscape = isLandscape;
    final maxPanelHeight = _maxPanelHeight();

    return SizedBox.expand(
      child: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              isLandscape ? 10 : 8,
              8,
              isLandscape ? 10 : 8,
              0,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxPanelHeight),
              child: SingleChildScrollView(
                padding: EdgeInsets.zero,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [_buildTopOverlayPanel(isLandscape: isLandscape)],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLauncherIcon() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _expandFromLauncher,
      onPanUpdate: _moveLauncherByDrag,
      child: Container(
        width: _launcherIconSize,
        height: _launcherIconSize,
        decoration: BoxDecoration(
          color: _accentColor,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 1),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 8,
              offset: Offset(0, 3),
            ),
          ],
        ),
        child: const Icon(Icons.layers, color: Colors.white, size: 18),
      ),
    );
  }

  double _maxPanelHeight() {
    if (_webOpen) {
      return _mainWidgetHeight(_isLandscapeScreen());
    }

    final media = MediaQuery.of(context);
    final height =
        media.size.height - media.padding.top - media.padding.bottom - 8;
    return height < 0 ? 0.0 : height;
  }

  // 상단 버튼 바, 웹뷰 조작 바, 선택된 기능 패널을 한 덩어리로 묶는다.
  Widget _buildTopOverlayPanel({required bool isLandscape}) {
    final textColor = _textColor;
    final mutedColor = _mutedColor;

    return Container(
      width: double.infinity,
      decoration: _panelDecoration,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildButtonBar(isLandscape: isLandscape),
          if (_activeMode != null) ...[
            Divider(height: 1, color: _borderColor),
            Padding(
              padding: EdgeInsets.all(isLandscape ? 8 : 10),
              child: _buildActivePanel(
                textColor: textColor,
                mutedColor: mutedColor,
                isLandscape: isLandscape,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // URL, 북마크, 메모, 메뉴 버튼이 있는 가장 위쪽 버튼 구역이다.
  Widget _buildButtonBar({required bool isLandscape}) {
    return Padding(
      padding: EdgeInsets.all(isLandscape ? 6 : 8),
      child: Row(
        children: [
          Expanded(
            child: _barButton(
              mode: OverlayMode.url,
              icon: Icons.search,
              label: 'URL',
              onPressed: () => _selectMode(OverlayMode.url),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _barButton(
              mode: OverlayMode.bookmarks,
              icon: Icons.bookmark_border,
              label: '북마크',
              onPressed: () => _selectMode(OverlayMode.bookmarks),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _barButton(
              mode: OverlayMode.memos,
              icon: Icons.note_alt_outlined,
              label: '메모',
              onPressed: () => _selectMode(OverlayMode.memos),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(child: _menuButton()),
        ],
      ),
    );
  }

  // URL, 북마크, 메모처럼 선택 상태가 있는 버튼을 만드는 공통 함수이다.
  Widget _barButton({
    required OverlayMode mode,
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    final selected = _activeMode == mode;

    return SizedBox(
      height: 42,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: selected ? _accentColor : _inactiveButtonColor,
          foregroundColor: selected ? Colors.white : _accentColor,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  // 메뉴 버튼은 글자 대신 목록 아이콘만 보여주는 버튼이다.
  Widget _menuButton() {
    final selected = _activeMode == OverlayMode.menu;

    return SizedBox(
      height: 42,
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: selected ? _accentColor : _inactiveButtonColor,
          foregroundColor: selected ? Colors.white : _accentColor,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        onPressed: () => _selectMode(OverlayMode.menu),
        child: const Icon(Icons.list, size: 20),
      ),
    );
  }

  // 현재 선택된 상단 버튼에 따라 URL, 북마크, 메모, 메뉴 패널 중 하나를 보여준다.
  Widget _buildActivePanel({
    required Color textColor,
    required Color mutedColor,
    required bool isLandscape,
  }) {
    if (_activeMode == OverlayMode.url) {
      return _buildUrlPanel(textColor, mutedColor);
    }
    if (_activeMode == OverlayMode.bookmarks) {
      return _buildBookmarkPanel(textColor, mutedColor, compact: isLandscape);
    }
    if (_activeMode == OverlayMode.memos) {
      return _buildMemoPanel(compact: isLandscape);
    }
    if (_activeMode == OverlayMode.menu) {
      return _buildMenuPanel();
    }
    return const SizedBox.shrink();
  }

  // 메뉴 패널에는 앱으로, 닫기, 다크모드 버튼을 배치한다.
  Widget _buildMenuPanel() {
    return Row(
      children: [
        Expanded(
          child: _menuActionButton(
            icon: Icons.home,
            label: '앱으로',
            onPressed: _returnToApp,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _menuActionButton(
            icon: Icons.keyboard_arrow_up,
            label: '닫기',
            onPressed: _collapseToLauncher,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _menuActionButton(
            icon: _isDark ? Icons.light_mode : Icons.dark_mode,
            label: '다크모드',
            onPressed: _toggleDarkMode,
          ),
        ),
      ],
    );
  }

  // 작은 텍스트 버튼을 반복해서 만들기 위한 공통 함수이다.
  Widget _smallTextButton(
    String label,
    VoidCallback onPressed, {
    bool danger = false,
    double width = 52,
  }) {
    return SizedBox(
      width: width,
      height: 42,
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: danger ? Colors.redAccent : _accentColor,
          foregroundColor: Colors.white,
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        onPressed: onPressed,
        child: Text(
          label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  // 메뉴 패널의 아이콘+텍스트 버튼을 만드는 공통 함수이다.
  Widget _menuActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      height: 42,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: _isDark
              ? const Color(0xFF334155)
              : const Color(0xFFE2E8F0),
          foregroundColor: _textColor,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  // URL 또는 검색어를 입력하는 패널이다.
  Widget _buildUrlPanel(Color textColor, Color mutedColor) {
    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 42,
            child: TextField(
              controller: _searchController,
              style: TextStyle(color: textColor, fontSize: 14),
              textInputAction: TextInputAction.search,
              decoration: _fieldDecoration(
                'URL 또는 검색어',
                Icons.search,
                mutedColor,
              ),
              onSubmitted: (_) => _searchUrl(),
            ),
          ),
        ),
        const SizedBox(width: 8),
        _iconAction(Icons.arrow_forward, _searchUrl),
      ],
    );
  }

  // 저장된 북마크를 보여주고, 누르면 오버레이 WebView로 연다.
  Widget _buildBookmarkPanel(
    Color textColor,
    Color mutedColor, {
    required bool compact,
  }) {
    if (_bookmarks.isEmpty) {
      return _buildHintLine('저장된 북마크가 없습니다.', mutedColor);
    }

    return SizedBox(
      height: _bookmarkPanelHeight(compact),
      child: Scrollbar(
        controller: _bookmarkScrollController,
        thumbVisibility: true,
        child: ListView.builder(
          controller: _bookmarkScrollController,
          itemCount: _bookmarks.length,
          itemBuilder: (context, index) {
            final item = _bookmarks[index];
            final title = item['title']?.trim().isNotEmpty == true
                ? item['title']!.trim()
                : '북마크';
            final url = item['url']?.trim().isNotEmpty == true
                ? item['url']!.trim()
                : title;

            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: _surfaceColor,
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => _openWeb(url),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.open_in_new,
                          color: Colors.amber,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: textColor,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              if (!compact)
                                Text(
                                  url,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: mutedColor),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  // 메모 목록 또는 메모 편집창을 보여주는 패널이다.
  Widget _buildMemoPanel({required bool compact}) {
    if (_memoEditorOpen) {
      return SizedBox(
        height: _memoPanelHeight(compact),
        child: _buildMemoEditor(),
      );
    }

    return SizedBox(
      height: _memoPanelHeight(compact),
      child: Scrollbar(
        controller: _memoScrollController,
        thumbVisibility: true,
        child: ListView.builder(
          controller: _memoScrollController,
          itemCount: _memos.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return _memoTile(
                compact: compact,
                icon: Icons.add,
                title: '메모 추가',
                content: _memos.isEmpty ? '저장된 메모가 없습니다.' : '새 메모 작성',
                onTap: () => _openMemoEditor(),
              );
            }

            final memoIndex = index - 1;
            final memo = _memos[memoIndex];
            final title = memo['title']?.isNotEmpty == true
                ? memo['title']!
                : '메모';
            final content = memo['content']?.isNotEmpty == true
                ? memo['content']!
                : '메모 내용이 없습니다.';

            return _memoTile(
              compact: compact,
              icon: Icons.note,
              title: title,
              content: content,
              onTap: () => _openMemoEditor(index: memoIndex),
            );
          },
        ),
      ),
    );
  }

  // 메모 추가/수정 시 패널 안에 표시되는 입력창이다.
  Widget _buildMemoEditor() {
    return Material(
      color: _surfaceColor,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            SizedBox(
              height: 38,
              child: TextField(
                controller: _memoTitleController,
                style: TextStyle(color: _textColor, fontSize: 14),
                decoration: _fieldDecoration('제목', Icons.title, _mutedColor),
              ),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: TextField(
                controller: _memoContentController,
                style: TextStyle(color: _textColor, fontSize: 14),
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                decoration: _fieldDecoration(
                  '내용',
                  Icons.note_alt_outlined,
                  _mutedColor,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                if (_memoEditIndex != null) ...[
                  _smallTextButton(
                    '삭제',
                    () => _deleteMemoEditor(),
                    danger: true,
                    width: 48,
                  ),
                  const SizedBox(width: 6),
                ],
                const Spacer(),
                _smallTextButton('취소', _cancelMemoEditor, width: 48),
                const SizedBox(width: 6),
                _smallTextButton('저장', () => _saveMemoEditor(), width: 48),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // 메모 목록에서 한 개의 메모를 카드처럼 보여주는 타일이다.
  Widget _memoTile({
    required bool compact,
    required IconData icon,
    required String title,
    required String content,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: _surfaceColor,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                Icon(icon, color: _accentColor, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _textColor,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        content,
                        maxLines: compact ? 1 : 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: _mutedColor, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // 아이콘만 들어가는 작은 실행 버튼을 만드는 공통 함수이다.
  Widget _iconAction(IconData icon, VoidCallback onPressed) {
    return SizedBox(
      width: 42,
      height: 42,
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: _accentColor,
          foregroundColor: Colors.white,
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        onPressed: onPressed,
        child: Icon(icon, size: 19),
      ),
    );
  }

  // 목록이 비어 있을 때 보여주는 짧은 안내 문구이다.
  Widget _buildHintLine(String message, Color mutedColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(message, style: TextStyle(color: mutedColor)),
      ),
    );
  }

  // 오버레이 안의 TextField들이 같은 모양을 가지도록 만든 입력창 장식이다.
  InputDecoration _fieldDecoration(
    String hint,
    IconData icon,
    Color mutedColor,
  ) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: mutedColor),
      prefixIcon: Icon(icon, color: mutedColor, size: 20),
      filled: true,
      fillColor: _surfaceColor,
      contentPadding: EdgeInsets.zero,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
    );
  }

  // 상단 패널의 배경, 테두리, 그림자 스타일을 한곳에서 관리한다.
  BoxDecoration get _panelDecoration => BoxDecoration(
    color: _panelColor,
    borderRadius: BorderRadius.circular(12),
    border: Border.all(color: _borderColor),
    boxShadow: const [
      BoxShadow(color: Color(0x33000000), blurRadius: 16, offset: Offset(0, 6)),
    ],
  );

  // 오버레이에서 반복해서 사용하는 색상 값들이다.
  Color get _accentColor => const Color(0xFF14B8A6);
  Color get _panelColor =>
      _isDark ? const Color(0xEE0F172A) : const Color(0xDDF8FAFC);
  Color get _surfaceColor =>
      _isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9);
  Color get _inactiveButtonColor =>
      _isDark ? const Color(0x3314B8A6) : const Color(0x1A14B8A6);
  Color get _borderColor =>
      _isDark ? const Color(0x3345F3E5) : const Color(0xFFE2E8F0);
  Color get _textColor => _isDark ? Colors.white : const Color(0xFF0F172A);
  Color get _mutedColor =>
      _isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
}
