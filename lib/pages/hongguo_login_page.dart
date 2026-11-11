import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/hongguo_account.dart';
import '../services/hongguo_account_sync.dart';
import '../widgets/series_detail/moyi_detail_theme.dart';

/// 红果账号页：手机号登录（主路）+ 扫码登录（备用）+ 账号主页
/// （云端收藏 / 云端继续观看 / 预约 / 退出）。
///
/// 扫码定法：本机展示二维码，供另一台设备上的红果 App 扫码确认。
/// 用户只有一台手机时，本机扫不了自己的屏幕——页面会明说这点，
/// 并引导走手机号登录，不在本机放假的“扫一扫”入口。
class HongguoLoginPage extends StatefulWidget {
  const HongguoLoginPage({super.key});

  @override
  State<HongguoLoginPage> createState() => _HongguoLoginPageState();
}

class _HongguoLoginPageState extends State<HongguoLoginPage> {
  final _service = HongguoAccountService.instance;
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();
  String _countryCode = '86';
  bool _showOnlineReservations = true;

  static const _countryCodes = [
    ('86', '中国大陆'),
    ('852', '中国香港'),
    ('853', '中国澳门'),
    ('886', '中国台湾'),
    ('65', '新加坡'),
    ('60', '马来西亚'),
    ('81', '日本'),
    ('82', '韩国'),
    ('1', '美国 / 加拿大'),
    ('44', '英国'),
    ('61', '澳大利亚'),
  ];

  @override
  void initState() {
    super.initState();
    _service.init();
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _sendCode() async {
    try {
      final sent = await _service.sendCode(
        countryCode: _countryCode,
        number: _phoneController.text,
      );
      _snack('验证码已发送至 ${sent.maskedMobile}，请打开本机短信查看');
    } on HongguoAccountError catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _verifyCode() async {
    try {
      await _service.verifyCode(_codeController.text);
    } on HongguoAccountError catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _fetchQr() async {
    try {
      await _service.fetchQr();
    } on HongguoAccountError catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _refresh() async {
    await _service.refresh();
    _snack(_service.statusMessage);
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('退出红果账号'),
        content: const Text(
          '退出后停止自动同步，账号收藏、云端历史与预约不再显示。\n'
          '本机历史与书架不受影响，下次登录同一账号会重新拉取。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _service.logout();
      if (mounted) setState(() {});
    }
  }

  String _formatMs(int ms) {
    final total = ms ~/ 1000;
    final minutes = total ~/ 60;
    final seconds = total % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  String _formatDate(int ms) {
    if (ms <= 0) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${date.year}-${date.month}-${date.day}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('红果账号'),
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        foregroundColor: Colors.white,
      ),
      body: MoyiPageBackground(
        child: ListenableBuilder(
          listenable: _service,
          builder: (context, _) {
            if (_service.signedIn) return _accountHome();
            return _loginForms();
          },
        ),
      ),
    );
  }

  Widget _sectionTitle(String title) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 8),
    child: Text(
      title,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 16,
        fontWeight: FontWeight.bold,
      ),
    ),
  );

