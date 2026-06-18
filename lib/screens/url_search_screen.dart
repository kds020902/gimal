import 'package:flutter/material.dart';
import 'package:gimal/main.dart';
import 'package:gimal/services/app_state_store.dart';
import 'package:webview_flutter/webview_flutter.dart';

// 검색어/URL을 WebView로 여는 화면. 메인 앱은 Activity 위에서 돌아서 Flutter WebView가
// 정상 동작하므로(오버레이와 달리) 여기선 webview_flutter를 그대로 씀.
// 현재 보고 있는 페이지를 북마크로 저장하는 기능도 같이 둠.

// ── 목차 (본문에서 같은 번호 헤더로 점프) ──────
//  1. WebView 초기화 : JS 켜고 · 페이지 이동 시 현재 URL 기억
//  2. 검색           : 입력을 무조건 구글 검색으로 엶
//  3. 북마크 저장     : 지금 보는 페이지를 북마크로(팝업)
//  4. build          : 검색창 + 웹뷰
// ────────────────────────────────────────────

class UrlSearchScreen extends StatefulWidget {
  const UrlSearchScreen({super.key});

  // StatefulWidget이 자신의 상태(State) 객체를 만드는 필수 메서드.
  @override
  State<UrlSearchScreen> createState() => _UrlSearchScreenState();
}

class _UrlSearchScreenState extends State<UrlSearchScreen> {
  // 검색 입력값을 읽으려고 둔 컨트롤러.
  final TextEditingController _searchController = TextEditingController();
  // WebView를 코드에서 제어(loadRequest)하려고 둠. initState에서 한 번만 만들어서 late final.
  late final WebViewController _webViewController;

  // 검색 전(안내문)과 검색 후(WebView)를 구분하려는 플래그.
  bool _isSearching = false;
  // 북마크 저장에 쓰려고 "지금 열려 있는 주소"를 기억해 둠.
  String _currentUrl = '';

  // ═══ 1. WebView 초기화 ═══════════════════════
  // 작동: WebView를 한 번 만들고 JS 켬. 페이지 이동이 끝날 때마다 현재 주소를 기억해 둠.
  @override
  void initState() {
    super.initState();

    // JS 켜고, 배경 투명, 페이지 이동이 끝나면 현재 URL을 기억하도록 설정.
    _webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..setNavigationDelegate(
        NavigationDelegate(
          // 링크를 눌러 이동해도 _currentUrl이 최신이 되게 갱신(북마크가 현재 페이지를 저장).
          onPageFinished: (String url) {
            setState(() => _currentUrl = url);
          },
        ),
      );
  }

  // 화면이 사라질 때 컨트롤러를 해제(안 풀면 메모리 누수).
  @override
  void dispose() {
    _searchController.dispose();
    super.dispose(); // 프레임워크 정리(필수)
  }

  // ═══ 2. 검색 ═════════════════════════════════
  // 작동: 입력값을 구글 검색 URL로 만들어 WebView에 로드(검색어는 자동 인코딩).
  // 입력을 "무조건 구글 검색"으로 연다(URL 직접 열기·검증 없이 단순화).
  void _performSearch(String query) {
    final trimmed = query.trim();
    // 빈칸이면 검색할 게 없어 무시.
    if (trimmed.isEmpty) return;

    setState(() => _isSearching = true);
    // Uri.https가 검색어를 자동 인코딩(공백·한글 등)해 줘서, 무조건 구글 검색 결과로 이동.
    _webViewController.loadRequest(
      Uri.https('www.google.com', '/search', {'q': trimmed}),
    );
  }

  // ═══ 3. 북마크 저장 ══════════════════════════
  // 작동: 지금 보는 페이지 주소로 팝업을 띄워, 이름/설명을 받아 북마크 목록에 추가+저장.
  // 지금 보고 있는 페이지를 북마크로 저장하는 팝업을 띄우려고 둠.
  void _saveBookmark() {
    // 아직 연 페이지가 없으면 저장할 게 없어 무시.
    if (_currentUrl.isEmpty) return;

    // 이름 기본값은 "북마크 N"으로 채워 그냥 저장해도 구분되게 함.
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
                // URL은 수정 대상이 아니라 현재 주소를 보여주기만 함.
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
                // 제목 키는 한글 '제목'로 통일(목록/오버레이가 같은 키로 읽음).
                setState(() {
                  globalBookmarks.add({
                    '제목': titleController.text,
                    'url': _currentUrl,
                    'desc': descController.text,
                  });
                });
                // 저장하면 이벤트로 다른 화면·오버레이에도 전파됨.
                await AppStateStore.saveBookmarks(globalBookmarks);
                // 비동기 뒤라 위젯이 살아있는지 확인하고 닫기/알림.
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

  // ═══ 4. build ════════════════════════════════
  // 작동: 앱바에 검색창+별 버튼, 본문은 검색 전엔 안내문 / 검색 후엔 WebView를 보여줌.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 앱바에 검색창+별(북마크) 버튼, 본문엔 검색 전 안내문 또는 검색 후 WebView.
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
