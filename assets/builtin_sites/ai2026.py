import gzip
import json
import re
import ssl
import time
import urllib.parse
import urllib.request

try:
    from base.spider import BaseSpider
except Exception:
    try:
        from base import BaseSpider
    except Exception:
        class BaseSpider:
            pass

BASE = 'https://11051735.2026aidj18.lol'
JUMP = 'https://2026.2026aidjtz.top/?yng'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

FALLBACK_CATS = [
    ('20', 'AI短剧'),
    ('21', '视频1区'),
    ('22', '视频2区'),
    ('23', '国产精品'),
    ('24', '华语AV'),
    ('25', '黑料吃瓜'),
    ('26', '欧美'),
    ('27', '禁漫'),
    ('28', '学生'),
    ('29', '乱伦'),
    ('30', '探花'),
    ('31', '日本无码'),
    ('32', '日本有码'),
    ('33', '主播网红'),
    ('35', '精品推荐'),
    ('36', '主播秀色'),
    ('37', '中文字幕'),
    ('38', '童颜巨乳'),
    ('39', '性感人妻'),
    ('40', '强奸乱伦'),
    ('44', '丝袜OL'),
    ('45', '自拍偷拍'),
    ('46', '日本片商'),
    ('48', '网曝系列'),
    ('49', '麻豆传媒'),
    ('51', '国产乱伦'),
    ('52', '国产丝袜'),
    ('53', '国产SM'),
    ('54', '国产人妻'),
    ('55', '探花嫖娼'),
    ('56', '同性恋'),
    ('57', '国产区'),
    ('58', 'AV区'),
    ('59', '欧美区'),
    ('60', '动漫区'),
    ('61', '其他区'),
    ('62', '网曝门'),
    ('64', '网红主播'),
    ('65', '国产传媒'),
    ('67', '人妻熟女'),
    ('68', '美乳巨乳'),
    ('69', '强制侵犯'),
    ('70', '制服诱惑'),
    ('73', '家庭乱伦'),
    ('76', '少女萝莉'),
    ('77', 'SM调教'),
    ('78', '绝顶潮吹'),
    ('83', '电车痴汉'),
    ('84', '淫欲痴女'),
    ('88', '女同性恋'),
    ('90', '欧美精品'),
    ('91', '国产自拍'),
    ('92', '日本动漫'),
    ('97', '学生少女'),
    ('98', '技师风采'),
    ('99', '熟女少妇'),
    ('100', '国产热播'),
    ('101', '反差母狗'),
    ('102', '美脚丝足'),
    ('103', '情侣自拍'),
    ('104', '偷情约炮'),
    ('105', '真实偷拍'),
    ('106', '高潮喷水'),
    ('108', '强奸迷奸'),
    ('109', '户外露出'),
    ('110', '情趣内衣'),
    ('111', '精选探花'),
    ('112', '黑料曝光'),
    ('113', '网曝门事件'),
    ('114', '校园猛料'),
    ('115', '网红流出'),
    ('116', '明星黑料'),
    ('119', '抓奸名场面'),
    ('120', '男同女同'),
    ('121', 'JK少女'),
    ('122', '黑丝白丝'),
    ('123', '女仆'),
    ('124', 'cosplay'),
    ('125', 'OL制服'),
    ('127', '空姐制服'),
    ('128', '护士医生'),
    ('130', '禁忌母子'),
    ('131', '兄弟姐妹'),
    ('132', '爱上嫂子'),
    ('133', '狂操小姨'),
    ('134', '换夫换妻'),
    ('135', '淫荡儿媳'),
    ('136', '爷爷奶奶'),
    ('138', '啪啪直播'),
    ('139', '学生直播'),
    ('140', '自慰诱惑'),
    ('141', '乱伦直播'),
    ('142', '户外勾搭'),
    ('143', '车震直播'),
    ('144', '国产AV'),
    ('145', '欧美精选'),
    ('146', '户外搭讪'),
    ('147', '美女自慰'),
    ('148', '成人剧情'),
    ('149', '黑人大屌'),
    ('150', '群P大作战'),
    ('151', '欧美重口'),
    ('153', '人兽性交'),
    ('155', '人妖伪娘'),
    ('156', '孕妇内射'),
    ('158', '扩阴拳交'),
    ('159', '阳具巨物'),
    ('163', '日本中文'),
    ('164', '无码流出'),
    ('170', '伦理精选'),
    ('173', '主播网黄'),
    ('174', '色情综艺'),
    ('175', '情色AV'),
    ('176', '乱伦精选'),
    ('177', '私房俱乐部'),
]

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

CACHE = {}
CATS_TTL = 3600
_CUR_BASE = [BASE]


def _now():
    return time.time()


