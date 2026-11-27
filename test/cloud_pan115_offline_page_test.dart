// 115 离线任务页组件测试：状态推导三态、配额行（有/无）、
// 进页自动加载一次、点任务分流（搜到文件走打开假件 / 搜不到
// 给提示 / 未完成只提示状态）。全部注入假件，不碰真网真账号。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/cloud_drive/cloud_115_offline.dart';
import 'package:fqapp/cloud_drive/cloud_drive_types.dart';
import 'package:fqapp/cloud_drive/cloud_pan115_offline_page.dart';

Pan115OfflineTask _task(String name, double percent, bool done) =>
    Pan115OfflineTask(infoHash: '', name: name, percent: percent, done: done);

void main() {
  test('状态推导：done → 已完成，percent 中间值 → 下载中 x%，0 → 等待中', () {
    expect(
      pan115OfflineTaskStatusLabel(_task('a', 1, true)),
      '已完成',
    );
    expect(
      pan115OfflineTaskStatusLabel(_task('b', 0.5, false)),
      '下载中 50%',
    );
    expect(
      pan115OfflineTaskStatusLabel(_task('c', 0, false)),
      '等待中',
    );
    // done 以状态字段为准：进度没满也算已完成，不编造。
    expect(
      pan115OfflineTaskStatusLabel(_task('d', 0.3, true)),
      '已完成',
    );
  });

  testWidgets('进页自动加载一次：三态任务行 + 配额行渲染', (tester) async {
    var taskCalls = 0;
    var quotaCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CloudPan115OfflinePage(
          loadTasks: () async {
            taskCalls++;
            return [
              _task('已下完.mkv', 1, true),
              _task('下着.mkv', 0.5, false),
              _task('排队.mkv', 0, false),
            ];
          },
          loadQuota: () async {
            quotaCalls++;
            return (total: 100, used: 37);
          },
          searchFiles: (_) async => const [],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(taskCalls, 1);
    expect(quotaCalls, 1);
    expect(find.text('离线配额：已用 37 / 共 100'), findsOneWidget);
    expect(find.text('已下完.mkv'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
    expect(find.text('下载中 50%'), findsOneWidget);
    expect(find.text('等待中'), findsOneWidget);
    expect(find.byKey(const ValueKey('pan115-offline-task-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('pan115-offline-task-2')), findsOneWidget);
  });

  testWidgets('配额回 null：配额行整行不显，任务照常出', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CloudPan115OfflinePage(
          loadTasks: () async => [_task('排队.mkv', 0, false)],
          loadQuota: () async => null,
          searchFiles: (_) async => const [],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('离线配额'), findsNothing);
    expect(find.text('排队.mkv'), findsOneWidget);
  });

  testWidgets('空任务列表出空态文案', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CloudPan115OfflinePage(
          loadTasks: () async => const [],
          loadQuota: () async => null,
          searchFiles: (_) async => const [],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('暂无离线任务'), findsOneWidget);
  });

  testWidgets('点已完成任务：搜到文件走打开假件（跳过文件夹结果）', (tester) async {
    CloudDriveFile? opened;
    String? searched;
    await tester.pumpWidget(
      MaterialApp(
        home: CloudPan115OfflinePage(
          loadTasks: () async => [_task('已下完.mkv', 1, true)],
          loadQuota: () async => null,
          searchFiles: (keyword) async {
            searched = keyword;
            return const [
              CloudDriveFile(
                id: 'dir1',
                name: '已下完',
                isFolder: true,
                kind: CloudFileKind.folder,
              ),
              CloudDriveFile(
                id: 'f1',
                name: '已下完.mkv',
                isFolder: false,
                kind: CloudFileKind.video,
              ),
            ];
          },
          openFile: (context, file) async {
            opened = file;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('已下完.mkv'));
    await tester.pumpAndSettle();
    expect(searched, '已下完.mkv');
    expect(opened?.id, 'f1');
  });

  testWidgets('点已完成任务：搜不到文件给提示去离线下载文件夹找', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CloudPan115OfflinePage(
          loadTasks: () async => [_task('已下完.mkv', 1, true)],
          loadQuota: () async => null,
          searchFiles: (_) async => const [],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('已下完.mkv'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.text('没在网盘里搜到这个文件，去网盘目录的离线下载文件夹里找找'),
      findsOneWidget,
    );
  });

  testWidgets('点未完成任务：只提示状态、不搜文件', (tester) async {
    var searchCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CloudPan115OfflinePage(
          loadTasks: () async => [_task('排队.mkv', 0, false)],
          loadQuota: () async => null,
          searchFiles: (_) async {
            searchCalls++;
            return const [];
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('排队.mkv'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('这个任务还没下载完（等待中）'), findsOneWidget);
    expect(searchCalls, 0);
  });
}
