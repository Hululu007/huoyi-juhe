// ZakaTV jar 常量（站点库批 2026-11-27 瘦身后）：
// 站点登记表已移出包、进「凡人修仙站点.sql」站点库，导入激活后由
// SourceRegistry.syncSqlSites 按库内登记行注册 jar 站；本文件只留
// 三个 jar 本体（仍绑定在包里当公共引擎）的 id / asset / 指纹常量
// 与被排除站清单（历史账，恢复须用户另行下令）。
//
// 铁律：每次合 jar 完必须跑 scripts/sync_jar_fingerprint.sh 同步指纹
// （声明 MD5 与盘上 jar 实测 MD5 对不上时，原生拒载、全部 jar 站
// 不注册；火蚁TV +40/+41 已因此丢过 244 站）。

const String zakatvJarAsset = 'assets/jars/zakatv.jar';
const String zakatvJarMd5 = 'fd800a963fde845dd0a5fe797d7d7516';
const String zakatvJarId = 'zakatv';
const String youtubeJarAsset = 'assets/jars/youtube.jar';
const String youtubeJarMd5 = 'd294ce251d3b2aa8528efff12cc4bf19';
const String youtubeJarId = 'youtube';
const String oneJarAsset = 'assets/jars/one.jar';
const String oneJarMd5 = 'af504c50de9f88246da9b086b5893c42';
const String oneJarId = 'one';
const String youtubeConfigAsset = 'assets/youtube3.json';
const String youtubeSpiderClass = 'com.github.catvod.spider.YouTube';

class ZakatvExcludedSite {
  const ZakatvExcludedSite(this.key, this.name, this.reason);
  final String key;
  final String name;
  final String reason;
}

const List<ZakatvExcludedSite> zakatvExcludedSites = [
  ZakatvExcludedSite('zakahzai747', '🔞盒子AI视频┃747专线', '盒子AI 747 专线：同盒子AI，服务端死亡未进成品'),
  ZakatvExcludedSite('zakahzai', '🔞盒子AI视频┃原生', '盒子AI：服务端 register 全 404，2026-10-24 修复批已摘，服务端死亡未进成品'),
  ZakatvExcludedSite('ZakaXme', '🔞樱桃破解┃站群直连', '樱桃：服务端 register 500，2026-10-24 修复批已摘，服务端死亡未进成品'),
  ZakatvExcludedSite('zakajavbus', '🔞JAVBUS┃磁力自动离线', 'JavBus：全是磁力、App 内无磁力播放，2026-10-31 摘除令'),
  ZakatvExcludedSite('zaka520av', '🔞520AV影城', '520AV：视频 CDN lovebb.520avtv.com 无响应（TLS 通、GET 后零字节，出口 504），详情页无其他播放源；搜索 303 跳女优页、女优页 307 回首页，2026-11-07 修复批已摘，CDN 恢复再议'),
  ZakatvExcludedSite('zakaaoxx69', '🔞AOXX69┃亞洲綜合', 'AOXX69：站方 www.aoxx69.app 自 2026-11-08 起本机出口多次实测无响应（curl https/http 与 Python urllib 各 20-30 秒超时、0 字节；同出口 Google/香蕉 API/img 域名均通，非出口断）；无其他镜像（aoxx69.com 301 回同一 www 主机）；站内链接已去掉 /hk/ 前缀、蜘蛛 /hk/ 路径与列表正则亦过期；2026-11-08 修不好按令摘登记，主机恢复再议'),
];