def _http_get(url, referer=None, timeout=25):
    hdr = {
        'User-Agent': UA,
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9',
        'Accept-Encoding': 'gzip, deflate',
        'Connection': 'keep-alive',
    }
    if referer:
        hdr['Referer'] = referer
    for attempt in range(3):
        try:
            req = urllib.request.Request(url, headers=hdr)
            with urllib.request.urlopen(req, timeout=timeout, context=CTX) as resp:
                if resp.status != 200:
                    return None
                data = resp.read()
                enc = (resp.headers.get('Content-Encoding') or '').lower()
            if enc == 'gzip' or data[:2] == b'\x1f\x8b':
                try:
                    data = gzip.decompress(data)
                except Exception:
                    pass
            return data.decode('utf-8', 'replace')
        except Exception:
            if attempt < 2:
                try:
                    time.sleep(1)
                except Exception:
                    pass
    return None


def _resolve_base():
    raw = _http_get(JUMP, referer=None, timeout=20)
    if raw:
        m = re.search(r'fixedDomain\s*=\s*"([^"]+)"', raw)
        if m:
            dom = m.group(1).strip()
            if dom:
                return 'https://' + dom
    return BASE


def _fetch(path, referer=None):
    base = _CUR_BASE[0]
    html = _http_get(base + path, referer=referer or (base + '/'))
    if html is not None:
        return html
    new_base = _resolve_base()
    if new_base != base:
        _CUR_BASE[0] = new_base
        return _http_get(new_base + path, referer=referer or (new_base + '/'))
    return None


def _unescape(s):
    if not s:
        return ''
    return (s.replace('&nbsp;', ' ')
             .replace('&amp;', '&')
             .replace('&quot;', '"')
             .replace('&#39;', "'")
             .replace('&lt;', '<')
             .replace('&gt;', '>')
             .replace('\\/', '/'))


def _fix_url(raw):
    u = (raw or '').strip()
    if not u:
        return ''
    if u.startswith('//'):
        return 'https:' + u
    if u.startswith('/'):
        return _CUR_BASE[0] + u
    return u


def _strip_tags(s):
    if not s:
        return ''
    s = re.sub(r'<[^>]+>', ' ', s)
    s = _unescape(s)
    s = re.sub(r'\s+', ' ', s)
    return s.strip()


def _parse_cards(html):
    out = []
    if not html:
        return out
    pat = re.compile(
        r'<a[^>]+href="/index\.php/vod/detail/id/(\d+)\.html"[^>]*title="([^"]+)"[^>]*>'
        r'.*?<img[^>]+data-original="([^"]+)"',
        re.S)
    seen = set()
    for m in pat.finditer(html):
        vid = m.group(1).strip()
        title = _unescape(m.group(2).strip())
        cover = _fix_url(m.group(3))
        if not vid or vid in seen or not title:
            continue
        seen.add(vid)
        out.append({
            'vod_id': vid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_remarks': '',
        })
    return out


def _fetch_categories():
    v = CACHE.get('cats')
    if v and _now() - v[0] < v[2]:
        return v[1]
    cats = []
    html = _fetch('/')
    if html:
        pat = re.compile(
            r'href="/index\.php/vod/type/id/(\d+)\.html"[^>]*>([^<]+)<')
        seen = {}
        for m in pat.finditer(html):
            cid = m.group(1).strip()
            name = m.group(2).strip()
            if not name or name == '更多>>':
                continue
            try:
                n = int(cid)
            except Exception:
                continue
            if 184 <= n <= 188:
                continue
            if cid not in seen:
                seen[cid] = name
        cats = [(cid, seen[cid]) for cid in sorted(seen, key=lambda x: int(x))]
    ttl = CATS_TTL
    if not cats:
        cats = list(FALLBACK_CATS)
        ttl = 300
    if len(CACHE) > 20:
        CACHE.clear()
    CACHE['cats'] = (_now(), cats, ttl)
    return cats


def _dl_value(html, label):
    pat = re.compile(
        r'<dt>' + re.escape(label) + r'</dt>\s*<dd>(.*?)</dd>', re.S)
    m = pat.search(html)
    if not m:
        return ''
    v = _strip_tags(m.group(1))
    return v.rstrip('.').strip()


def _parse_title(html):
    m = re.search(r'<title>(.*?)</title>', html, re.S)
    if not m:
        return ''
    raw = _unescape(m.group(1).strip())
    for suf in (',2026AI短剧', '视频详情'):
        if raw.endswith(suf):
            raw = raw[:-len(suf)]
    return raw.strip()


def _parse_cover(html):
    m = re.search(
        r'<div class="detail-pic">.*?<img[^>]+src="([^"]+)"', html, re.S)
    if m:
        return _fix_url(m.group(1))
    m = re.search(r'<img[^>]+src="(https?://[^"]+)"', html)
    if m:
        return _fix_url(m.group(1))
    return ''


