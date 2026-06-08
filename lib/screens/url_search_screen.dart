import 'package:flutter/material.dart';
import 'package:gimal/main.dart';
import 'package:gimal/services/app_state_store.dart';
import 'package:webview_flutter/webview_flutter.dart';

// 사용자가 입력한 검색어 또는 URL을 WebView로 여는 화면이다.
// 현재 열린 페이지를 북마크로 저장하는 기능도 함께 담당한다.

class UrlSearchScreen extends StatefulWidget {
  const UrlSearchScreen({super.key});

  @override
  State<UrlSearchScreen> createState() => _UrlSearchScreenState();
}

class _UrlSearchScreenState extends State<UrlSearchScreen> {
  // 검색창 입력값과 WebView를 제어하기 위한 컨트롤러이다.
  final TextEditingController _searchController = TextEditingController();
  late final WebViewController _webViewController;

  // 검색 전 안내 화면과 검색 후 WebView 화면을 구분하기 위한 값이다.
  bool _isSearching = false;
  String _currentUrl = '';

  @override
  void initState() {
    super.initState();

    // WebView 설정을 초기화하고, 페이지 로딩이 끝나면 현재 URL을 기억한다.
    _webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (String url) {
            setState(() => _currentUrl = url);
          },
        ),
      );
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // 입력값이 URL이면 바로 열고, 일반 검색어면 구글 검색 주소로 바꿔 연다.
  void _performSearch(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;

    final uri = _makeSearchUri(trimmed);
    if (uri == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('주소를 확인해주세요.')));
      return;
    }

    setState(() => _isSearching = true);
    _webViewController.loadRequest(uri);
  }

  // URL과 검색어를 구분해서 WebView가 열 수 있는 Uri 형태로 변환한다.
  Uri? _makeSearchUri(String value) {
    if (value.startsWith('http://') || value.startsWith('https://')) {
      final uri = Uri.tryParse(value);
      if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
      return uri;
    }

    return Uri.https('www.google.com', '/search', {'q': value});
  }

  // 현재 보고 있는 웹페이지를 북마크 목록에 저장하는 팝업을 띄운다.
  void _saveBookmark() {
    if (_currentUrl.isEmpty) return;

    final titleController = TextEditingController(
      text: '북마크 ${globalBookmarks.length + 1}',
    );
    final descController = TextEditingController();

    showDialog<void>(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        return AlertDialog(
          backgroundColor: theme.cardColor,
          title: Text(
            '북마크 저장',
            style: TextStyle(color: theme.textTheme.bodyLarge?.color),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: titleController,
                  style: TextStyle(color: theme.textTheme.bodyLarge?.color),
                  decoration: const InputDecoration(labelText: '북마크 이름'),
                ),
                const SizedBox(height: 16),
                Text(
                  'URL',
                  style: TextStyle(color: theme.hintColor, fontSize: 12),
                ),
                Text(
                  _currentUrl,
                  style: TextStyle(color: theme.textTheme.bodySmall?.color),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: descController,
                  style: TextStyle(color: theme.textTheme.bodyLarge?.color),
                  decoration: const InputDecoration(labelText: '설명'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('취소'),
            ),
            TextButton(
              onPressed: () async {
                setState(() {
                  globalBookmarks.add({
                    'title': titleController.text,
                    'url': _currentUrl,
                    'desc': descController.text,
                  });
                });
                await AppStateStore.saveBookmarks(globalBookmarks);
                if (!context.mounted) return;
                Navigator.pop(context);
                if (!mounted) return;
                ScaffoldMessenger.of(
                  this.context,
                ).showSnackBar(const SnackBar(content: Text('북마크가 저장되었습니다')));
              },
              child: const Text('저장'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 위쪽에는 검색창과 북마크 버튼을 두고, 아래에는 WebView 또는 안내 문구를 보여준다.
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Expanded(
              child: Container(
                height: 40,
                decoration: BoxDecoration(
                  color: theme.cardColor,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: TextField(
                  controller: _searchController,
                  style: TextStyle(color: theme.textTheme.bodyLarge?.color),
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: '검색어를 입력하시오',
                    hintStyle: TextStyle(color: theme.hintColor),
                    prefixIcon: Icon(Icons.search, color: theme.hintColor),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  onSubmitted: _performSearch,
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.star_border, color: Colors.amber),
              onPressed: _saveBookmark,
            ),
          ],
        ),
      ),
      body: _isSearching
          ? WebViewWidget(controller: _webViewController)
          : Center(
              child: Text(
                '이곳은 검색한 화면이 나올 곳이오',
                style: TextStyle(color: theme.hintColor),
              ),
            ),
    );
  }
}
