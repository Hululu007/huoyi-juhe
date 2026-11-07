try:
    from base.spider import BaseSpider
except Exception:
    try:
        from base import BaseSpider
    except Exception:
        class BaseSpider:
            pass


import gzip
import html as _html
import http.client
import http.cookiejar
import json
import re
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = 'https://1104.hyaidj221.lol'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

CATS = [
    ('21', '视频1区'), ('22', '视频2区'), ('35', '精品推荐'), ('36', '主播秀色'),
    ('37', '中文字幕'), ('38', '童颜巨乳'), ('39', '性感人妻'), ('40', '强奸乱伦'),
    ('44', '丝袜OL'), ('45', '自拍偷拍'), ('46', '日本片商'), ('48', '网曝系列'),
    ('49', '麻豆传媒'), ('51', '国产乱伦'), ('52', '国产丝袜'), ('53', '国产SM'),
    ('54', '国产人妻'), ('55', '探花嫖娼'), ('56', '同性恋'), ('57', '国产区'),
    ('58', 'AV区'), ('59', '欧美区'), ('60', '动漫区'), ('61', '其他区'),
    ('62', '网曝门'), ('97', '学生少女'), ('98', '技师风采'), ('99', '熟女少妇'),
    ('100', '国产热播'), ('101', '反差母狗'), ('102', '美脚丝足'), ('103', '情侣自拍'),
    ('104', '偷情约炮'), ('105', '真实偷拍'), ('106', '高潮喷水'), ('108', '强奸迷奸'),
    ('109', '户外露出'), ('110', '情趣内衣'), ('111', '精选探花'), ('112', '黑料曝光'),
    ('113', '网曝门事件'), ('114', '校园猛料'), ('115', '网红流出'), ('116', '明星黑料'),
    ('119', '抓奸名场面'), ('120', '男同女同'), ('121', 'JK少女'), ('122', '黑丝白丝'),
    ('123', '女仆'), ('124', 'cosplay'), ('125', 'OL制服'), ('127', '空姐制服'),
    ('128', '护士医生'), ('130', '禁忌母子'), ('131', '兄弟姐妹'), ('132', '爱上嫂子'),
    ('133', '狂操小姨'), ('134', '换夫换妻'), ('135', '淫荡儿媳'), ('136', '爷爷奶奶'),
    ('138', '啪啪直播'), ('139', '学生直播'), ('140', '自慰诱惑'), ('141', '乱伦直播'),
    ('142', '户外勾搭'), ('143', '车震直播'), ('144', '国产AV'), ('145', '欧美精选'),
    ('146', '户外搭讪'), ('147', '美女自慰'), ('148', '成人剧情'), ('149', '黑人大屌'),
    ('150', '群P大作战'), ('151', '欧美重口'), ('153', '人兽性交'), ('155', '人妖伪娘'),
    ('156', '孕妇内射'), ('158', '扩阴拳交'), ('159', '阳具巨物'), ('163', '日本中文'),
    ('164', '无码流出'), ('170', '伦理精选'), ('173', '主播网黄'), ('174', '色情综艺'),
    ('175', '情色AV'), ('176', '乱伦精选'), ('177', '私房俱乐部'), ('185', '国产自拍.'),
    ('186', '主播.'), ('187', '欧美.'), ('188', '日本无码.'), ('184', 'AI短剧'),
]

_JAR = http.cookiejar.CookieJar()
_OPENER = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(_JAR))


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _get(url, timeout=30):
    h = {'User-Agent': UA}
    for _ in range(3):
        try:
            req = urllib.request.Request(url, headers=h)
            with _OPENER.open(req, timeout=timeout, context=_ctx()) as resp:
                raw = resp.read()
                enc = (resp.headers.get('Content-Encoding') or '').lower()
                if enc == 'gzip' or raw[:2] == b'\x1f\x8b':
                    try:
                        raw = gzip.decompress(raw)
                    except Exception:
                        pass
                return raw.decode('utf-8', 'replace')
        except urllib.error.HTTPError as e:
            try:
                return e.read().decode('utf-8', 'ignore')
            except http.client.IncompleteRead as ie:
                return ie.partial.decode('utf-8', 'ignore')
        except Exception:
            time.sleep(1)
    return ''


def _unescape(s):
    return _html.unescape(s or '').replace('\\/', '/')


def _strip_tags(s):
    if not s:
        return ''
    t = re.sub(r'<[^>]+>', ' ', s)
    return _html.unescape(re.sub(r'\s+', ' ', t)).strip()


