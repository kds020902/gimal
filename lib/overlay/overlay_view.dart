import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:gimal/services/app_state_store.dart';

// ═══════════════════════════════════════════════════════════════
//  목차 — 이 파일의 큰 구조 (본문에서 같은 번호 헤더로 구분됨)
// ───────────────────────────────────────────────────────────────
//   1. 생명주기 (생성/소멸 · 회전 감지 · 데이터 로드)
//   2. 창 상태 전환 (앱으로 종료 · 접기 · 펼치기)
//   3. 오버레이 창 제어 (창 크기 · 화면 크기 · 스트립/웹 영역 계산)
//   4. 네이티브 WebView 창 제어 (메서드 채널로 띄움/이동/접기/닫기)
//   5. 포커스 플래그 · 런처 아이콘 위치/드래그
//   6. 기능: 다크모드 · 패널 선택 · 키보드 포커스
//   7. 기능: URL · 웹뷰 열기/닫기/접기
//   8. 기능: 메모 (추가 · 수정 · 삭제 · 저장)
//   9. 기능: 북마크 (추가 · 저장)
//  10. 크기·방향 계산 + URL 변환 (build에서 쓰는 보조 계산)
//  11. build / UI 빌더 (패널 · 버튼 · 타일)
//  12. 스타일 (패널 장식 · 다크모드 색상)
// ═══════════════════════════════════════════════════════════════

// services: 네이티브와 통신하는 MethodChannel을 쓰기 때문에 import.
// flutter_overlay_window: "다른 앱 위에 뜨는 창"은 안드로이드 OS 기능이라 Flutter 혼자선(webview가 제대로 작동을 안함)
//   못 한다. 이 플러그인이 그 시스템 창을 띄워주고 그 안에서 이 위젯을 돌려줘서 씀.
// app_state_store: 북마크/메모/다크모드를 메인 앱과 같은 저장소로 공유하려고 씀.

// 상단 버튼이 4개(URL/북마크/메모/메뉴)뿐이고 "지금 어떤 패널이 열렸나"를 하나의 값으로
// 안전하게 다루려고 enum으로 정의함. bool 4개로 관리하면 동시에 켜지는 실수가 생김.
enum OverlayMode { url, bookmarks, memos, menu }

// 오버레이는 메인 앱과 "다른 엔진"에서 도는 별개의 Flutter 앱이라, 그 진입점용 위젯이 필요해서 둠.
// 배경을 Colors.transparent로 둔 이유: 오버레이가 화면 전체를 가리지 않고, 바 아래로 뒤 화면이
//   비쳐 보이게 하려고. 불투명하면 게임 화면을 다 덮어버림.
class OverlayApp extends StatelessWidget {
  const OverlayApp({super.key});

  @override
  Widget build(BuildContext context) {
    // 오버레이의 뿌리. 배경을 투명(transparent)으로 둬 뒤의 다른 앱이 비쳐 보이게 함.
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Material(color: Colors.transparent, child: OverlayView()),
    );
  }
}

// 상태(웹뷰 열림/접힘 등)에 따라 화면이 계속 바뀌므로 StatefulWidget으로 만듦.
class OverlayView extends StatefulWidget {
  const OverlayView({super.key});

  // StatefulWidget이 자신의 상태(State) 객체를 만드는 필수 메서드.
  @override
  State<OverlayView> createState() => _OverlayViewState();
}

// WidgetsBindingObserver를 섞은 이유: 화면 회전(didChangeMetrics)을 감지해서 창 크기를
//   다시 잡아야 하기 때문.
class _OverlayViewState extends State<OverlayView> with WidgetsBindingObserver {
  // 네이티브(gimal_overlay_utils)에 명령을 보내는 단 하나의 통로.
  // 채널 이름은 네이티브 쪽과 똑같이 맞춰야 연결돼서 문자열을 고정해 둠.
  static const MethodChannel _utilsChannel = MethodChannel(
    'com.example.gimal/utils',
  );

  // 접었을 때 아이콘 창 크기(48)와 그 안 아이콘 크기(42). 여러 곳에서 같은 값을 써서
  // 숫자를 흩뿌리지 않으려고 상수로 묶음.
  static const int _launcherWindowSize = 48;
  static const double _launcherIconSize = 42;

  // TextField들의 입력값을 코드에서 읽고/지우려면 컨트롤러가 필요해서 각각 둠.
  // _searchController는 URL 패널과 웹뷰 컨트롤바가 같은 입력값을 공유하도록 하나만 씀.
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _memoTitleController = TextEditingController();
  final TextEditingController _memoContentController = TextEditingController();
  final TextEditingController _bookmarkTitleController = TextEditingController();
  final TextEditingController _bookmarkUrlController = TextEditingController();
  // 목록을 스크롤바와 함께 제어하려고 스크롤 컨트롤러를 둠.
  final ScrollController _bookmarkScrollController = ScrollController();
  final ScrollController _memoScrollController = ScrollController();

  // "필요할 때 키보드가 자동으로 뜨게" 하려면 코드에서 입력칸에 포커스를 줘야 해서 노드를 둠.
  // URL칸과 북마크 이름칸은 동시에 떠 있을 수 있어 노드를 분리(같은 노드 공유 시 충돌남).
  final FocusNode _searchFocusNode = FocusNode();
  final FocusNode _bookmarkTitleFocusNode = FocusNode();

  // 접힌 아이콘을 드래그로 옮긴 위치를 기억해야 다음에 같은 자리에서 펼쳐서 nullable로 둠.
  Offset? _launcherOffset;
  // 저장소 변경 이벤트 구독. dispose 때 취소해야 누수가 안 나서 보관함.
  StreamSubscription<dynamic>? _overlaySubscription;

