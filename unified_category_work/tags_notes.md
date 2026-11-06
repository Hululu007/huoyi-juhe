# 标签采集工作笔记（第 7 项）

日期：2026-11-06；执行人：标签采集执行人；树：~/workspace/huoyi_juhe；未推仓、未构建。

## 做法

1. 先读 `~/workspace/tpd_harvest/all_stations_tags.json`（2026-11-06 当天 8 批并行收站的成果，后补 wohs 400 条）：201 站，40703 条原始标签，其中 browsable=true 40651 条、browsable=false 52 条（带 note 原因）。
2. 直接用这份总表填资产，不再逐站重采（当天刚采过，重采只是重复劳动；只对 3 条标签链接和 missav 做了现网复核，见“本地验证”）。
3. 生成脚本 `unified_category_work/fill_tags.py`：只收 browsable 严格为 true 的条目；名、链接去首尾空格，空名/空链接跳过（0 条）；同名按精确字符串归并、同名下保留每站每条链接（wohs 23 个中文名跨组重复、URL 不同，全部保留，未去重合并）；仅剔除 3 条 aoxx69 的完全重复三元组（同名、同站、同 URL 各出现两次，是采集时同一条链接收了两遍）。
4. 资产其余字段：`total_site_count` 200→201（多出的 1 站是 wohs，上一版资产生成时它还没进核心）；`sites_without_categories` 按任务口径更新：采到可用标签的 20 站从里面去掉，剩 53 站；`site_count` 仍为 127（有静态分类的站数，未变）；`version` 1→2，`source` 补上标签来源。`categories` 一字未动（脚本内断言 + 事后比对）。
5. `sites_without_categories` 含义变化注意：原来是“无静态分类的 73 站”，现在是“既无静态分类、也无可用标签的 53 站”；另有 21 站只有标签、没有静态分类（20 站原在无分类表内 + wohs 从未进过该表）。Dart 侧 `lib/services/unified_video_categories.dart` 头部注释与字段注释已同步改掉（只改注释，未改逻辑）。

## 结果数字

| 项 | 数 |
|---|---|
| 总表原始标签条目 | 40703 |
| browsable=false 跳过（带原因） | 52 |
| 完全重复三元组剔除（aoxx69） | 3 |
| 填进资产的标签条目 | 40648 |
| 去重后标签名 | 38205 |
| 有可用标签的站 | 50 |
| 只有不可浏览标签的站 | 2（herexxx、kissjav，各 23 条全为 false） |
| 无标签的站 | 149 |
| 标签名只出现在 1 个站 | 36618 |
| 标签名出现在 2 个及以上站 | 1587 |
| 跨站中文重名 | 797 个中文名出现在 2 个及以上站（按精确字符串归并，链接各留各的） |
| 资产体积 | 129466 字节 → 4776822 字节（约 4.6MB） |
| 分类 | 未动：1600 名、2838 条、127 站 |
| 账目 | 127（有分类）+ 21（只有标签）+ 53（既无分类也无标签）= 201 |

热门标签（按站数降序，Dart 侧 tagNames 同款排序）：巨乳 15 站、口交 13 站、中出/人妻/熟女各 11 站、肛交 10 站、OL/自慰各 9 站。

## 追溯抽查（每条都能追溯到站方来源）

- 校服：99jj https://www.99jj25.com/tags/16801ba25bd82cd7a951f0d92e548d03/ 、jable https://jable.tv/tags/school-uniform/ 、tanhua91 https://www.91tanhua196.sbs/search?keywords=校服 、wohs https://whos.tv/frames/type-clothes/label-31 、xojav https://xojav.tv/tags/school-uniform
- 高跟鞋：99jj、swagr（http://zi.ri511.xyz/tags/84）、wohs 两条（type-clothes/label-447 与 type-prop/label-190207，跨组重名保留的实证）
- 中出：11 站，99jj / avjoy（cn.avjoy.ws/search/videos/中出）/ hl365 / hohoj / jable（/tags/creampie/）/ javplay / netflav / pigav / swagr / wuyetv / xojav
- 丝袜：7 站，99jj / hl365 / missavt / swagr / tanhua91 / wohs（/frames/type-clothes/label-134）/ wuyetv
- wohs 400 条全为 browsable=true，与上一批核实一致。

