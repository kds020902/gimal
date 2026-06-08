import 'dart:async';

import 'package:flutter/material.dart';
import 'package:gimal/main.dart';
import 'package:gimal/screens/memo_write_screen.dart';
import 'package:gimal/services/app_state_store.dart';

// 메인 앱에서 메모 목록을 보여주는 화면이다.
// 메모 추가, 수정, 삭제를 처리하고 오버레이에서 바뀐 메모도 즉시 다시 불러온다.

class MemoScreen extends StatefulWidget {
  const MemoScreen({super.key});

  @override
  State<MemoScreen> createState() => _MemoScreenState();
}

class _MemoScreenState extends State<MemoScreen> with WidgetsBindingObserver {
  StreamSubscription<dynamic>? _stateSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // 오버레이에서 메모가 바뀌면 메인 앱의 메모 목록도 새로 불러온다.
    _stateSubscription = AppStateStore.stateEvents.listen((event) {
      if (event == AppStateStore.stateUpdatedEvent) {
        _loadMemos();
      }
    });
    _loadMemos();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stateSubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 앱이 다시 보일 때 저장소 값을 다시 읽어서 화면을 맞춘다.
    if (state == AppLifecycleState.resumed) {
      _loadMemos();
    }
  }

  // 저장소에서 메모 목록을 읽어 전역 메모 목록에 넣는다.
  Future<void> _loadMemos() async {
    final memos = await AppStateStore.loadMemos();
    if (!mounted) return;
    setState(() => globalMemos = memos);
  }

  // 선택한 메모를 목록에서 제거하고 저장소에 반영한다.
  Future<void> _deleteMemo(int index) async {
    setState(() => globalMemos.removeAt(index));
    await AppStateStore.saveMemos(globalMemos);
  }

  // 메모 작성 화면을 수정 모드로 열고, 돌아오면 목록을 다시 불러온다.
  Future<void> _editMemo(int index) async {
    final memo = globalMemos[index];
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => MemoWriteScreen(
          editIndex: index,
          initialTitle: memo['title'] ?? '',
          initialContent: memo['content'] ?? '',
        ),
      ),
    );
    await _loadMemos();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 메모가 없으면 안내 문구를, 있으면 수정/삭제 버튼이 있는 목록을 보여준다.
    return Scaffold(
      appBar: AppBar(title: const Text('Memos')),
      body: globalMemos.isEmpty
          ? Center(
              child: Text(
                'No memos yet.',
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
                    memo['title'] ?? '',
                    style: TextStyle(color: theme.textTheme.bodyLarge?.color),
                  ),
                  subtitle: Text(
                    memo['content'] ?? '',
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
                        icon: const Icon(Icons.delete_outline, color: Colors.red),
                        onPressed: () => _deleteMemo(index),
                      ),
                    ],
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          // 새 메모 작성 화면을 열고, 저장 후 돌아오면 목록을 다시 읽는다.
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
