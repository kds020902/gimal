import 'dart:async';

import 'package:flutter/material.dart';
import 'package:gimal/main.dart';
import 'package:gimal/services/app_state_store.dart';
import 'package:webview_flutter/webview_flutter.dart';

// 저장된 북마크 목록을 보여주는 화면이다.
// 북마크를 누르면 WebView로 열고, 수정/삭제한 내용은 저장소에 반영한다.

class BookmarkScreen extends StatefulWidget {
  const BookmarkScreen({super.key});

  @override
  State<BookmarkScreen> createState() => _BookmarkScreenState();
}

class _BookmarkScreenState extends State<BookmarkScreen>
    with WidgetsBindingObserver {
  StreamSubscription<dynamic>? _stateSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // 다른 화면이나 오버레이에서 북마크가 바뀌면 목록을 다시 불러온다.
    _stateSubscription = AppStateStore.stateEvents.listen((event) {
      if (event == AppStateStore.stateUpdatedEvent) {
        _loadBookmarks();
      }
    });
    _loadBookmarks();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stateSubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 앱이 다시 활성화될 때 저장된 북마크를 다시 읽어 최신 상태로 맞춘다.
    if (state == AppLifecycleState.resumed) {
      _loadBookmarks();
    }
  }

  // SharedPreferences에 저장된 북마크를 전역 목록에 반영한다.
  Future<void> _loadBookmarks() async {
    final bookmarks = await AppStateStore.loadBookmarks();
    if (!mounted) return;
    setState(() => globalBookmarks = bookmarks);
  }

  // 북마크 URL을 WebView 화면으로 열어준다.
  void _openUrl(String url) {
    final uri = _makeBookmarkUri(url);
    if (uri == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('URL을 확인해주세요.')));
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) {
          final controller = WebViewController()
            ..setJavaScriptMode(JavaScriptMode.unrestricted)
            ..loadRequest(uri);

          return Scaffold(
            appBar: AppBar(title: const Text('북마크')),
            body: WebViewWidget(controller: controller),
          );
        },
      ),
    );
  }

  // http가 없는 주소에는 https를 붙이고, 잘못된 주소면 null을 반환한다.
  Uri? _makeBookmarkUri(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;

    final text = trimmed.startsWith('http://') || trimmed.startsWith('https://')
        ? trimmed
        : 'https://$trimmed';
    final uri = Uri.tryParse(text);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
    return uri;
  }

  // 북마크의 제목, URL, 설명을 수정하거나 삭제하는 팝업을 띄운다.
  void _showEditDialog(int index) {
    final titleController = TextEditingController(
      text: globalBookmarks[index]['title'],
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
          TextButton(
            onPressed: () async {
              setState(() {
                globalBookmarks[index]['title'] = titleController.text;
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

    // 북마크가 없으면 안내 문구를, 있으면 ListTile 목록을 보여준다.
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
                    item['title'] ?? '',
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