def _norm_id(ids):
    if isinstance(ids, (list, tuple)):
        ids = ids[0] if ids else ''
    return str(ids or '').strip()


def _norm_pg(pg):
    try:
        pg = int(pg)
    except Exception:
        pg = 1
    return pg if pg >= 1 else 1


def _parse_cards(html):
    card_re = re.compile(r'(?s)/index.php/vod/play/id/(\d+)/sid/1/nid/1\.html"[^>]*>.*?<img[^>]*src="([^"]+)"[^>]*>.*?<strong class="title">([^<]+)</strong>')
    out = []
    seen = set()
    for m in card_re.finditer(html or ''):
        vid = m.group(1).strip()
        if not vid or vid in seen:
            continue
        seen.add(vid)
        title = _unescape(m.group(3).strip())
        if not title:
            continue
        cover = m.group(2).strip()
        out.append({'vod_id': vid, 'vod_name': title, 'vod_pic': cover, 'vod_remarks': ''})
    return out


def _parse_player_url(html):
    m = re.search(r'(?s)player_aaaa=.*?"url":"([^"]+)"', html or '')
    if not m:
        return ''
    return _unescape(m.group(1))


def _play_url(vid):
    return BASE + '/index.php/vod/play/id/%s/sid/1/nid/1.html' % vid


def _parse_title(html):
    m = re.search(r'(?s)<title>(.*?)</title>', html or '')
    if not m:
        return ''
    title = _unescape(m.group(1).strip())
    if title.startswith('在线播放'):
        title = title[len('在线播放'):]
    if title.endswith(' - 红颜AI短剧'):
        title = title[:-len(' - 红颜AI短剧')]
    return title.strip()


def _parse_cover(html):
    m = re.search(r'<meta property="og:image"[^>]*content="([^"]+)"', html or '')
    if m and m.group(1).strip():
        return m.group(1).strip()
    m = re.search(r'poster="([^"]+)"', html or '')
    if m:
        return m.group(1).strip()
    return ''


class Spider(BaseSpider):
    def getName(self):
        return '红颜AI短剧'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=''):
        html = _get(BASE + '/index.php/vod/type.html')
        cats = []
        seen = set()
        for m in re.finditer(r'href="/index.php/vod/type/id/(\d+)\.html"[^>]*>([^<]+)</a>', html or ''):
            cid, name = m.group(1), m.group(2).strip()
            if not name or cid in seen:
                continue
            seen.add(cid)
            cats.append((cid, name))
        if not cats:
            cats = list(CATS)
        items = []
        if cats:
            html2 = _get(BASE + '/index.php/vod/type/id/%s.html' % cats[0][0])
            items = _parse_cards(html2)
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in cats],
            'list': items,
        }

    def homeVideoContent(self):
        html = _get(BASE + '/index.php/vod/type/id/21.html')
        return {'list': _parse_cards(html), 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        tid = _norm_id(tid) or '21'
        if pg <= 1:
            url = BASE + '/index.php/vod/type/id/%s.html' % tid
        else:
            url = BASE + '/index.php/vod/type/id/%s/page/%d.html' % (tid, pg)
        html = _get(url)
        items = _parse_cards(html)
        has_more = bool(items) and ('/page/%d.html' % (pg + 1)) in (html or '')
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': len(items) if not has_more else 0}

    def detailContent(self, ids):
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        html = _get(_play_url(nid))
        title = _parse_title(html)
        m3u8 = _parse_player_url(html)
        if not title or not m3u8:
            return {'list': []}
        cover = _parse_cover(html)
        synopsis = ''
        m = re.search(r'<meta name="description"[^>]*content="([^"]*)"', html or '')
        if m:
            synopsis = _unescape(m.group(1).strip())
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': '',
            'vod_year': '',
            'vod_area': '',
            'vod_content': synopsis,
            'type_name': '',
            'vod_tag': '',
            'vod_play_from': '在线播放',
            'vod_play_url': '播放$%s' % m3u8,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        url = BASE + '/index.php/vod/search.html?wd=%s' % urllib.parse.quote(str(key or ''))
        html = _get(url)
        items = _parse_cards(html)
        return {'list': items, 'page': _norm_pg(pg), 'pagecount': 0, 'total': len(items)}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        if raw.startswith('http'):
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        vid = raw.strip()
        if not vid or not vid.isdigit():
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        html = _get(_play_url(vid))
        m3u8 = _parse_player_url(html)
        if not m3u8:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        return {'parse': 0, 'playUrl': m3u8, 'url': m3u8, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', '']

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
