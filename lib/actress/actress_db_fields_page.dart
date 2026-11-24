import 'package:flutter/material.dart';

import 'actress_generic_db.dart';

/// “数据库字段”查看页（2026-11-20 通用读库兜底入口）：列出当前库
/// 探到的表名与字段名（每列的自动识别角色），自动映射实在认不出
/// 的表，用户手动指定哪个字段是标题、哪个是播放地址；映射按库
/// 文件结构指纹存下来，下次换同结构的库直接用。
///
/// 入口在女优库列表页：外来数据库模式下，绑定行下方会出现
/// “数据库字段”按钮；女优库结构不显示（走严格路径，不用映射）。
class ActressDbFieldsPage extends StatefulWidget {
  const ActressDbFieldsPage({super.key, required this.reader});

  final GenericDbReader reader;

  @override
  State<ActressDbFieldsPage> createState() => _ActressDbFieldsPageState();
}

const _roleLabels = <GenericDbRole, String>{
  GenericDbRole.title: '标题',
  GenericDbRole.cover: '封面',
  GenericDbRole.playUrl: '播放地址',
  GenericDbRole.actress: '女优',
  GenericDbRole.code: '番号',
  GenericDbRole.category: '分类',
  GenericDbRole.date: '日期',
};

class _ActressDbFieldsPageState extends State<ActressDbFieldsPage> {
  String? _table;
  final _picked = <GenericDbRole, String?>{};
  var _saving = false;

  @override
  void initState() {
    super.initState();
    final schema = widget.reader.schema;
    _table =
        schema.worksTable?.table ??
        (schema.tables.isEmpty ? null : schema.tables.first.table);
    final works = schema.worksTable;
    if (works != null && works.table == _table) {
      for (final role in GenericDbRole.values) {
        _picked[role] = works.columnFor(role);
      }
    }
  }

  GenericDbSchema get _schema => widget.reader.schema;

  /// 所选表的全部字段名（含未识别的）：手动指定就是要选那些没被
  /// 认出来的列，只列已识别的就选不到。
  List<String> get _pickableColumns {
    if (_table == null) return const [];
    for (final mapping in _schema.tables) {
      if (mapping.table == _table) return mapping.allColumns;
    }
    return const [];
  }

  String _tableKindLabel(GenericDbTableMapping mapping) {
    if (mapping == _schema.worksTable) return '作品表';
    if (mapping == _schema.personsTable) return '人物表';
    return '未识别';
  }

  String _roleLabelForColumn(
    GenericDbTableMapping mapping,
    String column,
  ) {
    for (final entry in mapping.columns.entries) {
      if (entry.value == column) return _roleLabels[entry.key]!;
    }
    return '未识别';
  }

  bool get _canSave =>
      !_saving &&
      _table != null &&
      (_picked[GenericDbRole.title] ?? '').isNotEmpty &&
      (_picked[GenericDbRole.playUrl] ?? '').isNotEmpty;

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() => _saving = true);
    final columns = <GenericDbRole, String>{};
    for (final entry in _picked.entries) {
      final value = entry.value;
      if (value != null && value.isNotEmpty) columns[entry.key] = value;
    }
    await widget.reader.applyManualMapping(
      table: _table!,
      columns: columns,
    );
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final schema = _schema;
    return Scaffold(
      appBar: AppBar(title: const Text('数据库字段')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        children: [
          Text(
            '自动识别可能认错，以实际字段为准；标题与播放地址必填，'
            '保存后按这个结构指纹存下来，下次换同结构的库直接用。',
            style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
          ),
          const SizedBox(height: 8),
          Text(
            '结构指纹：${schema.fingerprint.length > 48 ? '${schema.fingerprint.substring(0, 48)}…' : schema.fingerprint}',
            style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
          ),
          const SizedBox(height: 12),
          for (final mapping in schema.tables) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            mapping.table,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        Chip(
                          label: Text(_tableKindLabel(mapping)),
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    if (mapping.allColumns.isEmpty)
                      const Text('这张表没有字段'),
                    for (final column in mapping.allColumns)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          children: [
                            Expanded(child: Text(column)),
                            Chip(
                              label: Text(
                                _roleLabelForColumn(mapping, column),
                              ),
                              visualDensity: VisualDensity.compact,
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
          if (schema.tables.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: Text('这库里没有表'),
              ),
            ),
          const SizedBox(height: 12),
          const Text(
            '手动指定作品表',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            key: const ValueKey('generic-db-table-picker'),
            decoration: const InputDecoration(
              labelText: '表',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            value: _table,
            items: [
              for (final mapping in schema.tables)
                DropdownMenuItem(
                  value: mapping.table,
                  child: Text(mapping.table),
                ),
            ],
            onChanged: (value) {
              if (value == null) return;
              setState(() {
                _table = value;
                _picked.clear();
                for (final mapping in schema.tables) {
                  if (mapping.table == value) {
                    for (final role in GenericDbRole.values) {
                      _picked[role] = mapping.columnFor(role);
                    }
                  }
                }
              });
            },
          ),
          const SizedBox(height: 8),
          for (final role in GenericDbRole.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: DropdownButtonFormField<String>(
                key: ValueKey('generic-db-role-${role.name}'),
                decoration: InputDecoration(
                  labelText:
                      _roleLabels[role]! +
                      (role == GenericDbRole.title ||
                              role == GenericDbRole.playUrl
                          ? '（必填）'
                          : ''),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                value: _picked[role],
                items: [
                  const DropdownMenuItem<String>(
                    value: null,
                    child: Text('不指定'),
                  ),
                  for (final column in _pickableColumns)
                    DropdownMenuItem(value: column, child: Text(column)),
                ],
                onChanged: (value) {
                  setState(() => _picked[role] = value);
                },
              ),
            ),
          const SizedBox(height: 4),
          FilledButton(
            onPressed: _canSave ? _save : null,
            child:
                _saving
                    ? const Text('保存中…')
                    : const Text('保存映射并重新加载'),
          ),
        ],
      ),
    );
  }
}
