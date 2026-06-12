import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:gimal/main.dart';
import 'package:gimal/screens/bookmark_screen.dart';
import 'package:gimal/screens/memo_screen.dart';
import 'package:gimal/screens/url_search_screen.dart';
import 'package:gimal/services/app_state_store.dart';

// 메인 앱의 첫 화면을 만드는 파일이다.
// URL 검색, 북마크, 메모 화면으로 이동하고 오버레이 전환과 다크모드를 제어한다.

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  // Android 쪽 MainActivity에 "홈 화면으로 이동" 요청을 보낼 때 사용하는 채널이다.
  static const MethodChannel _homeChannel = MethodChannel(
    'com.example.gimal/home',
  );

  StreamSubscription<dynamic>? _overlaySubscription;
  bool _openOverlayAfterPermission = false;
  bool _isOpeningOverlay = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // 오버레이에서 데이터가 바뀌면 메인 앱도 저장소를 다시 읽어 최신 상태로 맞춘다.
    _overlaySubscription = AppStateStore.stateEvents.listen((event) async {
      if (event == AppStateStore.stateUpdatedEvent) {
        await _reloadStoredState();
      }
    });
    _reloadStoredState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _overlaySubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 앱이 다시 화면에 보일 때 저장된 값을 다시 읽어 오버레이 변경사항을 반영한다.
    if (state == AppLifecycleState.resumed) {
      _reloadStoredState();
      _openOverlayIfPermissionWasGranted();
    }
  }

  // 저장소의 다크모드, 북마크, 메모 값을 메인 앱 전역 상태에 다시 넣는다.
  Future<void> _reloadStoredState() async {
    final isDark = await AppStateStore.loadDarkMode();
    final bookmarks = await AppStateStore.loadBookmarks();
    final memos = await AppStateStore.loadMemos();
    if (!mounted) return;
    globalThemeNotifier.value = isDark;
    globalBookmarks = bookmarks;
    globalMemos = memos;
  }

  // 오버레이 권한을 확인한 뒤 오버레이를 띄우고 홈 화면으로 이동한다.
  Future<void> _startOverlay() async {
    if (_isOpeningOverlay) return;
    if (!await _checkOverlayPermission()) return;

    await _openOverlayAndGoHome();
  }

  Future<void> _openOverlayIfPermissionWasGranted() async {
    if (!_openOverlayAfterPermission || _isOpeningOverlay) return;
    if (!await FlutterOverlayWindow.isPermissionGranted()) return;

    _openOverlayAfterPermission = false;
    await _openOverlayAndGoHome();
  }

  Future<void> _openOverlayAndGoHome() async {
    _isOpeningOverlay = true;
    try {
      await _openOverlayWindow(closeBeforeOpen: true);
      await _homeChannel.invokeMethod('goHome');
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('오버레이를 열지 못했습니다: $error')));
    } finally {
      _isOpeningOverlay = false;
    }
  }

  // 실제 오버레이 창을 여는 공통 함수이다.
  Future<void> _openOverlayWindow({bool closeBeforeOpen = false}) async {
    if (closeBeforeOpen) {
      await _closeOverlayIfActive();
    }
    await FlutterOverlayWindow.showOverlay(
      enableDrag: false,
      alignment: OverlayAlignment.topLeft,
      overlayTitle: 'gimal',
      overlayContent: 'Overlay menu',
      flag: OverlayFlag.focusPointer,
      positionGravity: PositionGravity.none,
      startPosition: OverlayPosition(0, 0),
      width: WindowSize.matchParent,
      height: WindowSize.matchParent,
    );

    await _waitUntilOverlayStarted();
    await Future<void>.delayed(const Duration(milliseconds: 180));

    try {
      await FlutterOverlayWindow.shareData(AppStateStore.stateUpdatedEvent);
    } catch (_) {
      debugPrint('Overlay state event was skipped.');
    }
  }

  // showOverlay 호출 뒤 실제 서비스가 올라올 때까지 잠깐 기다린다.
  Future<void> _waitUntilOverlayStarted() async {
    for (var count = 0; count < 30; count++) {
      if (await FlutterOverlayWindow.isActive()) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    throw StateError('Overlay service did not become active.');
  }

  // 이미 떠 있는 오버레이가 있으면 먼저 닫아 이전 투명 창이 남지 않게 한다.
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

  // closeOverlay 직후 바로 showOverlay를 호출하면 실제 폰에서 투명 창만 남을 수 있어 닫힘을 기다린다.
  Future<void> _waitUntilOverlayClosed() async {
    for (var count = 0; count < 24; count++) {
      try {
        if (!await FlutterOverlayWindow.isActive()) {
          await Future<void>.delayed(const Duration(milliseconds: 180));
          return;
        }
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 180));
        return;
      }

      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    try {
      await FlutterOverlayWindow.closeOverlay();
    } catch (_) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 350));
  }

  // Android 오버레이 권한이 없으면 사용자에게 권한 설정 화면으로 갈지 물어본다.
  Future<bool> _checkOverlayPermission() async {
    if (await FlutterOverlayWindow.isPermissionGranted()) {
      return true;
    }
    if (!mounted) return false;

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

    _openOverlayAfterPermission = true;
    await FlutterOverlayWindow.requestPermission();
    final granted = await FlutterOverlayWindow.isPermissionGranted();
    if (granted) {
      _openOverlayAfterPermission = false;
      return true;
    }

    if (!granted && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('권한을 허용한 뒤 앱으로 돌아오면 오버레이가 열립니다.')),
      );
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 큰 메뉴 카드들을 세로로 배치해서 각 기능 화면으로 들어가게 한다.
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 36),
          children: [
            Text(
              '안나가공 컨트롤러',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: theme.textTheme.bodyLarge?.color,
              ),
            ),
            const SizedBox(height: 32),
            _buildMenuCard(
              context,
              'URL 검색',
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
            _buildMenuCard(
              context,
              '오버레이 전환',
              Icons.layers,
              Colors.teal,
              null,
              onTap: _startOverlay,
            ),
            ValueListenableBuilder<bool>(
              valueListenable: globalThemeNotifier,
              builder: (context, isDark, child) {
                // 다크모드 버튼은 현재 상태에 따라 문구와 아이콘이 바뀐다.
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

  Widget _buildMenuCard(
    BuildContext context,
    String title,
    IconData icon,
    Color iconColor,
    Widget? screen, {
    VoidCallback? onTap,
  }) {
    final theme = Theme.of(context);

    // 홈 화면에서 반복해서 쓰는 메뉴 카드 UI이다.
    return InkWell(
      onTap:
          onTap ??
          () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => screen!),
            );
          },
      borderRadius: BorderRadius.circular(16),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.cardColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: theme.dividerColor, width: 1),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: iconColor, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  color: theme.textTheme.bodyLarge?.color,
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
