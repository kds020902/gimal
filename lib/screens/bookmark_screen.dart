import 'dart:async';

import 'package:flutter/material.dart';
import 'package:gimal/main.dart';
import 'package:gimal/services/app_state_store.dart';
import 'package:webview_flutter/webview_flutter.dart';

// 저장된 북마크 목록 화면. 누르면 WebView로 열고, 수정/삭제는 저장소에 반영함.

// ── 목차 ─────────────────────────────────
//  · 생명주기·동기화 : 북마크 변경 구독 + 돌아왔을 때 재로드
//  · 북마크 열기     : 눌러서 WebView로 (검증 없이 바로)
//  · 수정/삭제       : 편집 팝업
//  · build          : 북마크 목록
// ────────────────────────────────────────────

class BookmarkScreen extends StatefulWidget {
  const BookmarkScreen({super.key});

  // StatefulWidget이 자신의 상태(State) 객체를 만드는 필수 메서드.
  @override
  State<BookmarkScreen> createState() => _BookmarkScreenState();
}

// WidgetsBindingObserver를 섞은 이유: 다른 화면/오버레이에서 북마크가 바뀐 뒤 이 화면에
//   돌아왔을 때(resumed) 목록을 다시 읽어 최신으로 맞추려고.
class _BookmarkScreenState extends State<BookmarkScreen>
    with WidgetsBindingObserver {
  // 저장소 변경 이벤트 구독(오버레이가 북마크를 바꾸면 받기 위함).
  StreamSubscription<dynamic>? _stateSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // 앱 생명주기(resumed) 감지 등록 → dispose에서 해제

    // 다른 화면/오버레이에서 북마크가 바뀌면 즉시 다시 불러오려고 구독함.
    _stateSubscription = AppStateStore.stateEvents.listen((event) {
      if (event == AppStateStore.stateUpdatedEvent) {
        _loadBookmarks(); // 저장된 북마크 표시
      }
    });
    // 처음 들어왔을 때 한 번 읽어 옴.
    _loadBookmarks();
  }

  // 화면이 사라질 때 initState에서 등록한 것들을 해제(안 하면 누수 + dispose 후 setState 크래시).
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this); // 생명주기 관찰 해제(addObserver의 짝)
    _stateSubscription?.cancel(); // 이벤트 구독 취소(listen의 짝)
    super.dispose(); // 프레임워크 정리(필수)
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 앱이 다시 보일 때 저장값을 다시 읽어 화면을 맞춤.
    if (state == AppLifecycleState.resumed) {
      _loadBookmarks();
    }
  }

  // 저장소의 북마크를 전역 목록에 넣어 화면을 갱신하려고 둠.
  Future<void> _loadBookmarks() async {
    final bookmarks = await AppStateStore.loadBookmarks();
    if (!mounted) return;
    setState(() => globalBookmarks = bookmarks);
  }

  // 북마크 주소를 새 WebView 화면으로 연다.
  // (검증/안내 없이 그냥 엶 — 틀린 링크는 웹뷰가 알아서 에러 페이지로 처리하니까.)
  void _openUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return; // 빈 주소만 거름.
    // http(s)가 없으면 https를 붙여 정상 주소로(예: youtube.com → https://youtube.com).
    final text = trimmed.startsWith('http://') || trimmed.startsWith('https://')
        ? trimmed
        : 'https://$trimmed';

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) {
          // 이 화면에서만 쓰는 WebView라 여기서 바로 만들어 로드함.
          final controller = WebViewController()
            ..setJavaScriptMode(JavaScriptMode.unrestricted)
            ..loadRequest(Uri.parse(text));

          return Scaffold(
            appBar: AppBar(title: const Text('북마크')),
            body: WebViewWidget(controller: controller),
          );
        },
      ),
    );
  }

  // 북마크 한 개의 이름/URL/설명을 수정하거나 삭제하는 팝업을 띄우려고 둠.
  void _showEditDialog(int index) {
    // 기존 값을 미리 채워 두려고 컨트롤러에 현재 값을 넣음(제목 키는 한글 '제목').
    final titleController = TextEditingController(
      text: globalBookmarks[index]['제목'],
    );
    final urlController = TextEditingController(
      text: globalBookmarks[index]['url'],
    );
    final descController = TextEditingController(
      text: globalBookmarks[index]['desc'] ?? '',
    );

    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('북마크 수정하기'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleController,
              decoration: const InputDecoration(labelText: '북마크 이름'),
            ),
            TextField(
              controller: urlController,
              decoration: const InputDecoration(labelText: 'URL'),
            ),
            TextField(
              controller: descController,
              decoration: const InputDecoration(labelText: '설명'),
            ),
          ],
        ),
        actions: [
          // 삭제: 목록에서 빼고 저장(저장 시 다른 화면에도 전파).
          TextButton(
            onPressed: () async {
              setState(() => globalBookmarks.removeAt(index));
              await AppStateStore.saveBookmarks(globalBookmarks);
              Navigator.pop(context);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          // 저장: 수정한 값으로 덮어쓰고 저장.
          TextButton(
            onPressed: () async {
              setState(() {
                globalBookmarks[index]['제목'] = titleController.text;
                globalBookmarks[index]['url'] = urlController.text;
                globalBookmarks[index]['desc'] = descController.text;
              });
              await AppStateStore.saveBookmarks(globalBookmarks);
              Navigator.pop(context);
            },
            child: const Text('저장하기'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 비었으면 안내문, 있으면 ListTile 목록(누르면 열기, 연필로 수정).
    return Scaffold(
      appBar: AppBar(title: const Text('북마크')),
      body: globalBookmarks.isEmpty
          ? Center(
              child: Text(
                '북마크가 없습니다',
                style: TextStyle(color: theme.hintColor),
              ),
            )
          : ListView.separated(
              itemCount: globalBookmarks.length,
              separatorBuilder: (_, __) => Divider(color: theme.dividerColor),
              itemBuilder: (context, index) {
                final item = globalBookmarks[index];
                return ListTile(
                  leading: const Icon(Icons.star, color: Colors.amber),
                  title: Text(
                    item['제목'] ?? '',
                    style: TextStyle(color: theme.textTheme.bodyLarge?.color),
                  ),
                  subtitle: Text(
                    item['desc']?.isNotEmpty == true
                        ? item['desc']!
                        : 'No description',
                    style: TextStyle(color: theme.hintColor),
                  ),
                  onTap: () => _openUrl(item['url'] ?? ''),
                  trailing: IconButton(
                    icon: Icon(Icons.edit, color: theme.hintColor),
                    onPressed: () => _showEditDialog(index),
                  ),
                );
              },
            ),
    );
  }
}