  Widget _noteCard(String text, {Color? color}) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: (color ?? Colors.amber).withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      text,
      style: const TextStyle(color: Colors.white70, fontSize: 13),
    ),
  );

  Widget _loginForms() {
    final cooldown = _service.codeCooldownSeconds;
    final busy = _service.busy;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        if (!_service.signingWired)
          _noteCard(
            '联调待验：账号请求签名尚未接线，登录请求可能被平台拒绝；'
            '短信验证码与扫码流程须在用户手机上实测验证，'
            '这里不谎称已通。',
          ),
        _sectionTitle('手机号登录（主路）'),
        const Text(
          '步骤：① 输入手机号，点「获取验证码」 ② 打开本机短信，'
          '查看验证码 ③ 输入验证码，点「登录」。验证码发到这台手机上，'
          '不用换设备。',
          style: TextStyle(color: Colors.white70, fontSize: 13),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            DropdownButton<String>(
              value: _countryCode,
              dropdownColor: moyiSheetFill,
              style: const TextStyle(color: Colors.white),
              items: [
                for (final (code, name) in _countryCodes)
                  DropdownMenuItem(value: code, child: Text('+$code $name')),
              ],
              onChanged: busy
                  ? null
                  : (value) {
                      if (value != null) setState(() => _countryCode = value);
                    },
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: '手机号',
                  hintText: '大陆 11 位，境外不填前导 0',
                  labelStyle: TextStyle(color: moyiMutedOnDark),
                  hintStyle: TextStyle(color: moyiMutedOnDark),
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _codeController,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: '短信验证码',
                  hintText: '4—8 位数字',
                  labelStyle: TextStyle(color: moyiMutedOnDark),
                  hintStyle: TextStyle(color: moyiMutedOnDark),
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: busy || cooldown > 0 ? null : _sendCode,
              child: Text(cooldown > 0 ? '$cooldown 秒后重发' : '获取验证码'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: busy ? null : _verifyCode,
          child: Text(
            _service.loginState == HongguoLoginState.verifying
                ? '正在登录…'
                : '登录',
          ),
        ),
        if (_service.statusMessage.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _service.statusMessage,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
        _sectionTitle('扫码登录（备用）'),
        const Text(
          '本页展示登录二维码，用另一台手机 / 平板上的红果 App：'
          '我的 → 右上角菜单 → 扫一扫，扫这里的二维码后在那台手机上'
          '点确认登录。\n只有一台手机时扫码用不了——本机扫不了自己的屏幕，'
          '请用上面的手机号登录。',
          style: TextStyle(color: Colors.white70, fontSize: 13),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            FilledButton.icon(
              onPressed: busy ? null : _fetchQr,
              icon: const Icon(Icons.qr_code, size: 18),
              label: Text(_service.qr == null ? '获取二维码' : '刷新二维码'),
            ),
            if (_service.qr != null) ...[
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () {
                  _service.cancelQr();
                },
                child: const Text('取消'),
              ),
            ],
          ],
        ),
        if (_service.qr != null) ...[
          const SizedBox(height: 12),
          Center(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Image.memory(
                Uint8List.fromList(_service.qr!.imageBytes),
                width: 220,
                height: 220,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              _service.loginState == HongguoLoginState.waitingScan
                  ? '等待手机确认… 二维码有效期约 ${_service.qr!.expiresInSeconds} 秒'
                  : _service.statusMessage,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
        ],
        const SizedBox(height: 16),
        _noteCard(
          '本机记录与账号记录分开存：登录后收藏、历史与预约进账号，'
          '换设备能回来；本机历史与书架不动，退出登录也不清。',
          color: Colors.blue,
        ),
      ],
    );
  }

  Widget _accountHome() {
    final profile = _service.profile;
    final history = _service.cloudHistory;
    final favorites = _service.accountFavorites;
    final reservations = _service.reservations(online: _showOnlineReservations);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Card(
          color: moyiSheetFill,
          child: ListTile(
            leading: const Icon(LucideIcons.user, color: Colors.white),
            title: Text(
              profile?.nickname ?? '红果用户',
              style: const TextStyle(color: Colors.white),
            ),
            subtitle: Text(
              _service.statusMessage,
              style: const TextStyle(color: Colors.white70),
            ),
            trailing: TextButton(
              onPressed: _service.busy ? null : _logout,
              child: const Text('退出登录'),
            ),
          ),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _service.busy ? null : _refresh,
          icon: const Icon(LucideIcons.refresh_cw, size: 18),
          label: const Text('刷新云端记录'),
        ),
        _sectionTitle('云端继续观看（${history.length}）'),
        if (history.isEmpty)
          const Text(
            '暂无云端观看记录，播放后进度会自动上传。',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
        for (final item in history)
          Card(
            color: moyiSheetFill,
            child: ListTile(
              title: Text(
                item.title.isEmpty ? '剧集 ${item.seriesId}' : item.title,
                style: const TextStyle(color: Colors.white),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '第 ${item.episodeIndex + 1} 集 · 已看到 ${_formatMs(item.positionMs)}'
                '${item.durationMs > 0 ? ' / 共 ${_formatMs(item.durationMs)}' : ''}',
                style: const TextStyle(color: Colors.white70),
              ),
              trailing: TextButton(
                onPressed: () => _showResumeDialog(item),
                child: const Text('续播点'),
              ),
            ),
          ),
        _sectionTitle('账户收藏（${favorites.length}）'),
        if (favorites.isEmpty)
          const Text(
            '账号下暂无收藏。登录后收藏进账号，换设备能回来。',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
        for (final item in favorites)
          Card(
            color: moyiSheetFill,
            child: ListTile(
              title: Text(
                item.title,
                style: const TextStyle(color: Colors.white),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                item.badge.isEmpty ? '账户收藏' : item.badge,
                style: const TextStyle(color: Colors.white70),
              ),
              trailing: IconButton(
                tooltip: '取消账户收藏',
                icon: const Icon(Icons.delete_outline, size: 18),
                color: Colors.white70,
                onPressed: () async {
                  final message = await _service.toggleAccountFavorite(
                    seriesId: item.seriesId,
                    title: item.title,
                  );
                  _snack(message);
                },
              ),
            ),
          ),
        _sectionTitle('预约'),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: true, label: Text('已上线')),
            ButtonSegment(value: false, label: Text('待上线')),
          ],
          selected: {_showOnlineReservations},
          onSelectionChanged: (values) {
            setState(() => _showOnlineReservations = values.first);
          },
        ),
        const SizedBox(height: 8),
        if (reservations.isEmpty)
          Text(
            _showOnlineReservations ? '暂无已上线预约。' : '暂无待上线预约。',
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        for (final item in reservations)
          Card(
            color: moyiSheetFill,
            child: ListTile(
              title: Text(
                item.title,
                style: const TextStyle(color: Colors.white),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                [
                  if (item.publishAtMs > 0) '预计 ${_formatDate(item.publishAtMs)}',
                  if (item.publishText.isNotEmpty) item.publishText,
                  if (item.playable) '已上线，可播',
                ].join(' · '),
                style: const TextStyle(color: Colors.white70),
              ),
            ),
          ),
        const SizedBox(height: 16),
        _noteCard(
          '退出登录只清账号数据，本机历史与书架不动。',
          color: Colors.blue,
        ),
      ],
    );
  }

  void _showResumeDialog(HongguoCloudProgress item) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(item.title.isEmpty ? '剧集 ${item.seriesId}' : item.title),
        content: Text(
          '云端续播点：第 ${item.episodeIndex + 1} 集，'
          '${_formatMs(item.positionMs)}'
          '${item.durationMs > 0 ? ' / 共 ${_formatMs(item.durationMs)}' : ''}。\n'
          '播放器接 resumeForSeries 后会从这里继续播。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}

/// 我的页顶部的红果账号入口：显示登录态，点进登录页。
class HongguoAccountTile extends StatelessWidget {
  const HongguoAccountTile({super.key});

  @override
  Widget build(BuildContext context) {
    final service = HongguoAccountService.instance;
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final signedIn = service.signedIn;
        return Card(
          color: moyiSheetFill,
          child: ListTile(
            leading: const Icon(LucideIcons.user, color: Colors.white),
            title: const Text('红果账号', style: TextStyle(color: Colors.white)),
            subtitle: Text(
              signedIn
                  ? '已登录 · ${service.profile?.nickname ?? '红果用户'} · 云端同步已开启'
                  : '未登录 · 手机号登录（主）/ 扫码登录（备）',
              style: const TextStyle(color: Colors.white70),
            ),
            trailing: const Icon(
              LucideIcons.chevron_right,
              color: Colors.white70,
            ),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => const HongguoLoginPage(),
              ),
            ),
          ),
        );
      },
    );
  }
}
