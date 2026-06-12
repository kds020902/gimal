import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:gimal/overlay/overlay_view.dart';
import 'package:gimal/screens/home_screen.dart';
import 'package:gimal/services/app_state_store.dart';

// 앱과 오버레이의 시작점을 모아둔 파일이다.
// 다크모드, 북마크, 메모의 전역 상태를 처음 불러오고 화면 테마를 결정한다.

// 메인 앱 전체의 다크모드 상태를 바로 반영하기 위해 ValueNotifier를 사용한다.
final ValueNotifier<bool> globalThemeNotifier = ValueNotifier(false);

// 북마크와 메모는 메인 앱 여러 화면에서 같이 쓰기 때문에 전역 목록으로 관리한다.
List<Map<String, String>> globalBookmarks = AppStateStore.defaultBookmarks();
List<Map<String, String>> globalMemos = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 앱이 켜질 때 저장된 설정과 데이터를 먼저 불러온 뒤 화면을 실행한다.
  globalThemeNotifier.value = await AppStateStore.loadDarkMode();
  globalBookmarks = await AppStateStore.loadBookmarks();
  globalMemos = await AppStateStore.loadMemos();
  runApp(const MyApp());
}

@pragma('vm:entry-point')
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  // 오버레이 서비스가 따로 실행될 때 사용하는 시작 함수이다.
  runApp(const OverlayApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    // 다크모드 값이 바뀌면 MaterialApp이 다시 그려져 테마가 바로 바뀐다.
    return ValueListenableBuilder<bool>(
      valueListenable: globalThemeNotifier,
      builder: (context, isDark, child) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          themeMode: isDark ? ThemeMode.dark : ThemeMode.light,
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
