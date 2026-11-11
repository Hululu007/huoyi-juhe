import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/hongguo_account.dart';
import 'package:fqapp/services/hongguo_account_sync.dart';
import 'package:fqapp/services/secure_key_provider.dart';

/// 内存假传输：不发任何网络请求，只按接口约定走状态。
class _FakeTransport implements HongguoAccountTransport {
  String? sentMobile;
  int pollCount = 0;
  int uploadCount = 0;
  final favorites = <HongguoCloudFavorite>[];
  final upcoming = <HongguoCloudReservation>[];
  final onlineReservations = <HongguoCloudReservation>[];

  HongguoAccountSession _session() => HongguoAccountSession(
    cookie: 'sessionid=fake',
    deviceId: 'd1',
    installId: 'i1',
    userId: '',
    nickname: '',
    savedAtMs: 1000,
  );

  @override
  Future<HongguoCodeSent> sendPhoneCode(String mobile) async {
    sentMobile = mobile;
    return const HongguoCodeSent(maskedMobile: '+86******23', retrySeconds: 5);
  }

  @override
  Future<HongguoAccountSession> verifyPhoneCode(String code) async {
    if (code == '000000') {
      throw HongguoAccountError('错误次数过多或验证码过期，请重新获取验证码', code: 1203);
    }
    if (code != '123456') {
      throw HongguoAccountError(
        '验证码错误（错误码 1102）',
        code: 1102,
        canRetryCode: true,
      );
    }
    return _session();
  }

  @override
  Future<HongguoQrCode> fetchQrCode() async =>
      const HongguoQrCode(imageBytes: [1, 2, 3], expiresInSeconds: 180);

  @override
  Future<HongguoQrPoll> pollQrCode() async {
    pollCount++;
    return pollCount >= 1
        ? HongguoQrPoll.confirmed
        : HongguoQrPoll.waiting;
  }

  @override
  Future<HongguoAccountSession> finishQrLogin() async => _session();

  @override
  Future<HongguoAccountProfile> fetchProfile(
    HongguoAccountSession session,
  ) async =>
      const HongguoAccountProfile(userId: 'u1', nickname: '测试用户');

  @override
  Future<List<HongguoCloudFavorite>> fetchFavorites(
    HongguoAccountSession session,
  ) async => List.of(favorites);

  @override
  Future<void> setFavorite(
    HongguoAccountSession session,
    String seriesId,
    bool add,
  ) async {
    if (add) {
      favorites.add(
        HongguoCloudFavorite(seriesId: seriesId, title: '剧 $seriesId'),
      );
    } else {
      favorites.removeWhere((e) => e.seriesId == seriesId);
    }
  }

  @override
  Future<List<HongguoCloudProgress>> fetchHistory(
    HongguoAccountSession session,
  ) async => const [];

  @override
  Future<void> uploadProgress(
    HongguoAccountSession session,
    HongguoCloudProgress progress,
  ) async {
    uploadCount++;
  }

  @override
  Future<List<HongguoCloudReservation>> fetchReservations(
    HongguoAccountSession session,
    bool online,
  ) async => List.of(online ? onlineReservations : upcoming);

  @override
  Future<void> reserve(
    HongguoAccountSession session,
    String seriesId, {
    required bool upcoming,
  }) async {
    this.upcoming.add(
      HongguoCloudReservation(
        seriesId: seriesId,
        title: '待上线 $seriesId',
        online: false,
      ),
    );
  }
}

HongguoAccountService _service(_FakeTransport transport) =>
    HongguoAccountService(
      transportFactory: () => transport,
      cloudStore: HongguoAccountCloudStore.memory(),
      sessionStorage: InMemorySecureKeyStorage(),
    );

HongguoCloudProgress _progress({
  String seriesId = '1001',
  String episodeId = '2001',
  int episodeIndex = 0,
  int positionMs = 1000,
  int durationMs = 60000,
  int updatedAtMs = 1000,
}) => HongguoCloudProgress(
  seriesId: seriesId,
  episodeId: episodeId,
  episodeIndex: episodeIndex,
  positionMs: positionMs,
  durationMs: durationMs,
  updatedAtMs: updatedAtMs,
);

