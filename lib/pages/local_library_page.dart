import 'package:flutter/material.dart';
import 'package:fqapp/pages/site_browse_page.dart';
import 'package:fqapp/services/m3u_export_db.dart';
import 'package:fqapp/services/midnight_gate.dart';
import 'package:fqapp/widgets/series_detail/moyi_detail_theme.dart';

/// 独立播库页：列出本地库里有视频的站点，点站名进该站的库内浏览
/// （分类、下钻、播放都复用浏览页与本地库客户端；播库页本身不做爬取）。
class LocalLibraryPage extends StatefulWidget {
  const LocalLibraryPage({super.key, this.dbSink});

  /// 测试注入；缺省走真实 Hive 库。
  final M3uExportDbSink? dbSink;

  @override
  State<LocalLibraryPage> createState() => _LocalLibraryPageState();
}

class _LocalLibraryPageState extends State<LocalLibraryPage> {
  bool _loading = true;
  List<M3uExportSiteInfo> _sites = const [];

  M3uExportDbSink get _db => widget.dbSink ?? HiveM3uExportDb.instance;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await MidnightGate.ensureLoaded();
    final sites = await _db.listSites(gateOpen: MidnightGate.activated.value);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _sites = sites;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('本地库'),
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: () {
              setState(() => _loading = true);
              _load();
            },
          ),
        ],
      ),
      body: MoyiPageBackground(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _sites.isEmpty
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    '本地库还是空的。\n'
                    '去站源管理浏览页点预爬取，或在一键写 PY 页点导出到本地库，'
                    '爬取的数据就会出现在这里。',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: moyiBodyOnDark),
                  ),
                ),
              )
            : ListView.builder(
                itemCount: _sites.length,
                itemBuilder: (context, index) {
                  final site = _sites[index];
                  return ListTile(
                    title: Text(
                      site.siteName,
                      style: const TextStyle(color: moyiBodyOnDark),
                    ),
                    subtitle: Text(
                      '${site.videoCount} 条',
                      style: const TextStyle(color: moyiMutedOnDark),
                    ),
                    trailing: const Icon(
                      Icons.chevron_right,
                      color: moyiMutedOnDark,
                    ),
                    onTap: () {
                      // 只传站号不传客户端：浏览页走注册表解析本地库站，
                      // 注册表那条路会给本地库客户端注入现取解析器，
                      // 库里没地址的记录播放时才能现取原站地址回写。
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => SiteBrowsePage(
                            siteId: 'localdb:${site.siteId}',
                            siteName: site.siteName,
                            dbSink: _db,
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
      ),
    );
  }
}
