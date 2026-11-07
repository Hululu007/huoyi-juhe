import gzip
import html as _html
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

BASE = 'https://xksp1359.lol'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

CATS = [
    ('75', '国产视频'),
    ('88', '日韩AV'),
    ('94', '蓝光超清'),
    ('99', '欧美视频'),
    ('103', '动漫精选'),
]

try:
    import requests
    _HAS_REQ = True
except Exception:
    _HAS_REQ = False

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

CAT_RE = re.compile(r'(?s)<a class="nav-link[^"]*"[^>]*href="/index\.php/vod/type/id/(\d+)\.html"[^>]*>(.*?)</a>')
CARD_RE = re.compile(r'(?s)<a href="/index\.php/vod/detail/id/(\d+)\.html" title="([^"]+)"[^>]*>.*?<img[^>]*data-src="([^"]+)"')
SEARCH_RE = re.compile(r'(?s)<a href="/index\.php/vod/play/id/(\d+)/sid/1/nid/1\.html" title="立刻播放([^"]+)"[^>]*>.*?<img[^>]*data-src="([^"]+)"')
PLAYER_RE = re.compile(r'(?s)var player_aaaa=(\{.*?\})\s*</script>')
H1_RE = re.compile(r'(?s)<h1[^>]*>(.*?)</h1>')
COVER_RE = re.compile(r'data-src="([^"]+)"')
DESC_RE = re.compile(r'<meta name="description"[^>]*content="([^"]+)"')


def _http_get(url, referer=None, timeout=25):
    hdr = {
        'User-Agent': UA,
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Referer': referer or BASE,
        'Accept-Encoding': 'gzip, deflate',
    }
    if _HAS_REQ:
        try:
            r = requests.get(url, headers=hdr, timeout=timeout)
            if r.status_code == 200 and r.text and r.text.strip():
                return r.text
        except Exception:
            pass
    for attempt in range(3):
        try:
            req = urllib.request.Request(url, headers=hdr)
            with urllib.request.urlopen(req, timeout=timeout, context=CTX) as resp:
                data = resp.read()
                enc = (resp.headers.get('Content-Encoding') or '').lower()
            if enc == 'gzip' or data[:2] == b'\x1f\x8b':
                try:
                    data = gzip.decompress(data)
                except Exception:
                    pass
            text = data.decode('utf-8', 'replace')
            if text.strip():
                return text
        except Exception:
            if attempt < 2:
                time.sleep(1)
    return ''


def _unescape(s):
    if not s:
        return ''
    return _html.unescape(s.replace('\\/', '/')).strip()


def _clean(t):
    if not t:
        return ''
    t = re.sub(r'<[^>]+>', ' ', t)
    return _html.unescape(re.sub(r'\s+', ' ', t)).strip()


def _fix_url(raw):
    u = (raw or '').strip()
    if not u:
        return ''
    if u.startswith('//'):
        return 'https:' + u
    if u.startswith('/'):
        return BASE + u
    return u


def _parse_cards(html, pattern):
    out = []
    seen = set()
    for m in pattern.finditer(html or ''):
        vid = m.group(1).strip()
        if not vid or vid in seen:
            continue
        title = _unescape(m.group(2))
        cover = _fix_url(m.group(3))
        if not title or not cover:
            continue
        seen.add(vid)
        out.append({
            'vod_id': vid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_remarks': '',
        })
    return out


def _parse_categories(html):
    out = []
    seen = set()
    for m in CAT_RE.finditer(html or ''):
        cid = m.group(1)
        name = _clean(m.group(2))
        if not name or cid in seen:
            continue
        seen.add(cid)
        out.append({'type_id': cid, 'type_name': name})
    return out


def _norm_id(ids):
    if isinstance(ids, (list, tuple)):
        return str(ids[0]) if ids else ''
    return str(ids or '')


def _norm_pg(pg):
    try:
        pg = int(pg)
    except Exception:
        pg = 1
    return pg if pg >= 1 else 1


class Spider(BaseSpider):

    def getName(self):
        return '星空福利视频'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=''):
        html = _http_get(BASE, referer=BASE + '/')
        cats = _parse_categories(html)
        if not cats:
            cats = [{'type_id': tid, 'type_name': name} for tid, name in CATS]
        items = []
        if cats:
            items = self._catalog(cats[0]['type_id'], 1)
        return {'class': cats, 'filters': {}, 'list': items}

    def homeVideoContent(self):
        items = self._catalog(CATS[0][0], 1)
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def _catalog(self, tid, pg):
        if pg <= 1:
            url = '%s/index.php/vod/show/id/%s.html' % (BASE, tid)
        else:
            url = '%s/index.php/vod/show/id/%s/page/%d.html' % (BASE, tid, pg)
        html = _http_get(url, referer=BASE + '/')
        return _parse_cards(html, CARD_RE)

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        tid = _norm_id(tid)
        items = self._catalog(tid, pg)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        nid = _norm_id(ids).strip().strip('/')
        if nid.startswith('index.php/vod/detail/id/'):
            nid = nid[len('index.php/vod/detail/id/'):]
        nid = nid.split('/')[0]
        if not nid:
            return {'list': []}
        html = _http_get('%s/index.php/vod/detail/id/%s.html' % (BASE, nid), referer=BASE + '/')
        if not html:
            return {'list': []}
        m = H1_RE.search(html)
        title = _clean(m.group(1)) if m else ''
        m = COVER_RE.search(html)
        cover = _fix_url(m.group(1)) if m else ''
        m = DESC_RE.search(html)
        synopsis = _unescape(m.group(1)) if m else ''
        play_html = _http_get('%s/index.php/vod/play/id/%s/sid/1/nid/1.html' % (BASE, nid), referer=BASE + '/')
        m3u8 = ''
        genre = ''
        m = PLAYER_RE.search(play_html)
        if m:
            try:
                player = json.loads(m.group(1))
                m3u8 = _unescape(player.get('url') or '')
                vd = player.get('vod_data') or {}
                if isinstance(vd, dict):
                    genre = str(vd.get('vod_class') or '')
            except Exception:
                pass
        if not title or not m3u8:
            return {'list': []}
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
            'type_name': genre,
            'vod_tag': genre,
            'vod_play_from': '在线播放',
            'vod_play_url': '播放$' + m3u8,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        url = '%s/index.php/vod/search.html?wd=%s' % (BASE, urllib.parse.quote(str(key or '').strip()))
        html = _http_get(url, referer=BASE + '/')
        items = _parse_cards(html, SEARCH_RE)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        if raw.startswith('http'):
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}

    def localProxy(self, param):
        return [404, 'text/plain', b'', {}]

    def isVideoFormat(self, url):
        u = (url or '').lower()
        return u.endswith('.m3u8') or u.endswith('.mp4') or '.m3u8?' in u or '.mp4?' in u

    def manualVideoCheck(self):
        return False

    def action(self, action, params=None):
        return None
