import 'package:flutter/material.dart';
import 'package:gimal/main.dart';
import 'package:gimal/services/app_state_store.dart';

// 메모를 새로 쓰거나 기존 메모를 수정하는 화면. 저장하면 전역 목록 + 저장소를 함께 갱신함.

// ── 목차 (본문에서 같은 번호 헤더로 점프) ──────
//  1. 입력 초기화 : 수정이면 기존 값, 새 메모면 빈칸(hint만)
//  2. 저장        : 새 메모 추가 / 기존 메모 교체
//  3. build       : 제목·내용 입력 폼
// ────────────────────────────────────────────

class MemoWriteScreen extends StatefulWidget {
  // editIndex가 있으면 "수정", 없으면 "새 메모". 수정 시 기존 제목/내용을 받아 채우려고
  //   initialTitle/initialContent를 둠.
  const MemoWriteScreen({
    super.key,
    this.editIndex,
    // 새 메모는 빈칸으로 시작(안내문은 아래 hintText로 보여줌). 수정 모드면 기존 값을 받음.
    this.initialTitle = '',
    this.initialContent = '',
  });

  final int? editIndex;
  final String initialTitle;
  final String initialContent;

  // StatefulWidget이 자신의 상태(State) 객체를 만드는 필수 메서드.
  @override
  State<MemoWriteScreen> createState() => _MemoWriteScreenState();
}

class _MemoWriteScreenState extends State<MemoWriteScreen> {
  // 제목/내용 입력값을 읽으려고 둔 컨트롤러.
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _contentController = TextEditingController();

  // ═══ 1. 입력 초기화 ══════════════════════════
  // 작동: 들어올 때 받은 값을 입력칸에 채움(수정=기존 값, 새 메모=빈칸).
  @override
  void initState() {
    super.initState();
    // 들어올 때 받은 값을 입력칸에 채움(수정이면 기존 값, 새 메모면 빈칸 → hintText만 보임).
    _titleController.text = widget.initialTitle;
    _contentController.text = widget.initialContent;
  }

  // 화면이 사라질 때 입력 컨트롤러들을 해제(안 풀면 메모리 누수).
  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    super.dispose(); // 프레임워크 정리(필수)
  }

  // ═══ 2. 저장 ═════════════════════════════════
  // 작동: 제목이 비면 무시. 새 메모면 목록에 추가, 수정이면 해당 위치 교체 후 저장+닫기.
  // 저장 버튼 동작. 새 메모면 목록에 추가, 수정이면 그 위치를 교체하려고 둠.
  Future<void> _saveMemo() async {
    // 제목이 비면 저장할 의미가 없어 무시.
    if (_titleController.text.trim().isEmpty) return;

    // 키는 한글 '제목'/'내용'로 통일(목록/오버레이가 같은 키로 읽음).
    final memo = {
      '제목': _titleController.text.trim(),
      '내용': _contentController.text.trim(),
    };

    final editIndex = widget.editIndex;
    if (editIndex == null) {
      globalMemos.add(memo);
    } else {
      globalMemos[editIndex] = memo;
    }

    // 저장하면 이벤트로 목록 화면·오버레이에도 전파되고, 화면을 닫음.
    await AppStateStore.saveMemos(globalMemos);
    Navigator.pop(context);
  }

  // ═══ 3. build ════════════════════════════════
  // 작동: 앱바 제목은 모드에 따라 바뀌고 체크 버튼으로 저장. 본문은 제목칸 + 내용칸.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 앱바 제목은 모드에 따라 바뀌고, 체크 버튼으로 저장. 본문은 제목칸 + (남은 높이를 채우는) 내용칸.
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.editIndex == null ? '새 메모 작성' : '메모 수정하기'),
        actions: [
          IconButton(onPressed: _saveMemo, icon: const Icon(Icons.check)),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _titleController,
              decoration: const InputDecoration(hintText: '적고 싶은 제목을 적으시오'),
              style: TextStyle(color: theme.textTheme.bodyLarge?.color),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: TextField(
                controller: _contentController,
                decoration: const InputDecoration(
                  hintText: '이곳은 내용을 적는 곳이오',
                  border: InputBorder.none,
                ),
                // 내용은 길 수 있어 줄 제한 없이 남은 공간을 다 쓰게 함.
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: TextStyle(color: theme.textTheme.bodyLarge?.color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