  OverlayMode? _activeMode; // 열린 패널(null이면 버튼만)
  int? _memoEditIndex; // 메모 수정 중이면 그 위치(추가면 null)
  bool _stateLoaded = false; // 저장소 첫 로드 끝났나(끝나기 전엔 로딩 표시)
  bool _webOpen = false; // 웹뷰가 켜졌나
  bool _isDark = false; // 다크모드
  bool _isClosing = false; // 닫히는 중(이후 setState/리사이즈를 막아 크래시 방지)
  bool _isCollapsed = false; // 아이콘으로 접혔나
  bool _isChangingSize = false; // 접기/펼치기 진행 중(중복 호출 방지)
  bool _memoEditorOpen = false; // 메모 편집 폼 열림
  bool _bookmarkEditorOpen = false; // 북마크 추가 폼 열림

  // 웹뷰만 접어둔 상태. _webOpen은 그대로 두고 네이티브 웹뷰 창만 잠시 숨긴 것이라
  // "끄지 않고 접기"를 구현하려고 별도 플래그로 둠.
  bool _webFolded = false;
  // 최초 표시 직후 창을 한 번만 내용 크기로 줄이려고 둔 가드(매번 줄이면 깜빡임).
  bool _didInitialSync = false;
  // 지금 창에 적용된 포커스 플래그를 캐시. 바뀔 때만 네이티브를 불러 불필요한 호출을 줄이려고 둠.
  OverlayFlag _currentFlag = OverlayFlag.defaultFlag;

  // 회전을 반영한 실제 화면 크기(px). ui.Display.size가 회전을 반영 안 해서 가로모드 폭이
  // 틀어지는 문제 때문에, 네이티브에서 회전 반영 크기를 받아 캐시하려고 둠.
  double _screenWidthPx = 0;
  double _screenHeightPx = 0;

  // 화면에 그릴 데이터. 저장소에서 읽어와 캐시해 두고 그림.
  List<Map<String, String>> _bookmarks = [];
  List<Map<String, String>> _memos = [];

  // ═══════════════════════════════════════════════════════
  // 1. 생명주기 (생성/소멸 · 회전 감지 · 데이터 로드)
  // ═══════════════════════════════════════════════════════

  @override
  void initState() {
    super.initState();
    // 회전 감지를 받으려고 옵저버 등록.
    WidgetsBinding.instance.addObserver(this);

    // 메인 앱이나 다른 화면에서 데이터를 바꾸면 오버레이도 즉시 최신으로 맞추려고 이벤트를 구독함.
    _overlaySubscription = AppStateStore.stateEvents.listen((event) {
      if (event == AppStateStore.stateUpdatedEvent) {
        _activateOverlayWindowIfNeeded();
        _loadState();
      }
    });
    // 켜지자마자 저장된 값을 읽어 와야 빈 화면이 안 떠서 바로 호출.
    _loadState();
  }