def _parse_synopsis(html):
    m = re.search(
        r'<dl class="juqing[^"]*">.*?<dd>(.*?)<a href="#jvqing-box"',
        html, re.S)
    if m:
        return _strip_tags(m.group(1))
    m = re.search(
        r'<dl class="juqing[^"]*">.*?<dd>(.*?)</dd>', html, re.S)
    if m:
        return _strip_tags(m.group(1))
    return ''


def _parse_player_url(html):
    if not html:
        return ''
    m = re.search(r'player_aaaa=.*?"url":"([^"]+)"', html, re.S)
    if m:
        return _unescape(m.group(1))
    m = re.search(r'"url":"(https?://[^"]+\.m3u8[^"]*)"', html)
    if m:
        return _unescape(m.group(1))
    return ''


def _norm_id(ids):
    if isinstance(ids, (list, tuple)):
        return str(ids[0]) if ids else ''
    return str(ids)


def _norm_pg(pg):
    try:
        return int(pg)
    except Exception:
        try:
            return int(str(pg).strip())
        except Exception:
            return 1


def _empty_detail(vod_id):
    return {'list': [{
        'vod_id': vod_id,
        'vod_name': '',
        'vod_pic': '',
        'vod_actor': '',
        'vod_director': '',
        'vod_remarks': '',
        'vod_year': '',
        'vod_area': '',
        'vod_content': '',
        'type_name': '',
        'vod_tag': '',
        'vod_play_from': '在线播放',
        'vod_play_url': '',
        'stills': [],
    }]}


class Spider(BaseSpider):

    def getName(self):
        return '2026短剧AI'

    def getDependence(self):
        return []

    def init(self, extend=None):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=False):
        cats = [{'type_id': cid, 'type_name': name}
                for cid, name in _fetch_categories()]
        return {'class': cats, 'filters': {}}

    def homeVideoContent(self):
        html = _fetch('/')
        items = _parse_cards(html)
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        tid = _norm_id(tid)
        pg = _norm_pg(pg)
        if pg < 1:
            pg = 1
        if pg <= 1:
            path = '/index.php/vod/type/id/%s/' % tid
        else:
            path = '/index.php/vod/type/id/%s/page/%d.html' % (tid, pg)
        html = _fetch(path)
        items = _parse_cards(html)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        raw = _norm_id(ids)
        nid = ''.join([ch for ch in raw if ch.isdigit()])
        if not nid:
            return _empty_detail(raw)
        html = _fetch('/index.php/vod/detail/id/%s.html' % nid)
        if not html:
            return _empty_detail(nid)
        title = _parse_title(html)
        if not title:
            return _empty_detail(nid)
        cover = _parse_cover(html)
        synopsis = _parse_synopsis(html)
        type_name = _dl_value(html, '类型：')
        year = _dl_value(html, '年代：')
        area = _dl_value(html, '地区：')
        lang = _dl_value(html, '语言：')
        updated = _dl_value(html, '更新：')
        parts = []
        if synopsis:
            parts.append(synopsis)
        if type_name:
            parts.append('类型：' + type_name)
        if lang:
            parts.append('语言：' + lang)
        play_path = ''
        m = re.search(
            r'href="(/index\.php/vod/play/id/\d+/sid/\d+/nid/\d+\.html)"',
            html)
        if m:
            play_path = m.group(1)
        if not play_path:
            return _empty_detail(nid)
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': updated,
            'vod_year': year,
            'vod_area': area,
            'vod_content': '\n'.join(parts),
            'type_name': type_name,
            'vod_tag': type_name,
            'vod_play_from': '在线播放',
            'vod_play_url': '正片$ai2026:%s' % nid,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        if pg < 1:
            pg = 1
        kw = urllib.parse.quote(str(key).strip())
        path = '/index.php/vod/search.html?wd=%s' % kw
        if pg > 1:
            path += '&page=%d' % pg
        html = _fetch(path)
        items = _parse_cards(html)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        header = {'User-Agent': UA, 'Referer': _CUR_BASE[0] + '/'}
        if raw.startswith('http') and '.m3u8' in raw:
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        nid = raw
        if nid.startswith('ai2026:'):
            nid = nid.split(':', 1)[1].strip()
        nid = ''.join([ch for ch in nid if ch.isdigit()])
        if not nid:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        html = _fetch(
            '/index.php/vod/play/id/%s/sid/1/nid/1.html' % nid)
        url = _parse_player_url(html)
        if not url:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        return {'parse': 0, 'playUrl': url, 'url': url, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', b'', {}]

    def isVideoFormat(self, url):
        u = str(url or '').lower().split('?')[0]
        return u.endswith(('.m3u8', '.mp4', '.mkv', '.webm', '.flv', '.ts'))

    def manualVideoCheck(self):
        return True

    def action(self, action, params=None):
        return {'code': 0, 'msg': 'ok'}
