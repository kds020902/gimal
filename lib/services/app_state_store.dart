import 'dart:async';
import 'dart:convert';

import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 북마크/메모/다크모드를 휴대폰 내부 저장소(SharedPreferences)에 저장, 오버레이가 "같은 데이터를 읽고 변경을 서로 알리게" 하는 단일 통로 파일.
// (메인 앱과 오버레이는 서로 다른 엔진이라, 이 클래스로 데이터·신호를 맞춤.)

// ── 목차 ─────────────────────────────────
//  · 상수            : 변경신호(stateUpdatedEvent) · 저장 키
//  · stateEvents     : 변경 알림 스트림(broadcast)
//  · load/save       : 북마크 · 메모 · 다크모드 (읽기/저장)
//  · defaultBookmarks: 첫 실행 기본 북마크
//  · _decodeList     : 저장 JSON → 안전하게 변환
//  · _notifyStateUpdated : 바뀌었다고 양쪽에 신호
// ────────────────────────────────────────────

class AppStateStore {
  // 값이 바뀌었음을 양쪽에 알릴 때 쓰는 공통 신호 문자열. 보내는 쪽·받는 쪽이 같은 값을
  // 약속해야 해서 상수로 고정함.
  static const String stateUpdatedEvent = 'stateUpdated';

  // SharedPreferences에 저장할 때 쓰는 키(이름표). 오타로 다른 키에 저장되면 못 읽어서 상수로 둠.
  static const String bookmarksKey = 'bookmarks';
  static const String memosKey = 'memos';
  static const String darkModeKey = 'darkMode';
  static Stream<dynamic>? _stateEvents;

  // 여러 화면이 동시에 같은 이벤트를 들어야 해서 broadcast로 바꿔 둠.
  // (overlayListener는 단일 구독이라 그대로 쓰면 두 번째 listen에서 에러남.)
  // 한 번 만든 스트림을 재사용하려고 _stateEvents에 캐시.
  static Stream<dynamic> get stateEvents {
    _stateEvents ??= FlutterOverlayWindow.overlayListener.asBroadcastStream();
    return _stateEvents!;
  }

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
    return _decodeList(raw);
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
    return _decodeList(raw);
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

  // 저장된 JSON 문자열을 List<Map<String,String>>로 "안전하게" 바꾸려고 둠.
  // 손상되거나 옛 형식의 데이터가 와도 앱이 죽지 않게 try와 타입 검사로 막음.
  static List<Map<String, String>> _decodeList(String raw) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      // 파싱 실패(깨진 데이터)면 빈 목록으로 처리.
      return [];
    }

    // 기대한 List가 아니면 빈 목록.
    if (decoded is! List) {
      return [];
    }

    // Map만 골라, 키/값을 String으로 정규화(숫자 등 섞여 있어도 안전하게).
    return decoded.whereType<Map>().map((item) {
      return item.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      );
    }).toList();
  }

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
