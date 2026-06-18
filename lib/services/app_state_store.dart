import 'dart:async';
import 'dart:convert';

import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 북마크/메모/다크모드를 휴대폰 내부 저장소(SharedPreferences)에 저장, 오버레이가 "같은 데이터를 읽고 변경을 서로 알리게" 하는 단일 통로 파일.
// (메인 앱과 오버레이는 서로 다른 엔진이라, 이 클래스로 데이터·신호를 맞춤.)

// ── 목차 (본문에서 같은 번호 헤더로 점프) ──────
//  1. 상수            : 변경신호(stateUpdatedEvent) · 저장 키
//  2. stateEvents     : 변경 알림 스트림(broadcast)
//  3. load/save       : 북마크 · 메모 · 다크모드 (읽기/저장)
//  4. defaultBookmarks: 첫 실행 기본 북마크
//  5. _notifyStateUpdated : 바뀌었다고 양쪽에 신호
// ────────────────────────────────────────────

class AppStateStore {
  // ═══ 1. 상수 ════════════════════════════════
  // 작동: 양쪽이 약속한 신호 문자열·저장 키를 한 곳에 고정(오타로 어긋나는 것 방지).

  // 값이 바뀌었음을 양쪽에 알릴 때 쓰는 공통 신호 문자열. 보내는 쪽·받는 쪽이 같은 값을
  // 약속해야 해서 상수로 고정함.
  static const String stateUpdatedEvent = 'stateUpdated';

  // SharedPreferences에 저장할 때 쓰는 키(이름표). 오타로 다른 키에 저장되면 못 읽어서 상수로 둠.
  static const String bookmarksKey = 'bookmarks';
  static const String memosKey = 'memos';
  static const String darkModeKey = 'darkMode';
  static Stream<dynamic>? _stateEvents;

  // ═══ 2. stateEvents ═════════════════════════
  // 작동: 오버레이 리스너를 broadcast 스트림으로 감싸 여러 화면이 동시에 변경 신호를 받게 함.

  // 여러 화면이 동시에 같은 이벤트를 들어야 해서 broadcast로 바꿔 둠.
  // (overlayListener는 단일 구독이라 그대로 쓰면 두 번째 listen에서 에러남.)
  // 한 번 만든 스트림을 재사용하려고 _stateEvents에 캐시.
  static Stream<dynamic> get stateEvents {
    _stateEvents ??= FlutterOverlayWindow.overlayListener.asBroadcastStream();
    return _stateEvents!;
  }

  // ═══ 3. load/save ═══════════════════════════
  // 작동: load=저장소에서 읽어(reload로 최신화) 반환, save=JSON으로 저장 후 변경 신호 발송.

  // 저장된 북마크를 읽음. 저장된 게 없으면(첫 실행) 기본 북마크를 보여주려고 둠.
  static Future<List<Map<String, String>>> loadBookmarks() async {
    final prefs = await SharedPreferences.getInstance();
    // reload()를 부르는 이유: 오버레이는 별도 프로세스라 메모리 캐시가 옛날일 수 있어,
    //   디스크의 최신 값을 다시 읽게 강제함(이게 없으면 한쪽이 옛 데이터를 봄).
    await prefs.reload();
    final raw = prefs.getString(bookmarksKey);
    if (raw == null || raw.isEmpty) {
      return defaultBookmarks();
    }
    // 저장된 JSON 문자열을 화면이 쓸 List<Map<String,String>>로 변환.
    return (jsonDecode(raw) as List)
        .whereType<Map>()
        .map(
          (item) => item.map(
            (key, value) => MapEntry(key.toString(), value.toString()),
          ),
        )
        .toList();
  }

  // 북마크를 JSON 문자열로 저장하고, 변경됐음을 양쪽에 알리려고 둠.
  static Future<void> saveBookmarks(List<Map<String, String>> bookmarks) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(bookmarksKey, jsonEncode(bookmarks));
    await _notifyStateUpdated();
  }

  // 저장된 메모를 읽음. 없으면 빈 목록(메모는 기본값이 없어서).
  static Future<List<Map<String, String>>> loadMemos() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload(); // 위와 같은 이유(다른 프로세스의 최신값 반영).
    final raw = prefs.getString(memosKey);
    if (raw == null || raw.isEmpty) {
      return [];
    }
    // 저장된 JSON 문자열을 화면이 쓸 List<Map<String,String>>로 변환.
    return (jsonDecode(raw) as List)
        .whereType<Map>()
        .map(
          (item) => item.map(
            (key, value) => MapEntry(key.toString(), value.toString()),
          ),
        )
        .toList();
  }

  // 메모를 저장하고 변경을 알리려고 둠.
  static Future<void> saveMemos(List<Map<String, String>> memos) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(memosKey, jsonEncode(memos));
    await _notifyStateUpdated();
  }

  // 다크모드를 읽음. 저장값이 없으면 기본 꺼짐(false).
  static Future<bool> loadDarkMode() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getBool(darkModeKey) ?? false;
  }

  // 다크모드를 저장하고, 화면들이 즉시 새 테마를 적용하도록 알리려고 둠.
  static Future<void> saveDarkMode(bool isDark) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(darkModeKey, isDark);
    await _notifyStateUpdated();
  }

  // ═══ 4. defaultBookmarks ════════════════════
  // 작동: 저장된 북마크가 없을 때(첫 실행) 보여줄 기본 목록을 돌려줌.

  // 첫 실행 때 빈 화면 대신 보여줄 기본 북마크. 제목 키는 한글 '제목'으로 통일.
  static List<Map<String, String>> defaultBookmarks() {
    return [
      {
        '제목': 'YouTube',
        'url': 'https://www.youtube.com',
        'desc': 'Video and search',
      },
      {
        '제목': 'Google',
        'url': 'https://www.google.com',
        'desc': 'Search engine',
      },
    ];
  }


  // ═══ 5. _notifyStateUpdated ═════════════════
  // 작동: 저장 직후 상대(메인↔오버레이)에게 변경 신호를 보냄(통신 실패해도 저장은 유지).

  // 저장 후 상대(메인↔오버레이)에게 "바뀌었다"고 알리려고 둠.
  // 오버레이가 안 떠 있는 등으로 통신이 실패해도 저장 자체는 성공해야 해서 예외를 삼킴.
  static Future<void> _notifyStateUpdated() async {
    try {
      await FlutterOverlayWindow.shareData(stateUpdatedEvent);
    } catch (_) {
      return;
    }
  }
}
