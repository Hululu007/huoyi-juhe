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

try:
    import requests as _requests
except Exception:
    _requests = None

BASE = 'https://wyswspqjtr.click'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

FALLBACK_CATS = [
    ('7', '中文字幕'),
    ('8', '国产传媒'),
    ('9', '日本有码'),
    ('10', '日本无码'),
    ('11', '欧美无码'),
    ('12', '强奸乱伦'),
    ('13', '制服诱惑'),
    ('14', '国产主播'),
    ('15', '激情动漫'),
    ('16', '明星换脸'),
    ('17', '抖阴视频'),
    ('18', '女优明星'),
    ('22', '网曝黑料'),
    ('26', '伦理三级'),
    ('28', 'AV解说'),
    ('31', 'SM调教'),
    ('33', '萝莉少女'),
    ('34', '极品媚黑'),
    ('37', '女同性恋'),
    ('39', '网红头条'),
    ('43', '人妖系列'),
    ('45', '韩国主播'),
    ('47', 'VR视角'),
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
        text = None
        if _requests is not None:
            try:
                resp = _requests.get(url, headers=hdr, timeout=timeout)
                if resp.status_code == 200:
                    text = resp.content.decode('utf-8', 'replace')
            except Exception:
                text = None
        if text is None:
            try:
                req = urllib.request.Request(url, headers=hdr)
                with urllib.request.urlopen(req, timeout=timeout, context=CTX) as resp:
                    if resp.status == 200:
                        data = resp.read()
                        enc = (resp.headers.get('Content-Encoding') or '').lower()
                        if enc == 'gzip' or data[:2] == b'\x1f\x8b':
                            try:
                                data = gzip.decompress(data)
                            except Exception:
                                pass
                        text = data.decode('utf-8', 'replace')
            except Exception:
                text = None
        if text is not None:
            return text
        if attempt < 2:
            try:
                time.sleep(2)
            except Exception:
                pass
    return None


def _fetch(path, referer=None):
    base = _CUR_BASE[0]
    return _http_get(base + path, referer=referer or (base + '/'))


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
        r'<article class="card">.*?<a[^>]*href="/info/id/(\d+)\.html"[^>]*>'
        r'.*?<img[^>]*src="([^"]+)"[^>]*>.*?<h2 class="card-title"[^>]*>(.*?)</h2>',
        re.S)
    seen = set()
    for m in pat.finditer(html):
        vid = m.group(1).strip()
        title = _unescape(m.group(3).strip())
        cover = _fix_url(m.group(2))
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
        nav = html
        i = html.find('<nav class="site-nav"')
        if i >= 0:
            j = html.find('</nav>', i)
            if j > i:
                nav = html[i:j]
        pat = re.compile(r'href="/type/id/(\d+)\.html"[^>]*>([^<]+)</a>')
        seen = set()
        for m in pat.finditer(nav):
            cid = m.group(1).strip()
            name = m.group(2).strip()
            if not name or cid in seen:
                continue
            seen.add(cid)
            cats.append((cid, name))
    ttl = CATS_TTL
    if not cats:
        cats = list(FALLBACK_CATS)
        ttl = 300
    if len(CACHE) > 20:
        CACHE.clear()
    CACHE['cats'] = (_now(), cats, ttl)
    return cats


def _parse_title(html):
    m = re.search(r'<h1[^>]*>(.*?)</h1>', html, re.S)
    if not m:
        return ''
    raw = _unescape(m.group(1).strip())
    suf = ' - 详情页'
    if raw.endswith(suf):
        raw = raw[:-len(suf)]
    return raw.strip()


def _parse_cover(html):
    m = re.search(
        r'<div class="detail-cover">.*?<img[^>]+src="([^"]+)"', html, re.S)
    if m:
        return _fix_url(m.group(1))
    m = re.search(r'<img[^>]+src="(https?://[^"]+)"', html)
    if m:
        return _fix_url(m.group(1))
    return ''


def _parse_synopsis(html):
    m = re.search(
        r'<meta name="description"[^>]*content="([^"]+)"', html)
    if not m:
        return ''
    return _unescape(m.group(1).strip())


def _parse_player_url(html):
    if not html:
        return ''
    m = re.search(r"playUrl\s*=\s*'([^']+)'", html)
    if m:
        return _unescape(m.group(1).strip())
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
        return '4K.AI短剧'

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
            path = '/type/id/%s.html' % tid
        else:
            path = '/type/id/%s/%d.html' % (tid, pg)
        html = _fetch(path)
        items = _parse_cards(html)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        raw = _norm_id(ids)
        nid = ''.join([ch for ch in raw if ch.isdigit()])
        if not nid:
            return _empty_detail(raw)
        html = _fetch('/info/id/%s.html' % nid)
        if not html:
            return _empty_detail(nid)
        title = _parse_title(html)
        if not title:
            return _empty_detail(nid)
        cover = _parse_cover(html)
        synopsis = _parse_synopsis(html)
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
            'vod_play_url': '播放$ai4k:%s' % nid,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        if pg < 1:
            pg = 1
        kw = urllib.parse.quote(str(key).strip())
        html = _fetch('/hunt/%s.html' % kw)
        items = _parse_cards(html)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        if raw.startswith('ai4k:'):
            raw = raw.split(':', 1)[1].strip()
        nid = ''.join([ch for ch in raw if ch.isdigit()])
        play_url = ''
        referer = _CUR_BASE[0] + '/'
        if raw.startswith('http') and '.m3u8' in raw:
            play_url = raw
        elif nid:
            play_page = '/play/id/%s.html' % nid
            html = _fetch(play_page)
            play_url = _parse_player_url(html)
            referer = _CUR_BASE[0] + play_page
        if not play_url:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        header = {'User-Agent': UA, 'Referer': referer}
        return {'parse': 0, 'playUrl': play_url, 'url': play_url, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', b'', {}]

    def isVideoFormat(self, url):
        u = str(url or '').lower().split('?')[0]
        return u.endswith(('.m3u8', '.mp4', '.mkv', '.webm', '.flv', '.ts'))

    def manualVideoCheck(self):
        return True

    def action(self, action, params=None):
        return {'code': 0, 'msg': 'ok'}
