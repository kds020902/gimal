import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:gimal/main.dart';
import 'package:gimal/screens/bookmark_screen.dart';
import 'package:gimal/screens/memo_screen.dart';
import 'package:gimal/screens/url_search_screen.dart';
import 'package:gimal/services/app_state_store.dart';

// 메인 앱의 첫 화면(메뉴). 각 기능 화면으로 보내고, 오버레이를 켜고, 다크모드를 토글함.

// ── 목차 ─────────────────────────────────
//  · 생명주기·동기화 : 저장값 변경 구독 + 돌아왔을 때(resumed) 재로드
//  · 오버레이 열기   : 권한 확인 → 창 띄움 → 홈으로 보내기
//  · 창 대기/닫기    : 재오픈 시 투명창 남는 레이스 방어
//  · 권한 확인       : 오버레이 권한 없으면 설정으로
//  · build / 메뉴 카드(_buildMenuCard)
// ────────────────────────────────────────────

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  // StatefulWidget이 자신의 상태(State) 객체를 만드는 필수 메서드.
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

// WidgetsBindingObserver를 섞은 이유: 권한 설정 화면에 갔다 "돌아왔을 때"(resumed)를
//   감지해서 오버레이를 마저 켜고 최신 데이터로 맞추려고.
class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  // 네이티브 MainActivity에 "홈으로 가라"고 요청하는 채널. 오버레이를 띄운 뒤 앱을
  // 백그라운드로 보내야 오버레이가 다른 앱(게임) 위에 떠 보여서 씀.
  static const MethodChannel _homeChannel = MethodChannel(
    'com.example.gimal/home',
  );

  // 저장소 변경 이벤트 구독(오버레이가 데이터를 바꾸면 받기 위함).
  StreamSubscription<dynamic>? _overlaySubscription;
  // 권한 설정 화면에 다녀온 뒤 오버레이를 자동으로 열지 기억하는 플래그.
  bool _openOverlayAfterPermission = false;
  // 오버레이 여는 중 중복 호출을 막는 플래그(버튼 연타 방지).
  bool _isOpeningOverlay = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // 앱 생명주기(resumed) 감지 등록 → dispose에서 해제

    // 오버레이 쪽에서 북마크/메모/다크모드를 바꾸면 메인 앱도 즉시 최신으로 맞추려고 구독함.
    _overlaySubscription = AppStateStore.stateEvents.listen((event) async {
      if (event == AppStateStore.stateUpdatedEvent) {
        await _reloadStoredState();
      }
    });
    // 처음 켜질 때 저장값을 한 번 읽어 와야 빈 상태로 안 떠서 호출.
    _reloadStoredState();
  }

  // 화면이 사라질 때 initState에서 등록한 것들을 해제(안 하면 누수 + dispose 후 setState 크래시).
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this); // 생명주기 관찰 해제(addObserver의 짝)
    _overlaySubscription?.cancel(); // 이벤트 구독 취소(listen의 짝)
    super.dispose(); // 프레임워크 정리(필수)
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 다시 화면에 돌아왔을 때(resumed): ① 오버레이가 바꾼 값 반영, ② 권한 허용하고
    //   돌아온 경우 미뤄둔 오버레이를 마저 켬. (권한 요청은 설정 앱으로 나갔다 오기 때문)
    if (state == AppLifecycleState.resumed) {
      _reloadStoredState();
      _openOverlayIfPermissionWasGranted();
    }
  }

  // 저장소의 다크모드/북마크/메모를 메인 앱 전역 상태에 다시 넣으려고 둠.
  Future<void> _reloadStoredState() async {
    final isDark = await AppStateStore.loadDarkMode();
    final bookmarks = await AppStateStore.loadBookmarks();
    final memos = await AppStateStore.loadMemos();
    if (!mounted) return;
    globalThemeNotifier.value = isDark;
    globalBookmarks = bookmarks;
    globalMemos = memos;
  }

  // "오버레이 전환" 버튼: 권한을 먼저 확인하고, 있으면 오버레이를 켜고 홈으로 보냄.
  Future<void> _startOverlay() async {
    if (_isOpeningOverlay) return;
    if (!await _checkOverlayPermission()) return;

    await _openOverlayAndGoHome();
  }

  // 권한 설정 화면에서 허용하고 돌아왔을 때, 미뤄둔 오버레이를 켜려고 둠.
  Future<void> _openOverlayIfPermissionWasGranted() async {
    if (!_openOverlayAfterPermission || _isOpeningOverlay) return;
    if (!await FlutterOverlayWindow.isPermissionGranted()) return;

    _openOverlayAfterPermission = false;
    await _openOverlayAndGoHome();
  }

  // 오버레이를 띄운 직후 홈으로 보내, 다른 앱 위에 오버레이만 남게 하려고 둠.
  Future<void> _openOverlayAndGoHome() async {
    _isOpeningOverlay = true;
    try {
      await _openOverlayWindow(closeBeforeOpen: true);
      await _homeChannel.invokeMethod('goHome');
    } catch (error) {
      // 실패하면 사용자에게 알려주려고 스낵바 표시.
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('오버레이를 열지 못했습니다: $error')));
    } finally {
      _isOpeningOverlay = false;
    }
  }

  // 실제로 오버레이 창을 띄우는 공통 함수.
  Future<void> _openOverlayWindow({bool closeBeforeOpen = false}) async {
    // 이전 오버레이가 남아 있으면 투명 창만 겹쳐 떠서, 먼저 닫고 시작.
    if (closeBeforeOpen) {
      await _closeOverlayIfActive();
    }
    // defaultFlag(NOT_FOCUSABLE)로 시작해야 뒤로가기·터치가 아래 앱으로 통과함.
    // 처음엔 matchParent(전체화면)로 띄우고, 오버레이가 첫 프레임 뒤 내용 크기로 줄임.
    await FlutterOverlayWindow.showOverlay(
      enableDrag: false,
      alignment: OverlayAlignment.topLeft,
      overlayTitle: 'gimal',
      overlayContent: 'Overlay menu',
      flag: OverlayFlag.defaultFlag,
      positionGravity: PositionGravity.none,
      startPosition: OverlayPosition(0, 0),
      width: WindowSize.matchParent,
      height: WindowSize.matchParent,
    );

    // 서비스가 실제로 올라온 뒤에 데이터를 보내야 해서 잠깐 대기.
    await _waitUntilOverlayStarted();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    // 오버레이가 최신 데이터를 읽도록 한 번 알림(실패해도 무시).
    try {
      await FlutterOverlayWindow.shareData(AppStateStore.stateUpdatedEvent);
    } catch (_) {
      debugPrint('오버레이 상태 이벤트 디버그 확인 글.');
    }
  }

  // showOverlay 직후엔 서비스가 아직 안 떠 있을 수 있어, isActive가 될 때까지 폴링하려고 둠.
  // 3초(30×100ms) 안에 안 뜨면 예외를 던져 호출부가 실패를 알 수 있게 함.
  Future<void> _waitUntilOverlayStarted() async {
    for (var count = 0; count < 30; count++) {
      if (await FlutterOverlayWindow.isActive()) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    throw StateError('오버레이가 열리지 않았습니다.');
  }

  // 이미 떠 있는 오버레이가 있으면 닫아, 재오픈 시 이전 투명 창이 남지 않게 하려고 둠.
  //해당 코드는 "오버레이 창을 염" -> "앱으로 클릭" ->"메인에서 다시 오버레이 전환 클릭" ->"오버레이 안뜸" -> 하지만 오버레이는 떠 있다 생각해 클릭이 안됨.
  //이러한 상태가 있는걸 발견했기에, 생성.
  Future<void> _closeOverlayIfActive() async {
    try {
      if (await FlutterOverlayWindow.isActive()) {
        await FlutterOverlayWindow.closeOverlay();
        await _waitUntilOverlayClosed();
      }
    } catch (error) {
      debugPrint('closeOverlayIfActive failed: $error');
    }
  }

  // closeOverlay 직후 바로 showOverlay를 부르면 실기기에서 투명 창만 남는 경우가 있어,
  // 실제로 닫힐 때까지 기다리려고 둔 함수.
  Future<void> _waitUntilOverlayClosed() async {
    for (var count = 0; count < 10; count++) {
      try {
        if (!await FlutterOverlayWindow.isActive()) {
          await Future<void>.delayed(const Duration(milliseconds: 300)); // 0.3초동안 대기
          return;
        }
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));// 오버레이 꺼진거 확인 시간 코드
    }
    // 그래도 안 닫히면 한 번 더 시도.
    try {
      await FlutterOverlayWindow.closeOverlay(); // 그냥 강제로 꺼버리기
    } catch (_) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    //오버레이가 꺼지는 경우 -> 앱으로 버튼
    //앱으로 누르고 -> 곧바로 오버레이 전환 -> 버그 터질수도 있어서 0.3초 정도 시스템이 "이거 제거함"의 시간을 줌
  }

  // 오버레이(SYSTEM_ALERT_WINDOW) 권한이 없으면 설정으로 보낼지 물어보려고 둠.
  Future<bool> _checkOverlayPermission() async {
    if (await FlutterOverlayWindow.isPermissionGranted()) {
      return true;
    }
    if (!mounted) return false;

    // 권한이 왜 필요한지 알려주고 설정으로 갈지 확인받음.
    final shouldRequest = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('오버레이 권한 필요'),
          content: const Text('플로팅 아이콘을 화면 위에 띄우려면 오버레이 권한을 허용해야 합니다.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('권한 설정'),
            ),
          ],
        );
      },
    );

    if (shouldRequest != true) return false;

    // 설정 앱으로 나가므로, 돌아왔을 때 자동으로 열도록 플래그를 켜 둠.
    _openOverlayAfterPermission = true;
    await FlutterOverlayWindow.requestPermission();
    final granted = await FlutterOverlayWindow.isPermissionGranted();
    if (granted) {
      _openOverlayAfterPermission = false;
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 기능별 큰 메뉴 카드를 세로로 쌓아 각 화면으로 들어가게 함.
    return Scaffold(
      body: SafeArea( // 타이틀이니 그 근처에 뭐가 있으면 거슬려 보임
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 35), // 20은 너무 좁고 40은 너무 큼 30~35가 제일 적당했음
          children: [
            Text(
              '안나가공 컨트롤러',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: theme.textTheme.bodyLarge?.color, //따로 지정하지 않은 이유 -> 다크ON 하얀색 / 다크 off 검은색
              ),
            ),
            const SizedBox(height: 32),
            _buildMenuCard(
              context,
              '웹 검색',
              Icons.search,
              Colors.blueAccent,
              const UrlSearchScreen(),
            ),
            _buildMenuCard(
              context,
              '북마크',
              Icons.bookmark_border,
              Colors.deepPurpleAccent,
              const BookmarkScreen(),
            ),
            _buildMenuCard(
              context,
              '메모',
              Icons.description_outlined,
              Colors.green,
              const MemoScreen(),
            ),
            const SizedBox(height: 20),
            // 화면 이동이 아니라 동작(오버레이 켜기)이라 screen 없이 onTap만 넘김.
            _buildMenuCard(
              context,
              '오버레이 전환',
              Icons.layers,
              Colors.teal,
              null,
              onTap: _startOverlay,
            ),
            // 다크모드는 전역 notifier라, 값이 바뀌면 이 카드(문구·아이콘)도 다시 그려지게 함.
            ValueListenableBuilder<bool>(
              valueListenable: globalThemeNotifier,
              builder: (context, isDark, child) {
                return _buildMenuCard(
                  context,
                  isDark ? '다크 모드 끄기' : '다크 모드 켜기',
                  isDark ? Icons.light_mode : Icons.dark_mode,
                  Colors.orangeAccent,
                  null,
                  onTap: () async {
                    globalThemeNotifier.value = !globalThemeNotifier.value;
                    await AppStateStore.saveDarkMode(globalThemeNotifier.value);
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // 메뉴 카드를 반복해서 만들려고 둔 공통 함수(틀). 카드마다 다른 재료만 받아 같은 모양으로 찍어냄.
  // 반환타입 Widget = 카드(화면 조각) 하나를 만들어 돌려줌.
  // 앞 5개(context~screen)는 '순서대로' 넘기는 위치 매개변수,
  // { } 안 onTap은 '이름 붙여' 넘기는 선택적 매개변수.
  Widget _buildMenuCard(
    BuildContext context, // 현재 맥락(테마·네비게이션). 모든 카드가 공통으로 넘김.
    String title, // 카드 제목 (예: '웹 검색' / '오버레이 전환' / '다크 모드 켜기')
    IconData icon, // 아이콘 (예: Icons.search=URL, Icons.layers=오버레이)
    Color iconColor, // 아이콘 색 (예: blueAccent=URL, teal=오버레이)
    Widget? screen, { // 이동할 화면. 예: URL/북마크/메모 카드만 줌(→해당 화면). 오버레이·다크모드는 null.
    VoidCallback? onTap, // 실행할 동작. 예: 오버레이 전환(_startOverlay)·다크모드 토글이 씀. 이동 카드는 생략.
  }) {
    // 현재 테마(밝은/어두운)를 가져와 색을 거기서 읽어 씀(다크모드 자동 반영).
    final theme = Theme.of(context);

    // InkWell: 탭이 되고 누를 때 물결(ripple) 효과를 주는 위젯.
    return InkWell(
      // onTap이 넘어왔으면 그걸 실행(오버레이/다크모드처럼 '동작'), 없으면(null)
      //   screen으로 화면 이동(push). ??는 "앞이 null이면 뒤를 쓴다"는 뜻.
      onTap:
          onTap ??
          () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => screen!),
            );
          },
      // 물결 효과도 카드의 둥근 모서리에 맞춰 잘리게 같은 반경을 줌.
      borderRadius: BorderRadius.circular(16),
      // 바깥 Container = 카드 그 자체(배경색·둥근 모서리·테두리).
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 8), // 카드 바깥 여백
        padding: const EdgeInsets.all(16), // 카드 안쪽 여백(내용과 테두리 사이)
        decoration: BoxDecoration(
          color: theme.cardColor, // 카드 배경색(테마에서)
          borderRadius: BorderRadius.circular(16), // 모서리 둥글게
          border: Border.all(color: theme.dividerColor, width: 1), // 얇은 테두리
        ),
        // 가로로 [아이콘][간격][제목] 배치.
        child: Row(
          children: [
            // 안쪽 Container = 아이콘을 감싸는 연한 색 동그란 배경 박스.
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                // 아이콘 색을 15% 투명도로 깔아 '연한 같은 계열' 배경을 만듦.
                color: iconColor.withOpacity(0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: iconColor, size: 24),
            ),
            const SizedBox(width: 16), // 아이콘과 글자 사이 간격
            // Expanded: 아이콘을 뺀 '남은 가로 폭'을 글자가 다 차지하게 함(길면 줄바꿈/잘림 기준).
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  color: theme.textTheme.bodyLarge?.color, // 본문 글자색(테마에서)
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
