import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../pages/tgdrama_login_page.dart';
import '../../services/tgdrama_account.dart';
import '../../services/tgdrama_service.dart';
import '../home/home_design.dart';
import '../home/home_shelf.dart';
import 'mine_entries.dart';

/// 我的页修仙人物卡下面一行：Telegram 登录入口 + 登录状态。
///
/// 未登录显示“未登录”，点了进登录页；登录后显示存下的脱敏手机号
/// （手机号登录成功时存的），扫码登录 / 预置会话没有手机号可存时只显示
/// “已登录”。点开进登录页看状态。插件接口不回用户名、库里也没有账号表，
/// 所以这里不编名字，只显示真实存下的东西。
///
/// 状态要起本地服务才能查准（预置会话的用户服务没起时查不到已登录），
/// 所以刷新时先 ensureRunning 再 authStatus；服务起不来时，有存下的
/// 标签说明之前登过，按已登录显示，真实状态点进登录页看。
class TgdramaAccountRow extends StatefulWidget {
  const TgdramaAccountRow({super.key, this.service, this.accountStore});

  /// 供测试注入的假服务；不传时用单例。
  final TgdramaService? service;

  /// 供测试注入的假存取；不传时用默认的 SharedPreferences 存取。
  final TgdramaAccountStore? accountStore;

  @override
  State<TgdramaAccountRow> createState() => _TgdramaAccountRowState();
}

class _TgdramaAccountRowState extends State<TgdramaAccountRow> {
  TgdramaService get _service => widget.service ?? TgdramaService.instance;
  TgdramaAccountStore get _store =>
      widget.accountStore ?? TgdramaAccountStore();

  String? _label;
  bool _authorized = false;
  bool _checking = true;
  bool _visible = false;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    final wasVisible = _visible;
    _visible = visible;
    if (visible && !wasVisible) _refresh();
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final label = await _store.readLabel();
      var authorized = false;
      try {
        if (await _service.ensureRunning()) {
          authorized = (await _service.authStatus()).authorized;
        } else {
          authorized = label != null;
        }
      } catch (_) {
        authorized = label != null;
      }
      if (!mounted) return;
      setState(() {
        _label = label;
        _authorized = authorized;
        _checking = false;
      });
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _openLogin() async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => const TgdramaLoginPage()),
    );
    if (!mounted) return;
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final status = _checking
        ? '检查中…'
        : _authorized
            ? (_label ?? '已登录')
            : '未登录';
    return Padding(
      padding: const EdgeInsets.only(top: homeSectionGap),
      child: Column(
        children: [
          Divider(height: 1, thickness: 0.6, color: palette.line),
          MineEntryRow(
            icon: LucideIcons.send,
            label: 'Telegram',
            trailing: status,
            onTap: _openLogin,
          ),
        ],
      ),
    );
  }
}
