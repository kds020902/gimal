import 'dart:async';
import 'dart:convert';

import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 북마크, 메모, 다크모드 값을 휴대폰 내부 저장소에 저장하는 파일이다.
// 메인 앱과 오버레이가 같은 데이터를 읽고, 변경 사실을 서로 알려주게 한다.

class AppStateStore {
  // 저장값이 바뀌었음을 메인 앱과 오버레이에 알려줄 때 쓰는 공통 신호이다.
  static const String stateUpdatedEvent = 'stateUpdated';

  // SharedPreferences에 저장할 때 사용하는 이름표이다.
  static const String bookmarksKey = 'bookmarks';
  static const String memosKey = 'memos';
  static const String darkModeKey = 'darkMode';
  static const String overlayExpandedKey = 'overlayExpanded';
  static const String openFullOverlayEvent = 'openFullOverlay';
  static const String openLauncherOverlayEvent = 'openLauncherOverlay';
  static Stream<dynamic>? _stateEvents;

  // 여러 화면이 같은 오버레이 이벤트를 같이 들을 수 있도록 broadcast stream으로 바꾼다.
  static Stream<dynamic> get stateEvents {
    _stateEvents ??= FlutterOverlayWindow.overlayListener.asBroadcastStream();
    return _stateEvents!;
  }

  // 저장된 북마크를 불러오고, 아직 저장된 값이 없으면 기본 북마크를 보여준다.
  static Future<List<Map<String, String>>> loadBookmarks() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(bookmarksKey);
    if (raw == null || raw.isEmpty) {
      return defaultBookmarks();
    }
    return _decodeList(raw);
  }

  // 북마크 목록을 문자열로 바꿔 저장한 뒤, 다른 화면에도 변경 사실을 알린다.
  static Future<void> saveBookmarks(List<Map<String, String>> bookmarks) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(bookmarksKey, jsonEncode(bookmarks));
    await _notifyStateUpdated();
  }

  // 저장된 메모 목록을 불러온다. 메모가 없으면 빈 목록을 반환한다.
  static Future<List<Map<String, String>>> loadMemos() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(memosKey);
    if (raw == null || raw.isEmpty) {
      return [];
    }
    return _decodeList(raw);
  }

  // 메모 목록을 저장하고, 메인 앱과 오버레이가 새 목록을 다시 읽게 알린다.
  static Future<void> saveMemos(List<Map<String, String>> memos) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(memosKey, jsonEncode(memos));
    await _notifyStateUpdated();
  }

  // 다크모드 설정을 불러온다. 저장된 값이 없으면 기본값은 꺼짐(false)이다.
  static Future<bool> loadDarkMode() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getBool(darkModeKey) ?? false;
  }

  // 다크모드 설정을 저장하고, 화면들이 즉시 새 테마를 적용하게 알린다.
  static Future<void> saveDarkMode(bool isDark) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(darkModeKey, isDark);
    await _notifyStateUpdated();
  }

  // 다음에 열릴 오버레이가 전체 화면인지 작은 아이콘인지 저장한다.
  static Future<bool> loadOverlayExpanded() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getBool(overlayExpandedKey) ?? false;
  }

  static Future<void> saveOverlayExpanded(bool expanded) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(overlayExpandedKey, expanded);
  }

  // 처음 실행했을 때 보여줄 기본 북마크 목록이다.
  static List<Map<String, String>> defaultBookmarks() {
    return [
      {
        'title': 'YouTube',
        'url': 'https://www.youtube.com',
        'desc': 'Video and search',
      },
      {
        'title': 'Google',
        'url': 'https://www.google.com',
        'desc': 'Search engine',
      },
    ];
  }

  // 저장된 JSON 문자열을 List<Map<String, String>> 형태로 안전하게 바꾼다.
  static List<Map<String, String>> _decodeList(String raw) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return [];
    }

    if (decoded is! List) {
      return [];
    }

    return decoded.whereType<Map>().map((item) {
      return item.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      );
    }).toList();
  }

  // 오버레이 통신이 실패해도 저장 기능 자체가 멈추지 않도록 예외를 무시한다.
  static Future<void> _notifyStateUpdated() async {
    try {
      await FlutterOverlayWindow.shareData(stateUpdatedEvent);
    } catch (_) {
      return;
    }
  }
}
