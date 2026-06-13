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
  // Android 네이티브 코드와 통신해서 메인 앱을 다시 앞으로 가져온다.
  static const MethodChannel _utilsChannel = MethodChannel(
    'com.example.gimal/utils',
  );

  static const int _launcherWindowSize = 48;
  static const double _launcherIconSize = 42;
  // URL 검색창과 메모 입력창에서 사용하는 컨트롤러이다.
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _memoTitleController = TextEditingController();
  final TextEditingController _memoContentController = TextEditingController();
  final TextEditingController _bookmarkTitleController = TextEditingController();
  final TextEditingController _bookmarkUrlController = TextEditingController();
  final ScrollController _bookmarkScrollController = ScrollController();
  final ScrollController _memoScrollController = ScrollController();
  // URL/검색 입력칸에 자동 포커스(키보드 자동 표시)를 주기 위한 노드이다.
  final FocusNode _searchFocusNode = FocusNode();
  final FocusNode _bookmarkTitleFocusNode = FocusNode();
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
  bool _lastLandscape = false;
  bool _memoEditorOpen = false;
  bool _bookmarkEditorOpen = false;
  // 웹뷰만 접어둔 상태(컨트롤 스트립은 남고 네이티브 웹뷰 창만 잠시 숨김).
  bool _webFolded = false;
  bool _didInitialSync = false;
  // 현재 오버레이 창에 적용된 포커스 플래그. show 시점과 동일하게 시작한다.
  OverlayFlag _currentFlag = OverlayFlag.defaultFlag;
  // 회전을 반영한 실제 화면 크기(physical px). 네이티브에서 받아 캐시한다.
  // (ui.Display.size는 회전을 반영하지 않아 가로모드에서 폭이 틀어진다.)
  double _screenWidthPx = 0;
  double _screenHeightPx = 0;
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
    _loadState();
  }

  @override
  void dispose() {
    _isClosing = true;
    _hideNativeWeb();
    WidgetsBinding.instance.removeObserver(this);
    _overlaySubscription?.cancel();
    _searchController.dispose();
    _memoTitleController.dispose();
    _memoContentController.dispose();
    _bookmarkTitleController.dispose();
    _bookmarkUrlController.dispose();
    _searchFocusNode.dispose();
    _bookmarkTitleFocusNode.dispose();
    _bookmarkScrollController.dispose();
    _memoScrollController.dispose();
    super.dispose();
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
    _hideNativeWeb();
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
        await _resizeToExpandedOverlay();
        return;
      }
      await _resizeToExpandedOverlay();
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

    // 처음 표시될 때 창은 전체화면으로 떠 있다. 첫 프레임 뒤에 내용 크기로 줄여서
    // 바 아래 화면(게임 등)을 조작할 수 있게 한다(최초 1회만).
    if (!_didInitialSync && !_isCollapsed) {
      _didInitialSync = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_isClosing && mounted && !_isCollapsed) {
          _resizeToExpandedOverlay();
        }
      });
    }
  }

  // "앱으로" 버튼을 눌렀을 때 웹뷰를 닫고 메인 앱을 앞으로 가져온 뒤 오버레이를 종료한다.
  Future<void> _returnToApp() async {
    FocusManager.instance.primaryFocus?.unfocus();
    _isClosing = true;
    _webOpen = false;
    _activeMode = null;
    await _hideNativeWeb();

    try {
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

  // "접기" 버튼을 누르면 오버레이를 끄지 않고 작은 아이콘 모드로 접는다.
  Future<void> _collapseToLauncher() async {
    FocusManager.instance.primaryFocus?.unfocus();
    if (_isClosing || _isChangingSize) return;
    _isChangingSize = true;

    try {
      if (!mounted || _isClosing) return;

      final wasWebOpen = _webOpen;
      setState(() {
        _isCollapsed = true;
        _activeMode = null;
        _memoEditorOpen = false;
        _memoEditIndex = null;
        _bookmarkEditorOpen = false;
      });

      // 접기는 웹뷰를 끄지 않는다: 열려 있으면 창에서만 떼고(인스턴스·로딩 유지),
      // _webOpen은 그대로 둬서 펼칠 때 다시 띄운다. 입력이 없으니 포커스도 되돌린다.
      if (wasWebOpen) {
        await _detachNativeWeb();
      }
      await _applyDesiredFlag();
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
      await WidgetsBinding.instance.endOfFrame;
      await FlutterOverlayWindow.moveOverlay(OverlayPosition(0, 0));
      await _resizeToExpandedOverlay();
      await FlutterOverlayWindow.moveOverlay(OverlayPosition(0, 0));
      // 접어둔 웹뷰가 있으면 같은 인스턴스로 다시 띄운다(웹뷰만 접어둔 상태면 제외).
      if (_webOpen && !_webFolded) {
        await _reattachNativeWeb();
      }
    } catch (error) {
      debugPrint('expandFromLauncher failed: $error');
    } finally {
      _isChangingSize = false;
    }
  }

  // Flutter 오버레이 창(컨트롤 UI)을 현재 상태에 맞춰 다시 잡는다.
  // - 플래그: URL/메모 입력이나 웹뷰일 때만 focusPointer(키보드 가능), 그 외에는
  //   defaultFlag(NOT_FOCUSABLE)로 둬서 뒤로가기와 바 바깥 터치가 아래 앱으로 통과한다.
  // - 크기: 항상 상단 바/패널(+웹뷰일 땐 컨트롤바) 높이만큼만 띄운다. 실제 웹 내용은
  //   네이티브 WebView 창이 이 스트립 아래에 따로 깔리므로 여기서 전체화면을 쓰지 않는다.
  // 주의: 이 플러그인(0.5.0)의 resizeOverlay는 height에 matchParent(-1)를 넘기면 내부
  //   버그로 창이 수백만 px가 되어 Vulkan 할당 중 앱이 죽으므로, 항상 실제 px를 넘긴다.
  Future<void> _resizeToExpandedOverlay() async {
    if (_isClosing || !mounted) return;

    await _refreshScreenSize();
    await _applyDesiredFlag();
    if (_isClosing || !mounted) return;

    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final dpr = view.devicePixelRatio;
    final topInset = view.padding.top / dpr;
    final compact = _isLandscapeScreen();
    // 네이티브 화면 크기 캐시가 아직 없으면 ui.Display.size로 폴백(폭 0 방지).
    final screenWidthPx = _screenWidthPx > 0
        ? _screenWidthPx
        : view.display.size.width;
    final width = (screenWidthPx / dpr).round();
    final height = _webOpen
        ? _webStripHeight(topInset, compact).ceil()
        : (topInset + 16 + _mainWidgetHeight(compact)).ceil();

    await FlutterOverlayWindow.resizeOverlay(width, height, false);
    await FlutterOverlayWindow.moveOverlay(OverlayPosition(0, 0));
    if (_webOpen) {
      await _updateNativeWebBounds();
    }
  }

  // 회전을 반영한 실제 화면 크기를 네이티브에서 받아 캐시한다.
  Future<void> _refreshScreenSize() async {
    try {
      final size = await _utilsChannel.invokeMethod('getScreenSize');
      if (size is Map) {
        final w = (size['width'] as num?)?.toDouble() ?? 0;
        final h = (size['height'] as num?)?.toDouble() ?? 0;
        if (w > 0 && h > 0) {
          _screenWidthPx = w;
          _screenHeightPx = h;
        }
      }
    } catch (error) {
      debugPrint('getScreenSize failed: $error');
    }
  }

  // 웹뷰가 열렸을 때 Flutter 컨트롤 스트립의 높이(logical). 이 아래부터 네이티브 웹뷰.
  double _webStripHeight(double topInset, bool compact) =>
      topInset + 8 + _mainWidgetHeight(compact) + 6 + 58 + 8;

  // 네이티브 WebView 창이 차지할 영역(physical px): 스트립 아래 ~ 화면 끝.
  (int, int, int, int) _webBoundsPx() {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final dpr = view.devicePixelRatio;
    final topInset = view.padding.top / dpr;
    final compact = _isLandscapeScreen();
    final stripPx = (_webStripHeight(topInset, compact) * dpr).round();
    final screenW =
        (_screenWidthPx > 0 ? _screenWidthPx : view.display.size.width).round();
    final screenH =
        (_screenHeightPx > 0 ? _screenHeightPx : view.display.size.height)
            .round();
    return (0, stripPx, screenW, screenH - stripPx);
  }

  // 접기: 네이티브 웹뷰 창을 떼되 인스턴스(로딩 상태)는 유지한다.
  Future<void> _detachNativeWeb() async {
    try {
      await _utilsChannel.invokeMethod('detachWebOverlay');
    } catch (error) {
      debugPrint('detachWebOverlay failed: $error');
    }
  }

  // 펼치기: 접어둔 웹뷰를 같은 인스턴스 그대로 다시 띄운다.
  Future<void> _reattachNativeWeb() async {
    final (x, y, w, h) = _webBoundsPx();
    try {
      await _utilsChannel.invokeMethod('reattachWebOverlay', {
        'x': x,
        'y': y,
        'width': w,
        'height': h,
      });
    } catch (error) {
      debugPrint('reattachWebOverlay failed: $error');
    }
  }

  // 네이티브 WebView 창을 띄우고 url을 로드한다.
  Future<void> _showNativeWeb(String url) async {
    final (x, y, w, h) = _webBoundsPx();
    try {
      await _utilsChannel.invokeMethod('showWebOverlay', {
        'url': url,
        'x': x,
        'y': y,
        'width': w,
        'height': h,
      });
    } catch (error) {
      debugPrint('showWebOverlay failed: $error');
    }
  }

  // 스트립 높이가 바뀌면(패널 열고 닫기 등) 네이티브 웹뷰 위치/크기도 맞춘다.
  Future<void> _updateNativeWebBounds() async {
    if (!_webOpen) return;
    final (x, y, w, h) = _webBoundsPx();
    try {
      await _utilsChannel.invokeMethod('setWebOverlayBounds', {
        'x': x,
        'y': y,
        'width': w,
        'height': h,
      });
    } catch (error) {
      debugPrint('setWebOverlayBounds failed: $error');
    }
  }

  // 네이티브 WebView 창을 닫는다.
  Future<void> _hideNativeWeb() async {
    try {
      await _utilsChannel.invokeMethod('hideWebOverlay');
    } catch (error) {
      debugPrint('hideWebOverlay failed: $error');
    }
  }

  // 현재 상태에 맞는 포커스 플래그를 적용한다(바뀔 때만 네이티브 호출).
  // 접힌 상태(런처 아이콘)에서는 입력이 없으므로 항상 defaultFlag.
  Future<void> _applyDesiredFlag() async {
    // 키보드 입력이 필요한 패널이 열려 있거나, 웹뷰가 펼쳐져 있을 때만 focusPointer.
    // 웹뷰를 접어두고 게임을 조작할 땐 defaultFlag여야 뒤로가기·터치가 게임으로 간다.
    final wantsInput =
        _activeMode == OverlayMode.url ||
        _memoEditorOpen ||
        _bookmarkEditorOpen;
    final webShown = _webOpen && !_webFolded;
    final desired = (!_isCollapsed && (wantsInput || webShown))
        ? OverlayFlag.focusPointer
        : OverlayFlag.defaultFlag;
    if (desired == _currentFlag) return;
    _currentFlag = desired;
    try {
      await FlutterOverlayWindow.updateFlag(desired);
    } catch (error) {
      debugPrint('updateFlag failed: $error');
    }
  }

  Future<void> _moveLauncherOverlay() async {
    final launcherOffset = _launcherOffset ?? _defaultLauncherOffset();
    _launcherOffset = launcherOffset;
    await FlutterOverlayWindow.moveOverlay(_overlayPositionFor(launcherOffset));
  }

  // 런처 아이콘을 드래그한 만큼 오버레이 창을 움직인다(화면 밖으로 안 나가게 제한).
  void _onLauncherDrag(DragUpdateDetails details) {
    if (_isClosing) return;
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final dpr = view.devicePixelRatio;
    final screenW =
        (_screenWidthPx > 0 ? _screenWidthPx : view.display.size.width) / dpr;
    final screenH =
        (_screenHeightPx > 0 ? _screenHeightPx : view.display.size.height) / dpr;
    final base = _launcherOffset ?? _defaultLauncherOffset();
    final next = Offset(
      (base.dx + details.delta.dx).clamp(
        0.0,
        (screenW - _launcherWindowSize).clamp(0.0, screenW),
      ),
      (base.dy + details.delta.dy).clamp(
        0.0,
        (screenH - _launcherWindowSize).clamp(0.0, screenH),
      ),
    );
    _launcherOffset = next;
    FlutterOverlayWindow.moveOverlay(_overlayPositionFor(next));
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
      if (nextMode != OverlayMode.bookmarks) {
        _bookmarkEditorOpen = false;
        _bookmarkTitleController.clear();
        _bookmarkUrlController.clear();
      }
    });
    await _resizeToExpandedOverlay();
    // URL 패널을 열면 입력칸에 자동 포커스해 키보드가 바로 뜨게 한다.
    if (_activeMode == OverlayMode.url) {
      _focusSearchSoon();
    }
  }

  // 입력이 필요한 순간 키보드가 자동으로 뜨도록 다음 프레임에 입력칸에 포커스를 준다.
  // (창 플래그가 focusPointer로 바뀐 뒤여야 키보드가 떠서 resize 이후에 호출한다.)
  void _focusSearchSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_isClosing && mounted) _searchFocusNode.requestFocus();
    });
  }

  // 검색어, URL, 북마크 주소를 네이티브 WebView 오버레이 창으로 연다.
  // (Flutter 오버레이 엔진은 Service라 Flutter WebView가 동작하지 않으므로 네이티브 사용)
  Future<void> _openWeb(String value) async {
    if (_isClosing) return;

    final url = _makeWebUrl(value);
    if (url.isEmpty) return;

    _lastLandscape = _isLandscapeScreen();
    setState(() {
      _webOpen = true;
      _webFolded = false;
      // 웹뷰를 열면 열려 있던 패널/편집창은 닫아 스트립을 짧게 유지한다.
      _activeMode = null;
      _memoEditorOpen = false;
      _bookmarkEditorOpen = false;
      _searchController.text = url;
    });

    await WidgetsBinding.instance.endOfFrame;
    if (_isClosing || !mounted) return;
    // 컨트롤 스트립을 먼저 자리잡은 뒤, 그 아래에 네이티브 웹뷰를 깐다.
    await _resizeToExpandedOverlay();
    if (_isClosing || !mounted) return;
    await _showNativeWeb(url);
  }

  // 컨트롤바 X: 네이티브 웹뷰 창을 완전히 닫고 컨트롤 스트립 크기를 다시 줄인다.
  Future<void> _closeWeb() async {
    if (_isClosing || !mounted) return;
    await _hideNativeWeb();
    setState(() {
      _webOpen = false;
      _webFolded = false;
    });
    await WidgetsBinding.instance.endOfFrame;
    if (!_isClosing && mounted) {
      await _resizeToExpandedOverlay();
    }
  }

  // 컨트롤바 접기/펼치기: 웹뷰 창만 잠시 접거나(끄지 않고) 다시 띄운다.
  // 접으면 상단 컨트롤 스트립만 남아 그 아래 화면(게임 등)을 조작할 수 있다.
  Future<void> _toggleWebFold() async {
    if (_isClosing || !_webOpen) return;
    if (_webFolded) {
      setState(() => _webFolded = false);
      await _resizeToExpandedOverlay();
      if (_isClosing || !mounted) return;
      await _reattachNativeWeb();
    } else {
      await _detachNativeWeb();
      setState(() => _webFolded = true);
      await _resizeToExpandedOverlay();
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
      _memoTitleController.text = memo?['제목'] ?? '';
      _memoContentController.text = memo?['내용'] ?? '';
    });
    await _resizeToExpandedOverlay();
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
    await _resizeToExpandedOverlay();
  }

  // 메모 입력창의 내용을 새 메모로 추가하거나 기존 메모에 덮어쓴다.
  Future<void> _saveMemoEditor() async {
    final title = _memoTitleController.text.trim();
    final content = _memoContentController.text.trim();
    if (title.isEmpty && content.isEmpty) return;

    final nextMemos = List<Map<String, String>>.from(_memos);
    final savedMemo = {
      '제목': title.isEmpty ? '메모' : title,
      '내용': content,
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
    await _resizeToExpandedOverlay();
  }

  // 새 북마크 입력창(이름 + URL)을 연다. URL 패널의 '북마크 추가'에서 현재 URL을
  // 미리 채워 호출한다. 북마크 패널로 전환해 폼을 보여준다.
  Future<void> _openBookmarkEditor({String url = ''}) async {
    setState(() {
      _activeMode = OverlayMode.bookmarks;
      _bookmarkEditorOpen = true;
      _bookmarkTitleController.clear();
      _bookmarkUrlController.text = url.trim();
    });
    await _resizeToExpandedOverlay();
    // 입력이 필요한 순간이므로 이름칸에 자동 포커스해 키보드를 띄운다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_isClosing && mounted) _bookmarkTitleFocusNode.requestFocus();
    });
  }

  void _closeBookmarkEditor() {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _bookmarkEditorOpen = false;
      _bookmarkTitleController.clear();
      _bookmarkUrlController.clear();
    });
  }

  Future<void> _cancelBookmarkEditor() async {
    _closeBookmarkEditor();
    await _resizeToExpandedOverlay();
  }

  // 입력한 제목/URL을 새 북마크로 저장한다(제목 비면 URL을 이름으로).
  Future<void> _saveBookmarkEditor() async {
    final title = _bookmarkTitleController.text.trim();
    final rawUrl = _bookmarkUrlController.text.trim();
    if (rawUrl.isEmpty) return;
    final url = _makeWebUrl(rawUrl);

    final nextBookmarks = List<Map<String, String>>.from(_bookmarks)
      ..add({'제목': title.isEmpty ? url : title, 'url': url, 'desc': ''});

    _closeBookmarkEditor();
    await _saveOverlayBookmarks(nextBookmarks);
  }

  // 오버레이 안의 북마크 목록을 갱신하고 저장소에도 저장한다.
  Future<void> _saveOverlayBookmarks(List<Map<String, String>> bookmarks) async {
    if (_isClosing || !mounted) return;
    setState(() => _bookmarks = bookmarks);
    await AppStateStore.saveBookmarks(bookmarks);
    if (_isClosing || !mounted) return;
    await _resizeToExpandedOverlay();
  }

  // 상단 위젯 높이를 계산해서 웹뷰가 열렸을 때 패널이 작아지지 않게 한다.
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
    // 회전을 반영한 실제 화면 크기로 방향을 판단한다(창 크기나 ui.Display.size로는
    // 가로/세로를 오판함). 아직 캐시 전이면 세로로 가정한다.
    if (_screenWidthPx <= 0 || _screenHeightPx <= 0) return false;
    return _screenWidthPx > _screenHeightPx;
  }

  double _bookmarkPanelHeight(bool compact) {
    if (_bookmarkEditorOpen) {
      return 152;
    }
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

  // 펼쳐진 오버레이는 컨트롤 UI(상단 패널 + 웹뷰 컨트롤바)만 보여준다.
  // 실제 웹 내용은 이 스트립 아래에 깔리는 별도의 네이티브 WebView 창이 담당한다.
  Widget _buildExpandedOverlay() {
    // 런처에서 펼치는 도중, 창이 아직 커지기 전의 한 프레임에서는 폭이 매우 좁아
    // (런처 48px) 상단 버튼 바가 overflow 난다. 충분히 넓어지기 전엔 그리지 않는다.
    if (MediaQuery.sizeOf(context).width < 200) {
      return const SizedBox.expand();
    }

    final isLandscape = _isLandscapeScreen();
    _lastLandscape = isLandscape;
    final maxPanelHeight = _maxPanelHeight();
    final horizontalPadding = isLandscape ? 10.0 : 8.0;

    return SizedBox.expand(
      child: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            8,
            horizontalPadding,
            0,
          ),
          child: _webOpen
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildTopOverlayPanel(isLandscape: isLandscape),
                    const SizedBox(height: 6),
                    _buildWebControlBar(),
                  ],
                )
              : Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: maxPanelHeight),
                    child: SingleChildScrollView(
                      padding: EdgeInsets.zero,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildTopOverlayPanel(isLandscape: isLandscape),
                        ],
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  Widget _buildWebControlBar() {
    return Container(
      decoration: _panelDecoration,
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          _smallTextButton('X', () => _closeWeb(), danger: true, width: 44),
          const SizedBox(width: 6),
          Expanded(
            child: SizedBox(
              height: 42,
              child: TextField(
                controller: _searchController,
                style: TextStyle(color: _textColor, fontSize: 14),
                textInputAction: TextInputAction.go,
                decoration: _fieldDecoration('URL', Icons.search, _mutedColor),
                onSubmitted: (_) => _searchUrl(),
              ),
            ),
          ),
          const SizedBox(width: 6),
          // 현재 보고 있는 페이지를 이름과 함께 북마크로 추가한다.
          _iconAction(
            Icons.bookmark_add_outlined,
            () => _openBookmarkEditor(url: _searchController.text),
          ),
          const SizedBox(width: 6),
          _smallTextButton(
            _webFolded ? '펼치기' : '접기',
            _toggleWebFold,
            width: 56,
          ),
        ],
      ),
    );
  }

  Widget _buildLauncherIcon() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _expandFromLauncher,
      onPanUpdate: _onLauncherDrag,
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
    bool fill = false,
  }) {
    if (_activeMode == OverlayMode.url) {
      final panel = _buildUrlPanel(textColor, mutedColor);
      return fill ? Align(alignment: Alignment.topCenter, child: panel) : panel;
    }
    if (_activeMode == OverlayMode.bookmarks) {
      return _buildBookmarkPanel(
        textColor,
        mutedColor,
        compact: isLandscape,
        fill: fill,
      );
    }
    if (_activeMode == OverlayMode.memos) {
      return _buildMemoPanel(compact: isLandscape, fill: fill);
    }
    if (_activeMode == OverlayMode.menu) {
      final panel = _buildMenuPanel();
      return fill ? Align(alignment: Alignment.topCenter, child: panel) : panel;
    }
    return const SizedBox.shrink();
  }

  // 메뉴 패널에는 앱으로, 접기, 다크모드 버튼을 배치한다.
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
            label: '접기',
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
              focusNode: _searchFocusNode,
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
    bool fill = false,
  }) {
    if (_bookmarkEditorOpen) {
      final editor = _buildBookmarkEditor();
      return fill
          ? editor
          : SizedBox(height: _bookmarkPanelHeight(compact), child: editor);
    }

    if (_bookmarks.isEmpty) {
      return _buildHintLine('저장된 북마크가 없습니다.', mutedColor);
    }

    final list = Scrollbar(
        controller: _bookmarkScrollController,
        thumbVisibility: true,
        child: ListView.builder(
          controller: _bookmarkScrollController,
          itemCount: _bookmarks.length,
          itemBuilder: (context, index) {
            final item = _bookmarks[index];
            final title = item['제목']?.trim().isNotEmpty == true
                ? item['제목']!.trim()
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
      );

    return fill
        ? list
        : SizedBox(height: _bookmarkPanelHeight(compact), child: list);
  }

  // 새 북마크를 직접 입력(이름 + URL)하는 폼이다.
  Widget _buildBookmarkEditor() {
    return Material(
      color: _surfaceColor,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 38,
              child: TextField(
                controller: _bookmarkTitleController,
                focusNode: _bookmarkTitleFocusNode,
                style: TextStyle(color: _textColor, fontSize: 14),
                decoration: _fieldDecoration('이름', Icons.title, _mutedColor),
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 38,
              child: TextField(
                controller: _bookmarkUrlController,
                style: TextStyle(color: _textColor, fontSize: 14),
                textInputAction: TextInputAction.done,
                decoration: _fieldDecoration('URL', Icons.link, _mutedColor),
                onSubmitted: (_) => _saveBookmarkEditor(),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Spacer(),
                _smallTextButton('취소', _cancelBookmarkEditor, width: 48),
                const SizedBox(width: 6),
                _smallTextButton('저장', () => _saveBookmarkEditor(), width: 48),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // 메모 목록 또는 메모 편집창을 보여주는 패널이다.
  Widget _buildMemoPanel({required bool compact, bool fill = false}) {
    if (_memoEditorOpen) {
      final editor = _buildMemoEditor();
      return fill
          ? editor
          : SizedBox(height: _memoPanelHeight(compact), child: editor);
    }

    final list = Scrollbar(
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
            final title = memo['제목']?.isNotEmpty == true
                ? memo['제목']!
                : '메모';
            final content = memo['내용']?.isNotEmpty == true
                ? memo['내용']!
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
      );

    return fill
        ? list
        : SizedBox(height: _memoPanelHeight(compact), child: list);
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
