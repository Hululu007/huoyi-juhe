import 'package:flutter/material.dart';

import '../services/drama_site_content.dart';
import '../services/tgdrama_content.dart';
import '../widgets/home/drama_site_grid.dart';

/// TG影视库频道页：点频道后看该频道收录的剧。
///
/// 列表走 `TgdramaContentClient.catalog`（分类 id 为 `channel:` 加频道号）
/// （读插件本地库 tgdrama.db），点剧走 DramaSiteGrid 默认的
/// openDramaSiteItem → 剧详情 → 选集播放；点剧不直接播第 1 集。
/// 库不存在/打不开时网格页如实报错，不回空假装频道没剧。
class TgdramaChannelPage extends StatelessWidget {
  const TgdramaChannelPage({
    super.key,
    required this.siteId,
    required this.channelId,
    required this.title,
    this.client,
  });

  /// 站点 id（tgdrama）。
  final String siteId;

  /// 频道 tg_chat_id（不带 channel: 前缀）。
  final String channelId;

  /// 频道名（AppBar 标题）。
  final String title;

  /// 测试注入的客户端；为空时网格按登记表取客户端。
  final DramaSiteContentClient? client;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      // DramaSiteGrid 出的是 sliver（SliverGrid/SliverToBoxAdapter），
      // 只能放在 CustomScrollView 里，不能直接当 body。
      body: CustomScrollView(
        slivers: [
          DramaSiteGrid(
            siteId: siteId,
            categoryId: '${TgdramaContentClient.channelItemPrefix}$channelId',
            gridWidth: MediaQuery.sizeOf(context).width,
            client: client,
            showFilterBar: false,
            columns: 4,
          ),
        ],
      ),
    );
  }
}
