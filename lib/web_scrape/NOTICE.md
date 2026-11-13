# 网页爬取模块出处说明

本目录代码分两类来源，分别注明。

## 一、移植自 NexHub（Apache-2.0）

- 来源仓库：https://github.com/nexhub-app/NexHub
- 依据提交：37ddbdd
- 许可证：Apache License 2.0（以原仓库 LICENSE / NOTICE 为准；
  本目录各文件头均注出处）
- 移植日期：2026-11-13

### 原文复制

| 本目录文件 | 原始路径 |
| --- | --- |
| `verification_detector.dart` | `lib/core/scraper/verification_detector.dart` |

### 改编

| 本目录文件 | 原始路径 | 改动点 |
| --- | --- | --- |
| `html_utils.dart` | `lib/core/utils/html_utils.dart` | XPath 分支改为抛 `UnsupportedError`（本树无 `xpath_selector` 依赖）；其余 CSS 查询逻辑与原文一致 |
| `web_scrape_service.dart` | `lib/core/scraper/web_scrape_service.dart` | 抓取改走 `package:http` + `gbk_codec` 解码（原 `HttpFetcher` 未移植）；验证判定改走随本批移植的 `VerificationDetector`；`ScrapeResult` 保留 `html` 字段；另加可注入抓取供测试 |

## 二、改编自万象影院自有代码（用户自有项目，非 NexHub 原文）

| 本目录文件 / 资产 | 来源 | 改动点 |
| --- | --- | --- |
| `scrape_py_service.dart` | 万象影院 `lib/core/pygen/onekey_py_service.dart` | 探测取数改走本目录共用的 `fetchScrapeHtml`；模板库匹配复用本树 `OneKeyPyService.matchDomainTemplate`；校验改走 `PyBridge.validate`；注册改走 `SourceRegistry.addPyImport` / `updatePyImportContent` + 同名判更新；去掉 `PluginConfig` / `SourceRepository` / `PyImporter` 引用 |
| `assets/py_tools/universal_spider_template.py` | 万象影院同路径资产 | 一字未改；与本树 `assets/py_tools/yijianxiepy.py` 内嵌模板同源 |

页面 `lib/pages/web_scrape_page.dart` 按万象爬取页结构、本树主题与规矩
重写，非复制；顶栏入口只加在解锁态 AppBar。

## 三、未移植项

- `http_fetcher.dart`（dio 抓取层）：本树无 dio，改走 `package:http`。
- 验证屏（WebView 内验证流程）：一期只诚实报错 + 指引去浏览器验证。
- `file_exporter.dart`（file_picker 保存）：本批改走 `share_plus` 系统分享。
- Chapter 适配器（结果转阅读章节）：一期不做，页内展示 + 外部浏览器打开。

## 四、已知限制

- XPath 选择器在本应用里不可用（`HtmlUtils` 遇 XPath 抛 `UnsupportedError`）。
- 验证页（Cloudflare 等挑战页）一期不绕过：命中时报错并指引用户去浏览器
  完成验证，二期再议。
- 动态渲染页面（内容由脚本加载）可能爬不到内容，属正常现象，页面如实提示。