## 已知问题 / 注意点（未改数据，如实记下）

- 99jj 一家 19561 条，占总数近一半，多为长尾标签（如 `#`、`#01`、`（1）`、视频标题碎片），是站方标签云原样，无过滤。标签组共 38205 名，其中 36618 名只属于 1 个站；页内搜索可过滤，折叠态只露 30 个 chip（`_collapsedCount = 30`），首屏不至于被淹没，但展开/搜索 3.8 万个 chip 在手机上的流畅度必须真机验。
- okxxx 6030 个名带 `（视频数）` 后缀（如 `1080 hd (306)`、`18 (3122)`），是总表原样（采集时只给部分站洗了计数后缀，okxxx 没洗），本次照实收，未改。
- 235 条链接是 http 不是 https（hjw 34 条、swagr 201 条），站方原链接，照实收。
- 52 条 browsable=false 已排除：hanime 2 条（标签页 60 秒超时）、avhwa 4 条（标签页静态仅 1 条视频链接，疑 JS 加载）、herexxx 23 条（同 avhwa 原因）、kissjav 23 条（标签页连接失败 HTTP 0）。
- tanhua91 只收了标签索引第 1 页 493 条，其余 169 页未收（总表 md 原话）。
- 资产 4.6MB，包体积与启动解析耗时待真机验。

## 本地验证

- `python3 -m json.tool`：JSON 合法。
- `unified_category_work/validate_tags.py`：按 `unified_video_categories.dart` 的 `parseUnifiedVideoCategories` 逻辑逐行复刻（Map 形 tags、browsable 严格为 true、空名/空链接跳过、字段缺失容错），解析出标签 38205 名、40648 条、50 站；分类 1600 名未变；`sites_without_categories` 53；账目 127+21+53=201。
- 现网复核（逐个 curl，2026-11-06 23:2x）：wohs 校服标签页 HTTP 200（649251 字节）、jable /tags/creampie/ HTTP 200（85271 字节）、okxxx /tags/1080p/ HTTP 200（397720 字节）。
- missav 复核：missav.com 首页现为 HTTP 200（总表当时记的是中继 410、missav.ws 超时、missav.ai 与 missav123.com 403），missav.ws 仍 HTTP 403。首页能开不等于有标签可采，本次未重探 missav 的标签页，仍按总表“未发现标签链接”记。
- 未跑 flutter analyze/test（总协调统一跑）。短剧区一字未动。

## 真机还需验

1. 分类页统一模式出现“标签”组，热门标签排前面，折叠态只露 30 个，展开后滚动/搜索 3.8 万个 chip 不卡、不掉帧。
2. 点标签（如“中出”“校服”）进站源搜索，按站分组出电影结果；逐站核对结果真是该标签的内容。
3. 资产 4.6MB 对包体积与分类页首次打开耗时有无可感影响。
4. 点 wohs 的跨组重名标签（如“高跟鞋”）时，两条不同链接（服饰组/道具组）是否都出结果。

## 采不到的站（151 站：2 站只有不可浏览标签 + 149 站无标签）

原因原样摘自 `~/workspace/tpd_harvest/all_stations_tags.md` 第二节（2026-11-06 采集结论），未改写。

### 只有不可浏览标签的站

| 站 key | 情况 |
|---|---|
| herexxx | 23 条全为 browsable=false：标签页 HTTP 200 但静态仅含 1 条视频链接，内容列表疑似 JS 加载 |
| kissjav | 23 条全为 browsable=false：标签页连接失败（HTTP 0，两次复核均不通） |

### 无标签的站（149 站）

