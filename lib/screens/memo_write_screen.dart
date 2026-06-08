import 'package:flutter/material.dart';
import 'package:gimal/main.dart';
import 'package:gimal/services/app_state_store.dart';

// 메인 앱에서 메모를 새로 작성하거나 기존 메모를 수정하는 화면이다.
// 저장 버튼을 누르면 전역 메모 목록과 저장소를 함께 갱신한다.

class MemoWriteScreen extends StatefulWidget {
  const MemoWriteScreen({
    super.key,
    this.editIndex,
    this.initialTitle = '',
    this.initialContent = '',
  });

  final int? editIndex;
  final String initialTitle;
  final String initialContent;

  @override
  State<MemoWriteScreen> createState() => _MemoWriteScreenState();
}

class _MemoWriteScreenState extends State<MemoWriteScreen> {
  // 제목과 내용을 입력받기 위한 컨트롤러이다.
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _contentController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // 수정 모드로 들어온 경우 기존 제목과 내용을 입력창에 넣어준다.
    _titleController.text = widget.initialTitle;
    _contentController.text = widget.initialContent;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  // 새 메모면 목록에 추가하고, 수정 모드면 해당 위치의 메모를 교체한다.
  Future<void> _saveMemo() async {
    if (_titleController.text.trim().isEmpty) return;

    final memo = {
      'title': _titleController.text.trim(),
      'content': _contentController.text.trim(),
    };

    final editIndex = widget.editIndex;
    if (editIndex == null) {
      globalMemos.add(memo);
    } else {
      globalMemos[editIndex] = memo;
    }

    await AppStateStore.saveMemos(globalMemos);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 위쪽 체크 버튼으로 저장하고, 본문에는 제목과 내용을 입력한다.
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
              decoration: const InputDecoration(hintText: '제목'),
              style: TextStyle(color: theme.textTheme.bodyLarge?.color),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: TextField(
                controller: _contentController,
                decoration: const InputDecoration(
                  hintText: 'Content',
                  border: InputBorder.none,
                ),
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
