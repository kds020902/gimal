import 'dart:async';

import 'package:flutter/material.dart';
import 'package:gimal/main.dart';
import 'package:gimal/screens/memo_write_screen.dart';
import 'package:gimal/services/app_state_store.dart';

// 메모 목록 화면. 추가/수정/삭제를 처리하고, 오버레이에서 바뀐 메모도 즉시 다시 불러옴.

// ── 목차 (본문에서 같은 번호 헤더로 점프) ──────
//  1. 생명주기·동기화 : 메모 변경 구독 + 돌아왔을 때 재로드
//  2. 삭제/수정 이동  : 목록에서 삭제 · 작성화면(수정 모드)으로
//  3. build          : 메모 목록 + 우하단 추가 버튼
// ────────────────────────────────────────────

class MemoScreen extends StatefulWidget {
  const MemoScreen({super.key});

  // StatefulWidget이 자신의 상태(State) 객체를 만드는 필수 메서드.
  @override
  State<MemoScreen> createState() => _MemoScreenState();
}

// WidgetsBindingObserver를 섞은 이유: 작성 화면이나 오버레이에서 메모가 바뀐 뒤 돌아왔을 때
//   (resumed) 목록을 다시 읽어 최신으로 맞추려고.
class _MemoScreenState extends State<MemoScreen> with WidgetsBindingObserver {
  // 저장소 변경 이벤트 구독(오버레이가 메모를 바꾸면 받기 위함).
  StreamSubscription<dynamic>? _stateSubscription;

  // ═══ 1. 생명주기·동기화 ══════════════════════
  // 작동: 켜질 때 변경 구독+초기 로드 → 돌아오면(resumed) 재로드 → 닫힐 때 구독 해제.
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // 앱 생명주기(resumed) 감지 등록 → dispose에서 해제

    // 오버레이/다른 화면에서 메모가 바뀌면 즉시 다시 불러오려고 구독함.
    _stateSubscription = AppStateStore.stateEvents.listen((event) {
      if (event == AppStateStore.stateUpdatedEvent) {
        _loadMemos();
      }
    });
    // 처음 들어왔을 때 한 번 읽어 옴.
    _loadMemos();
  }

  // 화면이 사라질 때 initState에서 등록한 것들을 해제(안 하면 누수 + dispose 후 setState 크래시).
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this); // 생명주기 관찰 해제
    _stateSubscription?.cancel(); // 이벤트 구독 취소
    super.dispose(); // 프레임워크 정리(필수)
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 앱이 다시 보일 때 저장값을 다시 읽어 화면을 맞춤.
    if (state == AppLifecycleState.resumed) {
      _loadMemos();
    }
  }

  // 저장소의 메모를 전역 목록에 넣어 화면을 갱신하려고 둠.
  Future<void> _loadMemos() async {
    final memos = await AppStateStore.loadMemos();
    if (!mounted) return;
    setState(() => globalMemos = memos);
  }

  // ═══ 2. 삭제/수정 이동 ═══════════════════════
  // 작동: 삭제=목록에서 빼고 저장, 수정=작성 화면을 수정 모드로 열고 돌아오면 다시 로드.

  // 선택한 메모를 목록에서 빼고 저장(저장 시 다른 화면에도 전파)하려고 둠.
  Future<void> _deleteMemo(int index) async {
    setState(() => globalMemos.removeAt(index));
    await AppStateStore.saveMemos(globalMemos);
  }

  // 메모 작성 화면을 "수정 모드"로 열고, 돌아오면 목록을 다시 읽으려고 둠.
  Future<void> _editMemo(int index) async {
    final memo = globalMemos[index];
    await Navigator.push(
      context,
      MaterialPageRoute(
        // 기존 값을 채워 넘겨 수정 화면에서 바로 보이게 함(키는 한글 '제목'/'내용').
        builder: (context) => MemoWriteScreen(
          editIndex: index,
          initialTitle: memo['제목'] ?? '',
          initialContent: memo['내용'] ?? '',
        ),
      ),
    );
    await _loadMemos();
  }

  // ═══ 3. build ════════════════════════════════
  // 작동: 메모가 없으면 안내문, 있으면 목록(수정/삭제 버튼) + 우하단 추가 버튼을 그림.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 비었으면 안내문, 있으면 수정/삭제 버튼이 달린 목록 + 우하단에 새 메모 추가 버튼.
    return Scaffold(
      appBar: AppBar(title: const Text('메모')),
      body: globalMemos.isEmpty
          ? Center(
              child: Text(
                '아무런 메모도 적혀있지 않소.',
                style: TextStyle(color: theme.hintColor),
              ),
            )
          : ListView.separated(
              itemCount: globalMemos.length,
              separatorBuilder: (_, __) => Divider(color: theme.dividerColor),
              itemBuilder: (context, index) {
                final memo = globalMemos[index];
                return ListTile(
                  leading: Icon(Icons.note, color: theme.colorScheme.primary),
                  title: Text(
                    memo['제목'] ?? '',
                    style: TextStyle(color: theme.textTheme.bodyLarge?.color),
                  ),
                  subtitle: Text(
                    memo['내용'] ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: theme.hintColor),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: Icon(Icons.edit, color: theme.hintColor),
                        onPressed: () => _editMemo(index),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.delete_outline,
                          color: Colors.red,
                        ),
                        onPressed: () => _deleteMemo(index),
                      ),
                    ],
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          // 새 메모 작성 화면을 열고, 저장 후 돌아오면 목록을 다시 읽음.
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const MemoWriteScreen()),
          );
          await _loadMemos();
        },
        child: const Icon(Icons.note_add),
      ),
    );
  }
}