| 站 key | 原因 |
|---|---|
| mjv011 | 站可打开(HTTP 200)，首页/标签页/详情页均未发现标签链接 |
| huangguo | 出口够不着：首页换新连接重试后仍超时(HTTP 000) |
| huangguotv | 站可打开(HTTP 200)，但首页、标签页 /tags(200)、标签页 /tags/(200)、标签页 /tag(301)、详情页(200)、详情页(200)均未发现标签链接 |
| hgtvim | 标签索引页 /tags.html 可打开(HTTP 200，28785字节)，但页内无标签链接（疑 JS 渲染或无标签体系） |
| huai | 出口够不着：首页换新连接重试后仍超时(HTTP 000) |
| sex8 | 站可打开(HTTP 200)，首页/标签页/详情页均未发现标签链接 |
| hgdjv | App 接口站，无网页标签体系（模块走签名 API，无 /tags 类网页入口） |
| km2 | App 接口站，无网页标签体系（模块走签名 API，无 /tags 类网页入口） |
| cucumber | 出口够不着：首页换新连接重试后仍超时(HTTP 000) |
| haijiao | App 接口站，无网页标签体系（模块走签名 API，无 /tags 类网页入口） |
| md | App 接口站，无网页标签体系（模块走签名 API，无 /tags 类网页入口） |
| utube | App 接口站，无网页标签体系（模块走签名 API，无 /tags 类网页入口） |
| av91 | App 接口站，无网页标签体系（模块走签名 API，无 /tags 类网页入口） |
| lxs | App 接口站，无网页标签体系（模块走签名 API，无 /tags 类网页入口） |
| javrate | 首页误收的站外广告链已剔除；首页/标签页/详情页均未发现真实标签链接 |
| txfans | 站可打开(HTTP 200)，首页/标签页/详情页均未发现标签链接 |
| juyin | 站可打开(HTTP 200)，首页/标签页/详情页均未发现标签链接 |
| dayday | 站可打开(HTTP 200)，首页/标签页/详情页均未发现标签链接 |
| dsav | App 接口站，无网页标签体系（模块走签名 API，无 /tags 类网页入口） |
| kuaihuo | 站可打开(HTTP 200)，首页/标签页/详情页均未发现标签链接 |
| jack20 | 站可打开(HTTP 200)，首页/标签页/详情页均未发现标签链接 |
| gqck | 站可打开(HTTP 200)，首页/标签页/详情页均未发现标签链接 |
| sihucdn | 站可打开但首页仅 3.7KB JS 壳，首页/标签页均无标签链接（疑 JS 渲染） |
| sihu | 站可打开但首页仅 3.7KB JS 壳，首页/标签页均无标签链接（疑 JS 渲染） |
| xx9 | 站可打开(HTTP 200)，首页/标签索引页/详情页均未发现标签链接 |
| 69vj | WP 站，首页/标签页/3 个详情页均未发现标签链接 |
| wnzs | App 接口站，无网页端；API host 直连超时，无标签体系 |
| tudou | H5 壳站，首页仅 9.6KB，首页/标签页均无标签链接（疑 JS 渲染） |
| xjh5 | H5 壳站，首页仅 9.6KB，首页/标签页均无标签链接（疑 JS 渲染） |
| xj2 | 站打不开：首页超时/出口够不着（HTTP 000，换新连接重试后仍不通） |
| missav | 中继站 HTTP 410、missav.ws 超时、missav.ai 与 missav123.com 均 HTTP 403（疑 CF 盾），换新连接重试后仍打不开 |
| jm | 站可打开(HTTP 200)，/tags 页为 JS 渲染，静态页面内无标签链接 |
| getav | Next.js 站，首页与 /tags、/zh/tags（404）均无标签链接 |
| hsck | 站可打开(HTTP 200)，首页/标签索引页/详情页均未发现标签链接 |
| missavoff | missav.live 超时、missav.ai HTTP 403（疑 CF 盾），换新连接重试后仍打不开 |
| mirror | 站打不开：首页超时/出口够不着（HTTP 000，换新连接重试后仍不通） |
| dsd | 站可打开(HTTP 200)，但站上只有导航类 label 页（最新影片/热门影片/常见问题/商务合作/备用网址等），无视频标签体系 |
| lissav | 首页 HTTP 500，重试后仍 500，站服务端异常 |
| pb | 站可打开(HTTP 200)，详情页 /video-{id}.htm 上无标签链接，首页为 JS 壳、无标签入口 |
| av18av | 首页/详情页只有分类/题材/女优链接，未发现标签(/tag |
| dage | 站可打开(HTTP 200)，首页为小体积页、无标签入口与标签链接 |
| sporn | 站可打开(HTTP 200)，首页与详情页均无标签链接；裸 slug 链接(/anal 等)是站内 25 个分类，不是标签 |
| ptt01 | 站可打开（经 /enter 入口），首页与详情页均未发现标签链接（/tags 索引 404） |
| cporn | 站可打开(HTTP 200)，首页与详情页只有 /categories/ 分类链接，无标签体系 |
| av6k | 首页/详情页只有分类/题材/女优链接，未发现标签(/tag |
| jav | 首页/详情页只有分类/题材/女优链接，未发现标签(/tag |
| jav777 | 站打不开：首页多次超时/被拒（HTTP 0），换新连接重试后仍不通 |
| go2av | /tag 页是出站链接页（a片、av9、伊莉論壇等友链，无标签内容），站无标签体系；此前误采的 5 条为各镜像站 /tag 入口链接，已剔除 |
| mmtv7 | 分类列表与详情页均未发现标签链接（仅分类与 JSON-LD genre） |
| zggjav | 站打不开：首页多次超时/被拒（HTTP 403），换新连接重试后仍不通 |
| avbigplat | https://porndav.com/ 首页 HTTP 200（30 秒复试通）；索引页与详情页均未发现标签链接（/tag |
| xhy11 | https://xhy.one/ 首页 HTTP 200；索引页 /tags HTTP 0; /tags/ HTTP 404; /tag HTTP 404; /tag/ HTTP 404; /tags.html HTTP 0; /label HTTP 0; /labels HTTP 404; /labels/ HTTP 0; /tags/index.html HTTP 0；首页与详情页均未发现标签链接（/tag |
| pj5ti | https://www.pj5ti.com/ 首页 HTTP 200（30 秒复试通）；索引页与详情页均未发现标签链接（/tag |
| thdh | 站打不开（30 秒复试）：thdhhaj.xyz 首页 HTTP 0；thdhran.xyz 首页 HTTP 0；thdhjtd.xyz 首页 HTTP 0 |
| hjapp | 无网站入口：API 型应用，模块只有 API 域名池（bapi.pyvllsdyh3.com / api.ww5api.com）与 CDN，无网页端、无标签体系；API 域名当网页打开回 403/超时 |
| 17rip | https://17rip.com 首页 HTTP 200；/label/ 下只有 4 个功能页链接（最新更新 /label/map.html、排行榜 /label/rank.html、周期表 /label/weekday.html、APP下载 /label/app.html），不是内容标签；首页与详情页也未发现 /tag |
| wukong | https://3ng23h0f.niumochishi06.sbs/ 首页 HTTP 200（30 秒复试通）；索引页与详情页均未发现标签链接（/tag |
| chengren91 | https://vaq68-90993-asyuua.miupiupiupiav131b72.top/ 首页 HTTP 200；索引页 /tags HTTP 404; /tags/ HTTP 404; /tag HTTP 404; /tag/ HTTP 404; /tags.html HTTP 404; /label HTTP 301; /labels HTTP 404; /labels/ HTTP 404; /tags/index.html HTTP 404；首页与详情页均未发现标签链接（/tag |
| badyi | https://badyi.cc/ 首页 HTTP 200；索引页 /tags HTTP 200; /tags/ HTTP 200; /tag HTTP 404; /tag/ HTTP 404; /tags.html HTTP 404; /label HTTP 404; /labels HTTP 404; /labels/ HTTP 404; /tags/index.html HTTP 200；首页与详情页均未发现标签链接（/tag |
| aiye | 站打不开：0826.aiyejikou0001.com 首页 HTTP 404；0826.aiyejikou0002.com 首页 HTTP 404 |
| av18avmcg | 站打不开：18av.pw 首页 HTTP 500；18av.ws 首页 HTTP 500 |
| avtoday | https://avtoday.io/ 首页 HTTP 200（30 秒复试通）；索引页与详情页均未发现标签链接（/tag |
| jptt | 站打不开（30 秒复试）：jptt.tv 首页 HTTP 403 |
| px8x | https://8xx6.lol/ 首页 HTTP 200（30 秒复试通）；索引页与详情页均未发现标签链接（/tag |
| pachub | https://pachub.net/ 首页 HTTP 200（30 秒复试通）；索引页与详情页均未发现标签链接（/tag |
| ssis | https://ssis1.cc/ 首页 HTTP 200；索引页 /tags HTTP 404; /tags/ HTTP 404; /tag HTTP 0; /tag/ HTTP 0; /tags.html HTTP 0; /label HTTP 404; /labels HTTP 0; /labels/ HTTP 404; /tags/index.html HTTP 0；首页与详情页均未发现标签链接（/tag |
| aisxpc | https://aicjjc.cc/ 首页 HTTP 200（30 秒复试通）；索引页与详情页均未发现标签链接（/tag |
| 321av | 站打不开（30 秒复试）：321av.fans 首页 HTTP 500；321xav.cc 首页 HTTP 500；321av.vip 首页 HTTP 500 |
| xlook | 站内无标签体系：首页/标签索引页/详情页均未发现标签链接 |
| madao | 站内无标签体系：标签云页不存在/为空，首页与播放页（站内无详情页、直链播放页）均无标签链接 |
| chinax | 首页可打开（主轮超时系 gzip 响应未解压所致）；站内无标签体系：播放页仅有标题分词搜索链接（“类型：”下惠惠/素人/爱侣/妄想等），无标签区、无标签索引页 |
| theporny | 站内无标签体系：API 驱动站（接口 POST /js 取流），网页端无标签页 |
| aimove | 站内无标签体系：短剧站，仅有分类，无标签 |
| henhenlu | 站内无标签体系：首页与播放页均无标签链接（站内无详情页、首页直链播放页；已实测播放页源码无任何 tag/label/search 链接） |
| mianfeiai | 站内无标签体系：API 驱动站，首页无标题/无标签入口 |
| avyanjiuyuan | 站内无标签体系：首页与播放页均无标签链接（已实测播放页源码无标签字样与 tag/label/search 链接） |
| xingkongfuli | 补探确认站内无标签体系：标签云页为空，首页/播放页无标签链接（主轮误把“下载客户端”导航当成标签，已清除） |
| ai2026 | 站内无标签体系：标签云页不存在/为空，首页与播放页均无标签链接 |
| dj91 | 站打不开：CF盾拦截（主轮与补探均被盾拦） |
| toptv | 站内无标签体系：标签云页不存在/为空，首页与播放页均无标签链接 |
| jin18 | 站内无标签体系：标签云页不存在/为空，首页与播放页均无标签链接 |
| klxq | 补探确认站内无标签体系：仅有“全部影片”等功能入口页（/index.php/label/new.html），详情页/播放页无标签 |
| taose | 站内无标签体系：标签云页不存在/为空，首页与播放页均无标签链接 |
| hongyan | 站内无标签体系：标签云页不存在/为空，首页与播放页均无标签链接 |
| naihenda | 站内无标签体系：标签云页不存在/为空，首页与播放页均无标签链接 |
| haijiao4k | 站内无标签体系：API/PWA 站，无标签页 |
| uudj | 站内无标签体系：短剧站，仅有分类，无标签 |
| madou | 站内无标签体系：标签云页不存在/为空，首页与播放页均无标签链接 |
| dj69 | https://agx6p-z9.69djudaq.vip/69d/ 首页 HTTP 200；索引 /tags HTTP 404；索引 /tag HTTP 404；agx6p-z9.69djudaq.vip/69d 首页 HTTP 200：未找到标签体系（首页、标签索引页 /tags、标签索引页 /tag均无标签链接） |
| ywmm | https://cc1k1k0k5k.18ywmmresi.buzz 首页 HTTP 200；索引 /tags HTTP 404；索引 /tag HTTP 404；cc1k1k0k5k.18ywmmresi.buzz 首页 HTTP 200：未找到标签体系（首页、标签索引页 /tags、标签索引页 /tag均无标签链接） |
| luoliai | https://luoliai.cc 首页 HTTP 200；索引 /tags HTTP 404；索引 /tag HTTP 404；luoliai.cc 首页 HTTP 200：未找到标签体系（首页、标签索引页 /tags、标签索引页 /tag均无标签链接） |
| shaofu | https://www.shaofudj.top 首页 HTTP 200；索引 /tags HTTP 404；索引 /tag HTTP 0；www.shaofudj.top 首页 HTTP 200：未找到标签体系（首页、标签索引页 /tags、标签索引页 /tag均无标签链接） |
| hgai | https://hgai8.cc 首页 HTTP 200；索引 /tags HTTP 404；索引 /tag HTTP 404；hgai8.cc 首页 HTTP 200：未找到标签体系（首页、标签索引页 /tags、标签索引页 /tag均无标签链接） |
| danai | https://danai88.cc 首页 HTTP 200；索引 /tags HTTP 404；索引 /tag HTTP 404；danai88.cc 首页 HTTP 200：未找到标签体系（首页、标签索引页 /tags、标签索引页 /tag均无标签链接） |
| yunmeng | https://89-ew-e.yunmengv.shop 首页 HTTP 200；索引 /tags HTTP 404；索引 /tag HTTP 404；89-ew-e.yunmengv.shop 首页 HTTP 200：未找到标签体系（首页、标签索引页 /tags、标签索引页 /tag均无标签链接） |
| javzw | https://www.javzw.cc 首页 HTTP 200；索引 /tags HTTP 404；索引 /tag HTTP 404；www.javzw.cc 首页 HTTP 200：未找到标签体系（首页、标签索引页 /tags、标签索引页 /tag均无标签链接） |
| hduanju | https://xiaonverjtx.click 首页 HTTP 200；索引 /tags HTTP 404；索引 /tag HTTP 200；详情页 HTTP 200；xiaonverjtx.click 首页 HTTP 200：未找到标签体系（首页、标签索引页 /tags、标签索引页 /tag、详情页均无标签链接）；另：首页“热搜/热词”词条全部链向站外广告域名，不是本站标签体系，故不计 |
| rscg91 | https://jcyh-gvz-nigo.obbplmm26y102.cc 首页 HTTP 200；索引 /tags HTTP 404；索引 /tag HTTP 404；jcyh-gvz-nigo.obbplmm26y102.cc 首页 HTTP 200：未找到标签体系（首页、标签索引页 /tags、标签索引页 /tag均无标签链接） |
| aidj | https://aisee10w29.buzz 首页 HTTP 200；索引 /tags HTTP 404；索引 /tag HTTP 404；aisee10w29.buzz 首页 HTTP 200：未找到标签体系（首页、标签索引页 /tags、标签索引页 /tag均无标签链接） |
| mose365 | https://exwxfmd4.work 首页 HTTP 200；索引 /tags HTTP 200；索引 /tag HTTP 200；详情页 HTTP 200；exwxfmd4.work 首页 HTTP 200：未找到标签体系（首页、标签索引页 /tags、标签索引页 /tag、详情页均无标签链接） |
| yiren | https://yiren234.cc 首页 HTTP 200；索引 /tags HTTP 404；索引 /tag HTTP 404；详情页 HTTP 200；yiren234.cc 首页 HTTP 200：未找到标签体系（首页、标签索引页 /tags、标签索引页 /tag、详情页均无标签链接） |
| zwdj | https://gczwfrusk.forum 首页 HTTP 200；索引 /tags HTTP 404；索引 /tag HTTP 404；详情页 HTTP 200；gczwfrusk.forum 首页 HTTP 200：未找到标签体系（首页、标签索引页 /tags、标签索引页 /tag、详情页均无标签链接） |
| hongxing | https://7p-r5-n.hongxingav.xyz 首页 HTTP 200；索引 /tags HTTP 404；索引 /tag HTTP 404；7p-r5-n.hongxingav.xyz 首页 HTTP 200：未找到标签体系（首页、标签索引页 /tags、标签索引页 /tag均无标签链接） |
| shunvwang | https://tv.shunvwang7.cc 首页 HTTP 200；索引 /tags HTTP 404；索引 /tag HTTP 404；tv.shunvwang7.cc 首页 HTTP 200：未找到标签体系（首页、标签索引页 /tags、标签索引页 /tag均无标签链接） |
| heitaoduanju | https://wap.heitaoduanju7.cc 首页 HTTP 200；索引 /tags HTTP 0；索引 /tag HTTP 404；wap.heitaoduanju7.cc 首页 HTTP 200：未找到标签体系（首页、标签索引页 /tags、标签索引页 /tag均无标签链接） |
| dingjiaseku | https://yxql-imh-nh4d.taoquan26s111.cc 首页 HTTP 200；索引 /tags HTTP 404；索引 /tag HTTP 404；yxql-imh-nh4d.taoquan26s111.cc 首页 HTTP 200：未找到标签体系（首页、标签索引页 /tags、标签索引页 /tag均无标签链接） |
| aiduanju | https://ai.aiduanjuwang8.cc 首页 HTTP 200；索引 /tags HTTP 404；索引 /tag HTTP 404；ai.aiduanjuwang8.cc 首页 HTTP 200：未找到标签体系（首页、标签索引页 /tags、标签索引页 /tag均无标签链接） |
| fuchou | https://kkb1.sixnicefczlm.cc 首页 HTTP 200；索引 /tags HTTP 0；索引 /tag HTTP 404；详情页 HTTP 200；kkb1.sixnicefczlm.cc 首页 HTTP 200：未找到标签体系（首页、标签索引页 /tags、标签索引页 /tag、详情页均无标签链接） |
| shunvqu | https://wap.snq2.cc 首页 HTTP 200；索引 /tags HTTP 0；索引 /tag HTTP 404；wap.snq2.cc 首页 HTTP 200：未找到标签体系（首页、标签索引页 /tags、标签索引页 /tag均无标签链接） |
| huangguazy | https://wap.huangguazy7.cc 首页 HTTP 200；索引 /tags HTTP 0；索引 /tag HTTP 404；wap.huangguazy7.cc 首页 HTTP 200：未找到标签体系（首页、标签索引页 /tags、标签索引页 /tag均无标签链接） |
| zwwm | https://zwwmtekr.lol 首页 HTTP 200；索引 /tags HTTP 404；索引 /tag HTTP 404；详情页 HTTP 200；zwwmtekr.lol 首页 HTTP 200：未找到标签体系（首页、标签索引页 /tags、标签索引页 /tag、详情页均无标签链接） |
| hgaidj | https://hgaidjzun.lol 首页 HTTP 200；索引 /tags HTTP 404；索引 /tag HTTP 200；详情页 HTTP 200；hgaidjzun.lol 首页 HTTP 200：未找到标签体系（首页、标签索引页 /tags、标签索引页 /tag、详情页均无标签链接） |
| jiuse | https://jiusequ.cyou 首页 HTTP 200；索引 /tags HTTP 404；索引 /tag HTTP 404；详情页 HTTP 200；jiusequ.cyou 首页 HTTP 200：未找到标签体系（首页、标签索引页 /tags、标签索引页 /tag、详情页均无标签链接）；另：首页有“热门搜索”词条，但全部链向站外广告域名（wolfbar/party91p 等），不是本站标签体系，故不计 |
| xianxia | home.xxaidj.cc 首页 HTTP 200：未找到标签体系（首页、标签索引页、详情页均无标签链接） |
| ai4k | wyswspqjtr.click 首页 HTTP 200：未找到标签体系（首页、标签索引页、详情页均无标签链接） |
| muzi | web.mzsp1.cc 首页 HTTP 0：未找到标签体系（首页、标签索引页、详情页均无标签链接） |
| guzhuang | 5g.guzhuangai8.cc 首页 HTTP 200：未找到标签体系（首页、标签索引页、详情页均无标签链接） |
| nvdi | nvdi496899299599.cc 首页 HTTP 200：未找到标签体系（首页、标签索引页、详情页均无标签链接） |
| caoliu | v2.cdn199.com 首页 HTTP 200：未找到标签体系（首页、标签索引页、详情页均无标签链接） |
| djwo | langwonqyl.forum 首页 HTTP 200：未找到标签体系（首页、标签索引页、详情页均无标签链接） |
| hgkpz | dykt1d.gyjwazo.cn 首页 HTTP 200：未找到标签体系（首页、标签索引页、详情页均无标签链接） |
| huangduanju | hpkspnbsk.xyz 首页 HTTP 404；hpkspvynq.buzz 首页 HTTP 200：未找到标签体系（首页、标签索引页、详情页均无标签链接） |
| jiuseduanju | www.jiuseai.top 首页 HTTP 200：未找到标签体系（首页、标签索引页、详情页均无标签链接） |
| xj | lw7k481j3l003h95pnwf.xjspapps.com 首页 HTTP 0：未找到标签体系（首页、标签索引页、详情页均无标签链接） |
| hbook | hd.skylines.pro 首页 HTTP 400；hbook.tv 首页 HTTP 200：未找到标签体系（首页、标签索引页、详情页均无标签链接） |
| hgdj58 | a2.hgdjap2.com 首页 HTTP 200：未找到标签体系（首页、标签索引页、详情页均无标签链接） |
| jav188 | jav188.net 首页 HTTP 200：未找到标签体系（首页、标签索引页、详情页均无标签链接） |
| crdj | 91crdjai.com 首页 HTTP 200：未找到标签体系（首页、标签索引页、详情页均无标签链接） |
| javher | javher.com 首页 HTTP 200：未找到标签体系（首页、标签索引页、详情页均无标签链接） |
| javwine | jav.wine 首页 HTTP 200：未找到标签体系（首页、标签索引页、详情页均无标签链接） |
| lissavcn | madou8.pw 首页 HTTP 500：未找到标签体系（首页、标签索引页、详情页均无标签链接） |
| pornhub | cn.pornhub365.com 首页 HTTP 500；cn.pornhub666.cc 首页 HTTP 500：未找到标签体系（首页、标签索引页、详情页均无标签链接） |
| hongluo | hongluo.co 首页 HTTP 200：未找到标签体系（首页、标签索引页、详情页均无标签链接） |
| ddys | ddys.io 首页 HTTP 200：未找到标签体系（首页、标签索引页、详情页均无标签链接） |
| javtiful | javtiful.com 首页 HTTP 200：未找到标签体系（首页、标签索引页、详情页均无标签链接） |
| vjav | https://vjav.com 首页 HTTP 200：未找到标签体系（首页、标签索引页均无标签链接） |
| tiktvod | https://tiktvod01.xyz 首页 HTTP 200：未找到标签体系（首页、标签索引页均无标签链接） |
| topjav | https://topjav.tv 首页 HTTP 200：未找到标签体系（首页、标签索引页均无标签链接） |
| javdino | https://javdino.com 首页 HTTP 200：未找到标签体系（首页、标签索引页均无标签链接） |
| roshy | 重探：https://roshy.tv 首页 HTTP 200，但本站无标签体系——首页与详情页均无本站 /tag/ 链接（仅一条外站 fullxcinema 标签链接），/tags/ 与 /tag/ 均 HTTP 404，站点地图 wp-sitemap.xml 无 post_tag 分类，只有 category（365 个分类）与 cast；上一轮 27 条无法复现，未硬写 |
| abjav | https://abjav.com 首页 HTTP 200：未找到标签体系（首页、标签索引页均无标签链接） |
| javfun | https://en.javfun.me 首页 HTTP 200：未找到标签体系（首页、标签索引页均无标签链接） |
| mythav | https://sdyoof.asia 首页曾 302、后 200 但页面为 JS 混淆编码（document.write 解码后渲染），静态抓不到标签链接，未找到标签体系 |
| senzuri | https://senzuri.tube 首页 HTTP 200，/tags 页为 JS 渲染（tags.js），静态 HTML 里无标签链接，未找到标签体系 |
| tokyomotion | https://www.tokyomotion.net 首页 HTTP 200，/tags 页标题存在但静态 HTML 里无标签链接，疑似 JS 加载，未找到标签体系 |
| x51 | https://51xz.vip 首页 HTTP 200：未找到标签体系（首页、标签索引页均无标签链接） |
| rouvideo | https://rou.video 首页 HTTP 200：未找到标签体系（首页、标签索引页均无标签链接） |
| porna91 | https://91porna.com 首页 HTTP 200：未找到标签体系（首页、标签索引页均无标签链接） |
| asextv | https://asextv.xyz 首页 HTTP 200：未找到标签体系（首页、标签索引页均无标签链接） |