  @override
  void dispose() {
    // 이후 비동기 콜백이 setState를 못 하게 먼저 막음.
    _isClosing = true;
    // 네이티브 웹뷰 창은 이 위젯과 별개라, 안 닫으면 화면에 남는 누수가 생겨서 같이 닫음.
    _hideNativeWeb();
    WidgetsBinding.instance.removeObserver(this);
    _overlaySubscription?.cancel();
    // 컨트롤러/포커스노드는 안 풀면 메모리 누수라 전부 해제.
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

  // 닫았다가 같은 엔진에서 다시 켜질 때 "닫히는 중" 잔여 상태가 남아 동작을 막는 경우가 있어,
  // 이벤트가 올 때 그 상태를 초기화하려고 둔 방어용 함수.
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
    // 화면이 회전하면 폭/위치가 바뀌므로 창과 웹뷰 영역을 다시 잡아야 해서 여기서 처리함.
    if (_isClosing) return;
    // 레이아웃이 끝난 다음 프레임에 처리해야 새 크기가 반영돼서 postFrame으로 미룸.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (_isClosing || !mounted) return;
      // 화면 크기(px)는 "회전할 때만" 바뀌므로, 매 resize가 아니라 여기서만 갱신함.
      await _refreshScreenSize();
      if (_isClosing || !mounted) return;
      // 접힌 상태면 아이콘 위치만, 아니면 창을 다시 잡음(웹 여부와 무관하게 같은 처리).
      if (_isCollapsed) {
        await _moveLauncherOverlay();
        return;
      }
      await _resizeToExpandedOverlay();
    });
  }

  // 저장소의 북마크/메모/다크모드를 읽어 화면 상태에 반영하려고 둠.
  Future<void> _loadState() async {
    if (_isClosing) return;

    // await 중 실패하더라도 이전 값을 유지하려고 현재 값으로 초기화해 둠.
    var bookmarks = _bookmarks.isEmpty
        ? AppStateStore.defaultBookmarks()
        : _bookmarks;
    var memos = _memos;
    var isDark = _isDark;

    // 저장소 읽기가 실패해도 앱이 죽지 않게 try로 감쌈.
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

    // 처음 show될 때 창은 전체화면으로 떠 있다. 그대로 두면 화면 전체가 터치를 먹어 게임을
    // 못 만지므로, 첫 프레임 뒤에 한 번만 내용 크기로 줄여서 바 아래를 조작 가능하게 함.
    if (!_didInitialSync && !_isCollapsed) {
      _didInitialSync = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!_isClosing && mounted && !_isCollapsed) {
          // 첫 resize 전에 화면 크기를 한 번 받아둠(이후엔 회전 때만 갱신).
          await _refreshScreenSize();
          await _resizeToExpandedOverlay();
        }
      });
    }
  }

  // ═══════════════════════════════════════════════════════
  // 2. 창 상태 전환 (앱으로 종료 · 접기 · 펼치기)
  // ═══════════════════════════════════════════════════════

  // "앱으로" 버튼: 메인 앱을 앞으로 가져오고 오버레이를 완전히 종료하려고 둠.
  Future<void> _returnToApp() async {
    // 키보드가 떠 있으면 닫고 시작(잔상 방지).
    FocusManager.instance.primaryFocus?.unfocus();
    _isClosing = true;
    _webOpen = false;
    _activeMode = null;
    // 별도 창인 네이티브 웹뷰를 먼저 닫아야 남지 않아서 종료 전에 호출.
    await _hideNativeWeb();

    try {
      try {
        // 네이티브에 메인 액티비티를 앞으로 가져오라고 요청.
        await _utilsChannel.invokeMethod('bringToFront');
      } catch (error) {
        debugPrint('bringToFront failed: $error');
      }
    } finally {
      // 닫기 직후 바로 종료하면 화면이 깜빡여서 한 프레임 기다린 뒤 닫음.
      await WidgetsBinding.instance.endOfFrame;
      try {
        await FlutterOverlayWindow.closeOverlay();
      } catch (error) {
        // 닫기 실패 시엔 닫히는 중 상태를 풀어 다시 쓸 수 있게 함.
        _isClosing = false;
        debugPrint('closeOverlay failed: $error');
      }
    }
  }

  // 메뉴의 "접기": 오버레이 전체를 작은 아이콘 창으로 줄이려고 둠(끄는 게 아님).
  Future<void> _collapseToLauncher() async {
    FocusManager.instance.primaryFocus?.unfocus();
    // 접기/펼치기가 겹쳐 호출되면 창 크기가 꼬여서 진행 중이면 막음.
    if (_isClosing || _isChangingSize) return;
    _isChangingSize = true;

    try {
      if (!mounted || _isClosing) return;

      // 웹뷰가 열려 있었는지 기억해 뒀다가, 접을 때 인스턴스를 유지한 채 떼기만 함.
      final wasWebOpen = _webOpen;
      setState(() {
        _isCollapsed = true;
        _activeMode = null;
        _memoEditorOpen = false;
        _memoEditIndex = null;
        _bookmarkEditorOpen = false;
      });

      // 접어도 웹뷰는 끄지 않고 창에서만 떼서(_webOpen 유지) 펼칠 때 그대로 복귀시키려고 함.
      // 또 아이콘 상태에선 입력이 없으니 포커스를 가져가지 않게 플래그도 되돌림.
      if (wasWebOpen) {
        await _detachNativeWeb();
      }
      await _applyDesiredFlag();
      await WidgetsBinding.instance.endOfFrame;
      // 이전에 드래그한 위치가 있으면 거기로, 없으면 기본 위치로 아이콘을 띄움.
      final launcherOffset = _launcherOffset ?? _defaultLauncherOffset();
      _launcherOffset = launcherOffset;
      // 세 번째 인자 true = 이 작은 아이콘 창은 드래그 가능하게.
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

  // 접힌 아이콘을 누르면 같은 창을 다시 펼치려고 둠.
  Future<void> _expandFromLauncher() async {
    if (_isClosing || _isChangingSize) return;
    _isChangingSize = true;

    try {
      setState(() => _isCollapsed = false);
      await WidgetsBinding.instance.endOfFrame;
      // 펼칠 땐 일단 좌상단(0,0)으로 옮기고 내용 크기로 다시 잡음.
      await FlutterOverlayWindow.moveOverlay(OverlayPosition(0, 0));
      await _resizeToExpandedOverlay();
      // resize가 위치를 살짝 바꾸는 기기가 있어 한 번 더 (0,0)으로 확정.
      await FlutterOverlayWindow.moveOverlay(OverlayPosition(0, 0));
      // 접기 전 웹뷰가 떠 있었으면 같은 인스턴스로 복귀. 단 "웹뷰만 접어둔" 상태면 그대로 둠.
      if (_webOpen && !_webFolded) {
        await _reattachNativeWeb();
      }
    } catch (error) {
      debugPrint('expandFromLauncher failed: $error');
    } finally {
      _isChangingSize = false;
    }
  }

  // ═══════════════════════════════════════════════════════
  // 3. 오버레이 창 제어 (창 크기 · 화면 크기 · 스트립/웹 영역 계산)
  // ═══════════════════════════════════════════════════════

  // ★ 이 파일의 중심 함수. 상태가 바뀔 때마다 불러 "창 크기 + 포커스 플래그 + 네이티브 웹뷰
  //   위치"를 한 번에 맞추려고 둠. 흩어진 리사이즈 호출을 여기 하나로 모음.

  // - 크기: 항상 상단 바/패널(+웹뷰면 컨트롤바)만큼만.
  // 전체화면이 아니라, 바 아래 게임을 만질 수있어서.
  // 실제 웹 화면은 이 스트립 아래에 깔리는 별도 네이티브 창이 담당함.

  // - 주의: 이 플러그인의 resizeOverlay에 height로 matchParent(-1)를 넘기면 내부 버그로 창이
  //   수백만 px가 돼서 Vulkan 할당 중 앱이 통째로 죽음. 그래서 항상 실제 px를 계산해 넘김.
  Future<void> _resizeToExpandedOverlay() async {
    if (_isClosing || !mounted) return;

    // 화면 크기는 회전 때만 바뀌므로 여기서 매번 갱신하지 않고 캐시값을 씀(과한 네이티브 호출 제거).
    // 크기를 바꾸기 전에 포커스 플래그(키보드/터치통과)부터 맞춤.
    await _applyDesiredFlag();
    if (_isClosing || !mounted) return;

    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final dpr = view.devicePixelRatio;
    final topInset = view.padding.top / dpr;
    final compact = _isLandscapeScreen();
    final (screenWidthPx, _) = _screenSizePx();
    final width = (screenWidthPx / dpr).round();
    // 웹뷰가 열렸으면 컨트롤바까지 포함한 스트립 높이, 아니면 패널 높이만큼.
    final height = _webOpen
        ? _webStripHeight(topInset, compact).ceil()
        : (topInset + 16 + _mainWidgetHeight(compact)).ceil();

    await FlutterOverlayWindow.resizeOverlay(width, height, false);
    await FlutterOverlayWindow.moveOverlay(OverlayPosition(0, 0));
    // 스트립 높이가 바뀌면 그 아래 네이티브 웹뷰도 같이 내려줘야 안 겹쳐서 위치를 갱신.
    if (_webOpen) {
      await _updateNativeWebBounds();
    }
  }

  // ui.Display.size는 회전을 반영 안 해서, 회전 반영 실제 크기를 네이티브에서 받아 캐시하려고 둠.
  Future<void> _refreshScreenSize() async {
    try {
      final size = await _utilsChannel.invokeMethod('getScreenSize');
      if (size is Map) {
        final w = (size['width'] as num?)?.toDouble() ?? 0;
        final h = (size['height'] as num?)?.toDouble() ?? 0;
        // 0 같은 비정상 값으로 덮어쓰지 않게 양수일 때만 반영.
        if (w > 0 && h > 0) {
          _screenWidthPx = w;
          _screenHeightPx = h;
        }
      }
    } catch (error) {
      debugPrint('getScreenSize failed: $error');
    }
  }

  // 회전 반영 실제 화면 크기(physical px). 캐시가 없으면 Display.size로 폴백.
  // resize/웹뷰영역/드래그 제한이 같은 폴백 규칙을 쓰도록 한곳에 모음(중복 제거).
  (double, double) _screenSizePx() {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    return (
      _screenWidthPx > 0 ? _screenWidthPx : view.display.size.width,
      _screenHeightPx > 0 ? _screenHeightPx : view.display.size.height,
    );
  }

  // 웹뷰가 열렸을 때 위쪽 컨트롤 스트립의 높이(logical). 이 아래 지점부터 네이티브 웹뷰를 깔려고
  // 계산식으로 둠 = 상태바 + 위여백8 + 패널높이 + 간격6 + 컨트롤바58 + 아래여백8.
  double _webStripHeight(double topInset, bool compact) =>
      topInset + 8 + _mainWidgetHeight(compact) + 6 + 58 + 8;

  // 네이티브 웹뷰 창이 차지할 사각형(physical px) = 스트립 바로 아래 ~ 화면 끝.
  // 네이티브 창은 px로 위치를 받아서 여기서 px로 계산해 넘기려고 둠. 레코드로 4개 값을 한 번에 반환.
  (int, int, int, int) _webBoundsPx() {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final dpr = view.devicePixelRatio;
    final topInset = view.padding.top / dpr;
    final compact = _isLandscapeScreen();
    final stripPx = (_webStripHeight(topInset, compact) * dpr).round();
    final (screenW, screenH) = _screenSizePx();
    return (0, stripPx, screenW.round(), (screenH - stripPx).round());
  }

  // ═══════════════════════════════════════════════════════
  // 4. 네이티브 WebView 창 제어 (메서드 채널로 띄움/이동/접기/닫기)
  // ═══════════════════════════════════════════════════════

  // 접기: 네이티브 웹뷰 창을 화면에서 떼되 인스턴스(로딩 상태)는 살려두려고 둠(다시 붙이면 그대로).
  Future<void> _detachNativeWeb() async {
    try {
      await _utilsChannel.invokeMethod('detachWebOverlay');
    } catch (error) {
      debugPrint('detachWebOverlay failed: $error');
    }
  }

  // 펼치기: 접어둔 그 웹뷰를 같은 인스턴스로 현재 위치에 다시 붙이려고 둠.
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

  // 웹뷰를 처음 열 때: 네이티브 창을 만들고 url을 로드하라고 보냄.
  // (오버레이 엔진은 Activity가 아니라 Service라 Flutter WebView가 안 떠서 네이티브로 띄움.)
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

  // 패널을 열고 닫아 스트립 높이가 바뀌면 웹뷰 위치/크기도 따라가게 맞추려고 둠.
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

  // 웹뷰를 완전히 닫을 때(X/앱으로/dispose). 인스턴스까지 없애서 메모리를 정리하려고 둠.
  Future<void> _hideNativeWeb() async {
    try {
      await _utilsChannel.invokeMethod('hideWebOverlay');
    } catch (error) {
      debugPrint('hideWebOverlay failed: $error');
    }
  }

  // ═══════════════════════════════════════════════════════
  // 5. 포커스 플래그 · 런처 아이콘 위치/드래그
  // ═══════════════════════════════════════════════════════

  // "게임 조작 vs 키보드 입력"의 분기점. 창의 포커스 플래그를 상태에 맞게 바꾸려고 둠.
  // - 입력 패널이 떠 있거나 웹뷰가 펼쳐졌을 때만 focusPointer(포커스 가능 → 키보드 뜸).
  // - 그 외(웹뷰 접고 게임 조작 등)엔 defaultFlag(NOT_FOCUSABLE) → 뒤로가기·바깥 터치가 게임으로 통과.
  Future<void> _applyDesiredFlag() async {
    final wantsInput =
        _activeMode == OverlayMode.url ||
        _memoEditorOpen ||
        _bookmarkEditorOpen;
    final webShown = _webOpen && !_webFolded;
    // 접힌 아이콘 상태에선 입력이 없으니 항상 defaultFlag.
    final desired = (!_isCollapsed && (wantsInput || webShown))
        ? OverlayFlag.focusPointer
        : OverlayFlag.defaultFlag;
    // 같은 플래그면 네이티브를 다시 부를 필요가 없어서 바뀔 때만 호출(낭비 방지).
    if (desired == _currentFlag) return;
    _currentFlag = desired;
    try {
      await FlutterOverlayWindow.updateFlag(desired);
    } catch (error) {
      debugPrint('updateFlag failed: $error');
    }
  }

  // 회전 등으로 다시 띄울 때 아이콘을 기억된 위치로 옮기려고 둠.
  Future<void> _moveLauncherOverlay() async {
    final launcherOffset = _launcherOffset ?? _defaultLauncherOffset();
    _launcherOffset = launcherOffset;
    await FlutterOverlayWindow.moveOverlay(_overlayPositionFor(launcherOffset));
  }

  // 아이콘을 드래그한 만큼 창을 옮기려고 둠. 화면 밖으로 사라지지 않게 clamp로 가둠.
  void _onLauncherDrag(DragUpdateDetails details) {
    if (_isClosing) return;
    final dpr =
        WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
    final (screenWPx, screenHPx) = _screenSizePx();
    final screenW = screenWPx / dpr;
    final screenH = screenHPx / dpr;
    final base = _launcherOffset ?? _defaultLauncherOffset();
    // delta(이번 프레임 이동량)를 누적해 새 위치를 만들고, 화면 안으로 제한.
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

  // 드래그 기록이 없을 때 아이콘 기본 위치(상단 가운데)를 정하려고 둠.
  Offset _defaultLauncherOffset() {
    final media = MediaQuery.of(context);
    final x = ((media.size.width - _launcherWindowSize) / 2).clamp(
      0.0,
      media.size.width,
    );
    final y = media.padding.top + 24.0;
    return Offset(x.toDouble(), y);
  }

  // Offset(논리 좌표)을 플러그인이 쓰는 OverlayPosition으로 바꿔주는 변환기.
  OverlayPosition _overlayPositionFor(Offset offset) {
    return OverlayPosition(offset.dx, offset.dy);
  }

  // ═══════════════════════════════════════════════════════
  // 6. 기능: 다크모드 · 패널 선택 · 키보드 포커스
  // ═══════════════════════════════════════════════════════

  // 다크모드를 토글하고 저장소에 저장하려고 둠. 저장하면 메인 앱에도 이벤트로 전파됨.
  Future<void> _toggleDarkMode() async {
    if (_isClosing) return;

    final nextValue = !_isDark;
    setState(() => _isDark = nextValue);
    await AppStateStore.saveDarkMode(nextValue);
  }

  // 상단 버튼(URL/북마크/메모/메뉴)을 눌렀을 때 어떤 패널을 열지 정하려고 둠.
  Future<void> _selectMode(OverlayMode mode) async {
    if (_isClosing) return;

    // 패널을 열기 전에 최신 데이터로 맞춰 보여주려고 다시 읽음.
    await _loadState();
    if (_isClosing || !mounted) return;

    // 이미 켜진 버튼을 다시 누르면 닫히도록(토글) null로.
    final nextMode = _activeMode == mode ? null : mode;
    setState(() {
      _activeMode = nextMode;
      // 다른 패널로 가면 열려 있던 편집 폼/입력값은 초기화(엉뚱한 잔상 방지).
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
    // 패널 높이가 바뀌니 창 크기를 다시 잡음.
    await _resizeToExpandedOverlay();
    // URL 패널은 열자마자 타이핑할 거라 자동 포커스로 키보드를 띄움.
    if (_activeMode == OverlayMode.url) {
      _focusSearchSoon();
    }
  }

  // "필요할 때 키보드 자동" 구현용. 창 플래그가 focusPointer로 바뀐 뒤여야 키보드가 떠서,
  // resize 이후 다음 프레임에 입력칸에 포커스를 주려고 둠.
  void _focusSearchSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_isClosing && mounted) _searchFocusNode.requestFocus();
    });
  }

  // ═══════════════════════════════════════════════════════
  // 7. 기능: URL · 웹뷰 열기/닫기/접기
  // ═══════════════════════════════════════════════════════

  // URL/검색어/북마크 주소를 네이티브 WebView 창으로 열려고 둠.
  // (오버레이 엔진은 Service라 Flutter WebView의 platform_views가 동작하지 않아 네이티브 사용.)
  Future<void> _openWeb(String value) async {
    if (_isClosing) return;

    final url = _makeWebUrl(value);
    if (url.isEmpty) return;

    setState(() {
      _webOpen = true;
      _webFolded = false;
      // 웹뷰를 열면 열려 있던 패널/편집창을 닫아 스트립을 짧게 → 웹뷰 영역을 넓게.
      _activeMode = null;
      _memoEditorOpen = false;
      _bookmarkEditorOpen = false;
      _searchController.text = url;
    });

    // 컨트롤 스트립을 먼저 자리잡게 한 뒤(높이 확정) 그 아래에 웹뷰를 깔아야 위치가 맞아서 순서를 둠.
    await WidgetsBinding.instance.endOfFrame;
    if (_isClosing || !mounted) return;
    await _resizeToExpandedOverlay();
    if (_isClosing || !mounted) return;
    await _showNativeWeb(url);
  }

  // 컨트롤바 X: 웹뷰를 완전히 닫고(인스턴스 제거) 스트립 크기를 다시 줄이려고 둠.
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

  // 컨트롤바 접기/펼치기: 웹뷰 창만 잠시 접거나(끄지 않고) 다시 띄우려고 둠.
  // 접으면 상단 스트립만 남아 그 아래 게임을 조작할 수 있게 됨(공략을 잠깐 치우는 용도).
  Future<void> _toggleWebFold() async {
    if (_isClosing || !_webOpen) return;
    if (_webFolded) {
      // 펼치기: 플래그/크기 먼저 맞춘 뒤 웹뷰를 다시 붙임.
      setState(() => _webFolded = false);
      await _resizeToExpandedOverlay();
      if (_isClosing || !mounted) return;
      await _reattachNativeWeb();
    } else {
      // 접기: 웹뷰를 떼고(인스턴스 유지) 플래그를 defaultFlag로 바꿔 게임 조작이 되게 함.
      await _detachNativeWeb();
      setState(() => _webFolded = true);
      await _resizeToExpandedOverlay();
    }
  }

  // ═══════════════════════════════════════════════════════
  // 8. 기능: 메모 (추가 · 수정 · 삭제 · 저장)
  // ═══════════════════════════════════════════════════════

  // 메모 추가/수정 입력창을 패널 안에 열려고 둠. index가 있으면 수정, 없으면 새 메모.
  Future<void> _openMemoEditor({int? index}) async {
    // 잘못된 index로 부르면 크래시라 범위를 먼저 검사.
    if (index != null && (index < 0 || index >= _memos.length)) {
      return;
    }

    final memo = index == null ? null : _memos[index];
    setState(() {
      _memoEditIndex = index;
      _memoEditorOpen = true;
      // 수정이면 기존 값을 채우고, 추가면 빈칸.
      _memoTitleController.text = memo?['제목'] ?? '';
      _memoContentController.text = memo?['내용'] ?? '';
    });
    await _resizeToExpandedOverlay();
  }

  // 메모 입력창을 닫고 입력값/수정 위치를 비우려고 둠.
  void _closeMemoEditor() {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _memoEditorOpen = false;
      _memoEditIndex = null;
      _memoTitleController.clear();
      _memoContentController.clear();
    });
  }

  // 취소: 닫고 패널 높이만 되돌리려고 둠.
  Future<void> _cancelMemoEditor() async {
    _closeMemoEditor();
    await _resizeToExpandedOverlay();
  }

  // 입력 내용을 새 메모로 추가하거나 기존 메모에 덮어쓰려고 둠.
  Future<void> _saveMemoEditor() async {
    final title = _memoTitleController.text.trim();
    final content = _memoContentController.text.trim();
    // 제목·내용이 둘 다 비면 저장할 게 없어서 무시.
    if (title.isEmpty && content.isEmpty) return;

    // 원본을 직접 건드리지 않고 복사본을 만들어 바꾼 뒤 저장(상태 꼬임 방지).
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

  // 수정 중이던 메모를 목록에서 지우려고 둠.
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

  // 화면 목록을 먼저 갱신하고 저장소에도 저장하려고 둠(저장 시 메인 앱에도 전파됨).
  Future<void> _saveOverlayMemos(List<Map<String, String>> memos) async {
    if (_isClosing || !mounted) return;
    setState(() => _memos = memos);
    await AppStateStore.saveMemos(memos);
    if (_isClosing || !mounted) return;
    await _resizeToExpandedOverlay();
  }

  // ═══════════════════════════════════════════════════════
  // 9. 기능: 북마크 (추가 · 저장)
  // ═══════════════════════════════════════════════════════

  // 새 북마크 입력창(이름 + URL)을 열려고 둠. 웹뷰 컨트롤바의 북마크 버튼에서 현재 URL을
  // 미리 채워 부르며, 폼을 보여주려고 북마크 패널로 전환함.
  Future<void> _openBookmarkEditor({String url = ''}) async {
    setState(() {
      _activeMode = OverlayMode.bookmarks;
      _bookmarkEditorOpen = true;
      _bookmarkTitleController.clear();
      _bookmarkUrlController.text = url.trim();
    });
    await _resizeToExpandedOverlay();
    // 바로 이름을 타이핑할 거라 이름칸에 자동 포커스해 키보드를 띄움.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_isClosing && mounted) _bookmarkTitleFocusNode.requestFocus();
    });
  }

  // 북마크 입력창을 닫고 입력값을 비우려고 둠.
  void _closeBookmarkEditor() {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _bookmarkEditorOpen = false;
      _bookmarkTitleController.clear();
      _bookmarkUrlController.clear();
    });
  }

  // 취소: 닫고 패널 높이만 되돌리려고 둠.
  Future<void> _cancelBookmarkEditor() async {
    _closeBookmarkEditor();
    await _resizeToExpandedOverlay();
  }

  // 입력한 이름/URL을 새 북마크로 저장하려고 둠(이름이 비면 URL을 이름으로 대체).
  Future<void> _saveBookmarkEditor() async {
    final title = _bookmarkTitleController.text.trim();
    final rawUrl = _bookmarkUrlController.text.trim();
    // URL이 비면 저장 불가.
    if (rawUrl.isEmpty) return;
    // 사람이 적은 주소를 정상 URL로 보정해 저장.
    final url = _makeWebUrl(rawUrl);

    final nextBookmarks = List<Map<String, String>>.from(_bookmarks)
      ..add({'제목': title.isEmpty ? url : title, '주소': url, '내용': ''});

    _closeBookmarkEditor();
    await _saveOverlayBookmarks(nextBookmarks);
  }

  // 화면 목록 갱신 + 저장소 저장(메인 앱에 전파)을 한 번에 하려고 둠.
  Future<void> _saveOverlayBookmarks(List<Map<String, String>> bookmarks) async {
    if (_isClosing || !mounted) return;
    setState(() => _bookmarks = bookmarks);
    await AppStateStore.saveBookmarks(bookmarks);
    if (_isClosing || !mounted) return;
    await _resizeToExpandedOverlay();
  }

  // ═══════════════════════════════════════════════════════
  // 10. 크기·방향 계산 + URL 변환 (build에서 쓰는 보조 계산)
  // ═══════════════════════════════════════════════════════

  // 상단 위젯(버튼바 + 열린 패널)의 전체 높이를 계산하려고 둠. 창 크기/웹뷰 위치 계산의 기준값.
  double _mainWidgetHeight(bool compact) {
    final buttonBarHeight = compact ? 54.0 : 58.0;
    var height = buttonBarHeight;
    // 패널이 열렸으면 구분선(1) + 패딩 + 패널 높이를 더함.
    if (_activeMode != null) {
      final panelPadding = compact ? 16.0 : 20.0;
      height += 1 + panelPadding + _activePanelHeight(compact);
    }
    return height;
  }

  // 열린 패널 종류별 높이를 돌려주려고 둠(URL/메뉴는 짧아서 기본 42).
  double _activePanelHeight(bool compact) {
    if (_activeMode == OverlayMode.bookmarks) {
      return _bookmarkPanelHeight(compact);
    }
    if (_activeMode == OverlayMode.memos) {
      return _memoPanelHeight(compact);
    }
    return 42;
  }

  // 가로/세로를 판정하려고 둠. 창을 내용 크기로 줄이면 MediaQuery가 작은 창 크기를 줘서
  // 세로폰을 가로로 오판하므로, 회전 반영 실제 화면 크기로 판단함(웹 열림 여부와 무관하게 정확).
  bool _isLandscapeScreen() {
    // 캐시 전이면 세로로 가정.
    if (_screenWidthPx <= 0 || _screenHeightPx <= 0) return false;
    return _screenWidthPx > _screenHeightPx;
  }

  // 북마크 패널 높이. 편집 폼이 열리면 입력칸 때문에 더 높아야 해서 분기.
  double _bookmarkPanelHeight(bool compact) {
    if (_bookmarkEditorOpen) {
      return 152;
    }
    return compact ? 120 : 188;
  }

  // 메모 패널 높이. 목록일 때와 편집창일 때 필요한 높이가 달라서 상태로 분기.
  double _memoPanelHeight(bool compact) {
    if (_memoEditorOpen) {
      return compact ? 146 : 188;
    }
    return compact ? 120 : 188;
  }

  // URL 패널의 이동 버튼이나 키보드 제출 시 웹을 열려고 둠.
  Future<void> _searchUrl() async {
    await _openWeb(_searchController.text);
  }

  // 입력을 정상 URL로 바꾸려고 둠. 주소 같으면 그대로/https 보정, 단어면 구글 검색으로.
  String _makeWebUrl(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }
    // 점이 있고 공백이 없으면 도메인으로 보고 https를 붙임(예: a.com).
    if (trimmed.contains('.') && !trimmed.contains(' ')) {
      return 'https://$trimmed';
    }
    return 'https://www.google.com/search?q=${Uri.encodeQueryComponent(trimmed)}';
  }

  // ═══════════════════════════════════════════════════════
  // 11. build / UI 빌더 (패널 · 버튼 · 타일)
  // ═══════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    // 데이터 로드 전엔 빈 화면 대신 로딩 표시를 보여주려고 분기.
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

    // 접힌 상태면 아이콘만, 아니면 펼친 오버레이를 그림.
    if (_isCollapsed) {
      return Center(child: _buildLauncherIcon());
    }

    return _buildExpandedOverlay();
  }

  // 펼친 오버레이는 컨트롤 UI(상단 패널 + 웹뷰 컨트롤바)만 그림. 실제 웹 내용은 이 스트립 아래에
  // 깔리는 별도 네이티브 WebView 창이 담당해서 여기엔 안 넣음.
  Widget _buildExpandedOverlay() {
    // 런처에서 펼치는 도중, 창이 아직 커지기 전 한 프레임은 폭이 매우 좁아(런처 48px) 버튼바가
    // overflow 나므로, 충분히 넓어지기 전엔 아예 안 그려서 그 경고를 피함.
    if (MediaQuery.sizeOf(context).width < 200) {
      return const SizedBox.expand();
    }

    final isLandscape = _isLandscapeScreen();
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
          // 웹뷰가 열렸으면 [상단패널 + 컨트롤바]를, 아니면 상단패널만 위에 붙여 보여줌.
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
                  // 패널이 화면보다 길어질 수 있어 스크롤 가능하게 감쌈.
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: _maxPanelHeight()),
                    child: SingleChildScrollView(
                      padding: EdgeInsets.zero,
                      child: _buildTopOverlayPanel(isLandscape: isLandscape),
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  // 웹뷰 위에 올리는 조작 바. [X 닫기] [URL] [🔖 북마크추가] [접기/펼치기]로 구성하려고 둠.
  // (뒤로가기 버튼은 없앰 — 휴대폰 하드웨어 뒤로가기를 네이티브 웹뷰가 처리하게 바꿔서.)
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
                decoration: _fieldDecoration('검색', Icons.search, _mutedColor),
                onSubmitted: (_) => _searchUrl(),
              ),
            ),
          ),
          const SizedBox(width: 6),
          // 지금 보고 있는 페이지를 이름과 함께 북마크로 저장하려고 둔 버튼.
          _iconAction(
            Icons.bookmark_add_outlined,
            () => _openBookmarkEditor(url: _searchController.text),
          ),
          const SizedBox(width: 6),
          // 웹뷰만 접었다 폈다 하는 버튼. 상태에 따라 글자를 바꿈.
          _smallTextButton(
            _webFolded ? '펼치기' : '접기',
            _toggleWebFold,
            width: 56,
          ),
        ],
      ),
    );
  }

  // 접었을 때 보이는 동그란 아이콘. 탭하면 펼치고(onTap), 끌면 옮기게(onPanUpdate) 둠.
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

  // 비-웹 패널이 가질 수 있는 최대 높이 = 화면 높이(인셋 제외). 웹뷰일 땐 이 값을 안 써서
  // 웹 분기는 두지 않음.
  double _maxPanelHeight() {
    final media = MediaQuery.of(context);
    final height =
        media.size.height - media.padding.top - media.padding.bottom - 8;
    return height < 0 ? 0.0 : height;
  }

  // 버튼바 + 선택된 패널을 한 덩어리(카드)로 묶으려고 둠.
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
          // 패널이 열린 경우에만 구분선과 함께 그 아래 패널을 붙임.
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

  // 맨 위 4개 버튼(URL/북마크/메모/메뉴) 줄. Expanded로 폭을 균등 분배하려고 둠.
  Widget _buildButtonBar({required bool isLandscape}) {
    return Padding(
      padding: EdgeInsets.all(isLandscape ? 6 : 8),
      child: Row(
        children: [
          Expanded(
            child: _barButton(
              mode: OverlayMode.url,
              icon: Icons.search,
              label: '검색',
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

  // 선택 상태(켜짐/꺼짐)에 따라 색이 바뀌는 버튼을 매번 똑같이 만들려고 공통 함수로 둠.
  Widget _barButton({
    required OverlayMode mode,
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    // 지금 열린 패널과 같은 버튼이면 강조색으로.
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

  // 메뉴 버튼은 글자가 길어 자리가 부족해서 아이콘만 쓰려고 따로 둠.
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

  // 선택된 모드에 맞는 패널을 골라 그리려고 둠(분기 한곳에 모음).
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

  // 메뉴 패널: 앱으로/접기/다크모드 3개 동작 버튼을 모아두려고 둠.
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
            // 현재 모드에 따라 아이콘을 해/달로 바꿔 직관적으로 보여줌.
            icon: _isDark ? Icons.light_mode : Icons.dark_mode,
            label: '다크모드',
            onPressed: _toggleDarkMode,
          ),
        ),
      ],
    );
  }

  // X/이동/취소/저장 같은 작은 글자 버튼을 반복해서 쓰려고 공통 함수로 둠. danger면 빨강(닫기/삭제).
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

  // 메뉴 패널의 아이콘+글자 버튼을 반복해서 만들려고 공통 함수로 둠.
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

  // URL/검색어 입력 패널. 입력칸 + 이동(→) 버튼으로 둠. 자동 포커스를 주려고 focusNode를 연결.
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
                '검색어 입력',
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

  // 저장된 북마크 목록을 보여주고 누르면 웹뷰로 열려고 둠. 편집 폼/빈 목록을 먼저 분기 처리.
  Widget _buildBookmarkPanel(
    Color textColor,
    Color mutedColor, {
    required bool compact,
  }) {
    // 추가 폼이 열렸으면 목록 대신 입력 폼을 보여줌.
    if (_bookmarkEditorOpen) {
      return SizedBox(
        height: _bookmarkPanelHeight(compact),
        child: _buildBookmarkEditor(),
      );
    }

    // 비었으면 안내문만.
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
            // 제목 키는 한글 '제목'로 통일. 비면 '북마크'로 대체.
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
                              // 가로(compact)에선 자리가 좁아 URL 줄은 생략.
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

    // 목록은 고정 높이 칸 안에서 스크롤되게 감쌈.
    return SizedBox(height: _bookmarkPanelHeight(compact), child: list);
  }

  // 새 북마크를 직접 입력(이름 + URL)하는 폼. 이름칸은 자동 포커스용 focusNode를 연결.
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

  // 메모 목록 또는 편집창을 보여주려고 둠. 목록 맨 위(index 0)에 "메모 추가" 타일을 끼워 넣음.
  Widget _buildMemoPanel({required bool compact}) {
    if (_memoEditorOpen) {
      return SizedBox(
        height: _memoPanelHeight(compact),
        child: _buildMemoEditor(),
      );
    }

    final list = Scrollbar(
        controller: _memoScrollController,
        thumbVisibility: true,
        child: ListView.builder(
          controller: _memoScrollController,
          // +1은 맨 위 "메모 추가" 타일 한 칸.
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

            // 0번이 추가 타일이라 실제 메모는 index-1.
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

    return SizedBox(height: _memoPanelHeight(compact), child: list);
  }

  // 메모 추가/수정 입력창. 내용칸은 남은 높이를 채우게 expands로 둠. 수정 모드일 때만 삭제 버튼 노출.
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
                // 수정 중일 때만(_memoEditIndex != null) 삭제 버튼을 보여줌.
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

  // 목록의 한 줄(카드)을 반복해서 만들려고 공통 타일로 둠. 메모 목록과 추가 타일이 같이 씀.
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
                        // 가로에선 1줄, 세로에선 2줄까지만 미리보기.
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

  // 아이콘만 있는 작은 실행 버튼(이동/북마크추가 등)을 반복해서 쓰려고 공통 함수로 둠.
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

  // 목록이 비었을 때 보여줄 짧은 안내문을 만들려고 둠.
  Widget _buildHintLine(String message, Color mutedColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(message, style: TextStyle(color: mutedColor)),
      ),
    );
  }

  // 오버레이 안 TextField들이 같은 모양을 갖도록 입력칸 장식을 한곳에서 만들려고 둠(중복 제거).
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

  // ═══════════════════════════════════════════════════════
  // 12. 스타일 (패널 장식 · 다크모드 색상)
  // ═══════════════════════════════════════════════════════

  // 패널 카드의 배경/테두리/그림자를 한곳에서 관리하려고 getter로 둠(여러 곳에서 같은 스타일 재사용).
  BoxDecoration get _panelDecoration => BoxDecoration(
    color: _panelColor,
    borderRadius: BorderRadius.circular(12),
    border: Border.all(color: _borderColor),
    boxShadow: const [
      BoxShadow(color: Color(0x33000000), blurRadius: 16, offset: Offset(0, 6)),
    ],
  );

  // 색은 다크모드(_isDark)에 따라 달라져서, 매번 분기하지 않게 getter로 모아 둠.
  // 여기 한곳만 고치면 전체 테마가 바뀌게 하려는 의도.
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
