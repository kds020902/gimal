import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:gimal/overlay/overlay_view.dart';
import 'package:gimal/screens/home_screen.dart';
import 'package:gimal/services/app_state_store.dart';

// ── 목차 (본문에서 같은 번호 헤더로 점프) ──────
//  1. 전역 상태   : 다크모드 notifier · 북마크/메모 캐시
//  2. main        : 메인 앱 시작점 (저장값 로드 → runApp)
//  3. overlayMain : 오버레이 시작점 (별도 엔진 · 트리쉐이킹 보존)
//  4. MyApp       : 밝은/어두운 테마 정의
// ────────────────────────────────────────────

// ═══ 1. 전역 상태 ═══════════════════════════
// 여러 화면이 함께 보는 값을 전역에 둠. 다크모드는 notifier라 바뀌면 화면이 즉시 반영됨.

// 다크모드를 ValueNotifier로 둔 이유: 값이 바뀌면 MaterialApp을 감싼 리스너만 다시 그려
//   테마가 "즉시" 바뀌게 하려고(전역 setState나 재시작 없이).
final ValueNotifier<bool> globalThemeNotifier = ValueNotifier(false);

// 북마크/메모는 여러 화면이 같이 보고 쓰므로, 상태관리 라이브러리 없이 간단히 전역 변수로 공유함.
// (단일 소스는 저장소이고, 이건 화면이 빠르게 읽는 캐시 역할.)
List<Map<String, String>> globalBookmarks = AppStateStore.defaultBookmarks();
List<Map<String, String>> globalMemos = [];

// ═══ 2. main ════════════════════════════════
// 작동: 저장값(다크모드·북마크·메모)을 먼저 읽어 전역에 채운 뒤 runApp으로 앱 실행.

// 메인 앱의 시작점.
Future<void> main() async {
  // runApp 전에 플랫폼 채널(저장소)을 쓰려면 바인딩을 먼저 초기화해야 함.
  WidgetsFlutterBinding.ensureInitialized();
  // 첫 프레임이 빈 화면이 안 되게, 저장된 값을 먼저 읽어 전역에 채운 뒤 실행.
  globalThemeNotifier.value = await AppStateStore.loadDarkMode();
  globalBookmarks = await AppStateStore.loadBookmarks();
  globalMemos = await AppStateStore.loadMemos();
  runApp(const MyApp());
}

// ═══ 3. overlayMain ═════════════════════════
// 작동: 오버레이는 별도 엔진에서 이 함수로 시작. 플러그인 수동 등록 후 OverlayApp 실행.

//"" 오버레이 전용 시작점.""
// flutter_overlay_window가 별도 엔진에서 이 함수를 이름으로 찾아 실행함.
// @pragma('vm:entry-point'): 릴리스 빌드에서 호출처가 없다고 트리쉐이킹으로 지워지지 않게 보존.
@pragma('vm:entry-point')
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  // 오버레이는 별도 엔진이라 플러그인이 자동 등록되지 않을 수 있어, 수동으로 등록해야
  // SharedPreferences·메서드 채널 같은 게 동작함.
  DartPluginRegistrant.ensureInitialized();
  runApp(const OverlayApp());
}

// ═══ 4. MyApp ═══════════════════════════════
// 작동: 밝은/어두운 테마를 둘 다 정의하고, 다크모드 값에 따라 themeMode로 골라 적용.
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    // 다크모드 값이 바뀌면 여기 builder만 다시 돌아 MaterialApp의 테마가 바로 바뀜.
    return ValueListenableBuilder<bool>(
      valueListenable: globalThemeNotifier,
      builder: (context, isDark, child) {
        // theme/darkTheme를 둘 다 정의하고 themeMode로 고르게 해서, 토글 시 깔끔히 전환되게 함.
        return MaterialApp(
          debugShowCheckedModeBanner: false, //거슬리는 디버그 배너 삭제
          themeMode: isDark ? ThemeMode.dark : ThemeMode.light, //참이면 다크모드 / 거짓이면 꺼짐
          theme: ThemeData(
            brightness: Brightness.light,
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            scaffoldBackgroundColor: Colors.white,
            cardColor: const Color(0xFFF8FAFC),
            appBarTheme: const AppBarTheme(
              backgroundColor: Colors.white,
              foregroundColor: Colors.black,
              elevation: 0,
              titleTextStyle: TextStyle(
                color: Colors.black,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          darkTheme: ThemeData(
            brightness: Brightness.dark,
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.teal,
              brightness: Brightness.dark,
            ),
            scaffoldBackgroundColor: const Color(0xFF020617),
            cardColor: const Color(0xFF0F172A),
            appBarTheme: const AppBarTheme(
              backgroundColor: Color(0xFF0F172A),
              foregroundColor: Colors.white,
              elevation: 0,
              titleTextStyle: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          home: const HomeScreen(),
        );
      },
    );
  }
}
