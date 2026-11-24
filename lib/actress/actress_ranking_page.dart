import 'package:flutter/material.dart';

import 'actress_database.dart';
import 'actress_detail_page.dart';
import 'actress_models.dart';
import 'actress_widgets.dart';
import 'actress_adapter_repository.dart';
import 'actress_adapter_store.dart';

/// 女优作品排行榜：与片库顶栏原奖杯榜单并存的新榜，原榜数据不动。
///
/// 排序口径（名气 + 作品数量，榜内一致）：综合分 = 名气分 + 作品分，
/// 名气分取 MissAV 排行名次换算（第 1 名 1000 分，逐名减 1，1000 名
/// 开外 0 分）+ 潮流“推荐”加 50 分，作品分取显示作品数封顶 500；
/// 同分按实际作品数、再按名字排。数据直接读本地库，不联网。
class ActressRankingPage extends StatefulWidget {
  const ActressRankingPage({
    super.key,
    required this.repository,
    required this.store,
    required this.database,
  });

  final AppRepository repository;
  final LocalStore store;
  final ActressDatabase database;

  @override
  State<ActressRankingPage> createState() => _ActressRankingPageState();
}

class _ActressRankingPageState extends State<ActressRankingPage> {
  var _persons = <ActressPerson>[];
  var _loading = true;
  var _sex = ActressSexFilter.all;
  var _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() => _loading = true);
    final persons = await widget.database.allPersonsForRanking(sex: _sex);
    if (!mounted || generation != _generation) return;
    setState(() {
      _persons = persons;
      _loading = false;
    });
  }

  void _setSex(ActressSexFilter sex) {
    if (sex == _sex) return;
    setState(() => _sex = sex);
    _load();
  }

  void _openPerson(ActressPerson person) {
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ActressDetailPage(
          localId: person.localId,
          repository: widget.repository,
          store: widget.store,
          database: widget.database,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.emoji_events_outlined),
            SizedBox(width: 8),
            Text('演员排行榜'),
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('全部'),
                  selected: _sex == ActressSexFilter.all,
                  onSelected: (_) => _setSex(ActressSexFilter.all),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('女'),
                  selected: _sex == ActressSexFilter.female,
                  onSelected: (_) => _setSex(ActressSexFilter.female),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('男'),
                  selected: _sex == ActressSexFilter.male,
                  onSelected: (_) => _setSex(ActressSexFilter.male),
                ),
                const Spacer(),
                Text(
                  '按名气与作品数量综合排序',
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _persons.isEmpty
                ? Center(
                    child: Text(
                      '暂无排行数据',
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  )
                : ListView.builder(
                    key: const ValueKey('actress-ranking-list'),
                    itemCount: _persons.length,
                    itemBuilder: (context, index) {
                      final person = _persons[index];
                      final rank = index + 1;
                      return ListTile(
                        key: ValueKey('actress-rank-$rank'),
                        leading: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _RankBadge(rank: rank),
                            const SizedBox(width: 12),
                            ActressAvatar(
                              avatarUrl: person.avatarUrl,
                              name: person.displayName,
                            ),
                          ],
                        ),
                        title: Text(person.displayName),
                        subtitle: Text('作品 ${person.displayWorks} 部'),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => _openPerson(person),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// 名次徽标：前三名金/银/铜底色区分，其余只显示名次数字。
class _RankBadge extends StatelessWidget {
  const _RankBadge({required this.rank});

  final int rank;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final Color? background;
    final Color? foreground;
    switch (rank) {
      case 1:
        background = const Color(0xFFD4A017);
        foreground = Colors.white;
      case 2:
        background = const Color(0xFF9AA0A6);
        foreground = Colors.white;
      case 3:
        background = const Color(0xFFB07A4F);
        foreground = Colors.white;
      default:
        background = null;
        foreground = null;
    }
    return SizedBox(
      width: 28,
      child: Center(
        child: background == null
            ? Text(
                '$rank',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: colors.onSurfaceVariant,
                ),
              )
            : CircleAvatar(
                radius: 13,
                backgroundColor: background,
                child: Text(
                  '$rank',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: foreground,
                  ),
                ),
              ),
      ),
    );
  }
}