void main() {
  test('手机号归一化：大陆 11 位、空格横线、前导 0、境外 +区号', () {
    expect(HongguoPhoneNumber.format('86', '13800138000'), '13800138000');
    expect(HongguoPhoneNumber.format('86', '138-0013-8000'), '13800138000');
    expect(HongguoPhoneNumber.parse('+886 0912345678'), '+886 912345678');
    expect(HongguoPhoneNumber.parse('13800138000'), '13800138000');
    expect(
      () => HongguoPhoneNumber.format('86', '23800138000'),
      throwsA(isA<HongguoAccountError>()),
    );
    expect(
      () => HongguoPhoneNumber.format('86', '1380013800'),
      throwsA(isA<HongguoAccountError>()),
    );
  });

  test('打码不回显完整号码，会话 toString 不含 cookie', () {
    expect(HongguoPhoneNumber.mask('13800138000'), '13******00');
    const session = HongguoAccountSession(
      cookie: 'sessionid=secret-value',
      deviceId: 'd',
      installId: 'i',
      userId: 'u1',
      nickname: 'n',
      savedAtMs: 0,
    );
    expect(session.toString(), isNot(contains('secret-value')));
    expect(session.toString(), contains('u1'));
  });

  test('续播合并：更新时间新者赢，时间相同取本机', () {
    final local = _progress(updatedAtMs: 2000, positionMs: 5000);
    final cloud = _progress(updatedAtMs: 1000, positionMs: 9000);
    expect(mergeCloudProgress(local: local, cloud: cloud), same(local));
    expect(
      mergeCloudProgress(local: cloud, cloud: local),
      same(local),
    );
    expect(
      mergeCloudProgress(
        local: _progress(updatedAtMs: 1000),
        cloud: _progress(updatedAtMs: 1000, positionMs: 9000),
      )?.positionMs,
      1000,
    );
    expect(mergeCloudProgress(local: null, cloud: cloud), same(cloud));
    expect(mergeCloudProgress(local: local, cloud: null), same(local));
    expect(mergeCloudProgress(local: null, cloud: null), isNull);
  });

  test('手机号登录状态机：发码 → 验码 → 已登录，错码可重试', () async {
    final transport = _FakeTransport();
    final service = _service(transport);
    addTearDown(service.dispose);
    await service.init();

    final sent = await service.sendCode(number: '13800138000');
    expect(transport.sentMobile, '13800138000');
    expect(sent.maskedMobile, '+86******23');
    expect(service.loginState, HongguoLoginState.codeSent);
    expect(service.codeCooldownSeconds, greaterThan(0));

    await expectLater(
      () => service.verifyCode('111111'),
      throwsA(isA<HongguoAccountError>()),
    );
    // 可重试的错码：仍停在 codeSent，不丢本次尝试。
    expect(service.loginState, HongguoLoginState.codeSent);

    await service.verifyCode('123456');
    expect(service.signedIn, isTrue);
    expect(service.loginState, HongguoLoginState.signedIn);
    expect(service.profile?.userId, 'u1');
    expect(service.profile?.nickname, '测试用户');
  });

  test('验证码作废（1203）后须重新发码', () async {
    final service = _service(_FakeTransport());
    addTearDown(service.dispose);
    await service.init();
    await service.sendCode(number: '13800138000');
    await expectLater(
      () => service.verifyCode('000000'),
      throwsA(isA<HongguoAccountError>()),
    );
    expect(service.loginState, HongguoLoginState.signedOut);
    expect(service.signedIn, isFalse);
  });

  test('扫码登录：取码 → 轮询确认 → 已登录', () async {
    final service = _service(_FakeTransport());
    addTearDown(service.dispose);
    await service.init();
    await service.fetchQr();
    expect(service.loginState, HongguoLoginState.waitingScan);
    expect(service.qr, isNotNull);
    // 轮询定时器 2 秒一跳，等确认后状态翻成已登录。
    final deadline = DateTime.now().add(const Duration(seconds: 6));
    while (!service.signedIn && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    expect(service.signedIn, isTrue);
  });

  test('收藏进账号：写后重读核对，加 / 取消都报确认结果', () async {
    final service = _service(_FakeTransport());
    addTearDown(service.dispose);
    await service.init();
    await service.sendCode(number: '13800138000');
    await service.verifyCode('123456');

    final added = await service.toggleAccountFavorite(
      seriesId: '1001',
      title: '剧 1001',
    );
    expect(added, contains('已加入账户收藏'));
    expect(service.isAccountFavorite('1001'), isTrue);

    final removed = await service.toggleAccountFavorite(
      seriesId: '1001',
      title: '剧 1001',
    );
    expect(removed, contains('已取消账户收藏'));
    expect(service.isAccountFavorite('1001'), isFalse);
  });

  test('预约进账号：待上线可约，约后列表里有', () async {
    final service = _service(_FakeTransport());
    addTearDown(service.dispose);
    await service.init();
    await service.sendCode(number: '13800138000');
    await service.verifyCode('123456');

    final message = await service.reserveSeries('3001', upcoming: true);
    expect(message, contains('已加入账号预约'));
    expect(service.isReserved('3001'), isTrue);
    expect(
      await service.reserveSeries('3001', upcoming: true),
      contains('已在当前账号的预约列表中'),
    );
  });

  test('播放器续播接口：按剧 / 按集查，未登录与集 id 不符返回 null', () async {
    final service = _service(_FakeTransport());
    addTearDown(service.dispose);
    await service.init();
    expect(await service.resumeForSeries('1001'), isNull);

    await service.sendCode(number: '13800138000');
    await service.verifyCode('123456');
    await service.reportProgress(
      seriesId: '1001',
      episodeId: '2001',
      episodeIndex: 2,
      positionMs: 45000,
      durationMs: 60000,
      episodeCount: 12,
      title: '剧 1001',
    );
    final resume = await service.resumeForSeries('1001');
    expect(resume?.episodeId, '2001');
    expect(resume?.episodeIndex, 2);
    expect(resume?.positionMs, 45000);
    expect(
      await service.resumeForEpisode('1001', '2001'),
      isNotNull,
    );
    expect(await service.resumeForEpisode('1001', '9999'), isNull);
    expect(service.cachedResumeForSeries('1001')?.positionMs, 45000);
  });

  test('同一集 30 秒内只上传一次', () async {
    final transport = _FakeTransport();
    final service = _service(transport);
    addTearDown(service.dispose);
    await service.init();
    await service.sendCode(number: '13800138000');
    await service.verifyCode('123456');
    for (var i = 0; i < 3; i++) {
      await service.reportProgress(
        seriesId: '1001',
        episodeId: '2001',
        episodeIndex: 0,
        positionMs: 1000 + i,
        durationMs: 60000,
        episodeCount: 12,
      );
    }
    expect(transport.uploadCount, 1);
  });

  test('本机与账号分开存：退出只清本账号，另一账号不受影响', () async {
    final store = HongguoAccountCloudStore.memory();
    await store.putFavorites('u1', [
      const HongguoCloudFavorite(seriesId: '1001', title: '剧 1001'),
    ]);
    await store.putFavorites('u2', [
      const HongguoCloudFavorite(seriesId: '1002', title: '剧 1002'),
    ]);
    await store.putHistory('u1', [_progress()]);
    expect(store.favorites('u1').length, 1);
    expect(store.favorites('u2').length, 1);

    await store.clearAccount('u1');
    expect(store.favorites('u1'), isEmpty);
    expect(store.history('u1'), isEmpty);
    expect(store.favorites('u2').length, 1);
  });

  test('退出登录清会话与账号箱，续播接口随即返回 null', () async {
    final service = _service(_FakeTransport());
    addTearDown(service.dispose);
    await service.init();
    await service.sendCode(number: '13800138000');
    await service.verifyCode('123456');
    await service.reportProgress(
      seriesId: '1001',
      episodeId: '2001',
      episodeIndex: 0,
      positionMs: 1000,
      durationMs: 60000,
      episodeCount: 12,
    );
    expect(await service.resumeForSeries('1001'), isNotNull);
    await service.logout();
    expect(service.signedIn, isFalse);
    expect(await service.resumeForSeries('1001'), isNull);
    expect(service.accountFavorites, isEmpty);
    expect(service.cloudHistory, isEmpty);
  });

  test('解析：收藏 / 进度 / 预约 / 账号资料', () {
    final favorites = HongguoAccountHttpTransport.parseFavoritesJson({
      'code': 0,
      'data': {
        'video_shelf_info': [
          {
            'series_id': '1001',
            'series_title': '剧 1001',
            'series_cover_url': 'https://example.com/c.jpg',
            'collect_time': 1700000000,
            'video_data': {'episode_cnt': 12},
          },
        ],
      },
    });
    expect(favorites.length, 1);
    expect(favorites.first.badge, '全 12 集');
    expect(favorites.first.collectedAtMs, 1700000000000);

    final progress = HongguoAccountHttpTransport.parseProgressRows([
      {
        'series_id': '1001',
        'vid': '2001',
        'vid_index': 3,
        'current_play_time': 45000,
        'current_total_time': 60000,
        'last_watch_time': 1700000000,
        'episode_count': 12,
      },
    ]);
    expect(progress.length, 1);
    expect(progress.first.episodeIndex, 2);
    expect(progress.first.updatedAtMs, 1700000000000);

    final upcoming = HongguoAccountHttpTransport.parseReservationsJson({
      'code': 0,
      'data': {
        'subscribe_items': [
          {'item_id': '3001', 'name': '待上线剧', 'is_online': false},
        ],
      },
    }, false);
    expect(upcoming.length, 1);
    // 未上线条目没有可播剧集 id：reservation: 命名空间，不可播。
    expect(upcoming.first.seriesId, 'reservation:3001');
    expect(upcoming.first.playable, isFalse);

    expect(
      () => HongguoAccountHttpTransport.parseProfileJson({
        'code': 0,
        'data': {'biz_user_id': '', 'user_name': ''},
      }),
      throwsA(isA<HongguoAccountError>()),
    );
    final profile = HongguoAccountHttpTransport.parseProfileJson({
      'code': 0,
      'data': {'biz_user_id': 'u9', 'user_name': '阿狸'},
    });
    expect(profile.userId, 'u9');
  });
}
