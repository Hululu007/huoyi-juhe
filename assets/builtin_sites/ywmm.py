import gzip
import html as _html
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

FALLBACK_BASE = 'https://cc1k1k0k5k.18ywmmresi.buzz'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

CATS = [
    ('48', '桃花资源'),
    ('50', '华语AV'),
    ('52', '欧美'),
    ('441', '糖心Vlog'),
]

try:
    import requests
    _HAS_REQ = True
except Exception:
    _HAS_REQ = False

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

_HOST_CACHE = {'base': '', 'ts': 0}

CAT_RE = re.compile(r'href="/vodtype/(\d+)/"[^>]*>([^<]+)</a>')
CARD_RE = re.compile(r'(?s)/voddetail/(\d+)/"[^>]*>.*?<img[^>]*src="([^"]+)"[^>]*>.*?<p>([^<]+)</p>')
H1_RE = re.compile(r'(?s)<h1[^>]*>(.*?)</h1>')
OGIMG_RE = re.compile(r'<meta property="og:image"[^>]*content="([^"]+)"')
UPLOAD_IMG_RE = re.compile(r'(?s)<img[^>]*(?:data-original|src)="(https?://[^"]*upload/vod[^"]+)"')
DESC_RE = re.compile(r'<meta name="description"[^>]*content="([^"]*)"')
PLAYER_RE = re.compile(r'(?s)player_data=.*?"url":"([^"]+)"')


def _http_get(url, referer=None, timeout=25):
    hdr = {
        'User-Agent': UA,
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Encoding': 'gzip, deflate',
    }
    if referer:
        hdr['Referer'] = referer
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
            return data.decode('utf-8', 'replace')
        except Exception:
            if attempt < 2:
                time.sleep(1)
    return ''


def _http_status(url, timeout=15):
    if _HAS_REQ:
        try:
            r = requests.get(url, headers={'User-Agent': UA}, timeout=timeout)
            return r.status_code == 200
        except Exception:
            pass
    try:
        req = urllib.request.Request(url, headers={'User-Agent': UA})
        with urllib.request.urlopen(req, timeout=timeout, context=CTX) as resp:
            return resp.status == 200
    except Exception:
        return False


def _unescape(s):
    if not s:
        return ''
    return _html.unescape(s.replace('\\/', '/')).strip()


def _clean(t):
    if not t:
        return ''
    t = re.sub(r'<[^>]+>', ' ', t)
    return _html.unescape(re.sub(r'\s+', ' ', t)).strip()


def _date_code():
    secs = int(time.time()) + 3 * 3600
    tm = time.gmtime(secs)
    two = lambda n: '%dk%dk' % (n // 10, n % 10)
    return two(tm.tm_mon) + two(tm.tm_mday)


def _resolve_base():
    now = time.time()
    if _HOST_CACHE['base'] and now - _HOST_CACHE['ts'] < 3600:
        return _HOST_CACHE['base']
    code = _date_code()
    for prefix in ('aa', 'bb', 'cc'):
        base = 'https://%s%s.18ywmmresi.buzz' % (prefix, code)
        if _http_status(base + '/vod/'):
            _HOST_CACHE['base'] = base
            _HOST_CACHE['ts'] = now
            return base
    _HOST_CACHE['base'] = FALLBACK_BASE
    _HOST_CACHE['ts'] = now
    return FALLBACK_BASE


def _parse_categories(html):
    out = []
    seen = set()
    for m in CAT_RE.finditer(html or ''):
        cid = m.group(1)
        name = _unescape(m.group(2))
        if not name or name == '更多' or cid in seen:
            continue
        seen.add(cid)
        out.append({'type_id': cid, 'type_name': name})
    return out


def _parse_cards(html):
    out = []
    seen = set()
    for m in CARD_RE.finditer(html or ''):
        vid = m.group(1).strip()
        if not vid or vid in seen:
            continue
        title = _unescape(m.group(3))
        if not title:
            continue
        seen.add(vid)
        out.append({
            'vod_id': vid,
            'vod_name': title,
            'vod_pic': m.group(2).strip(),
            'vod_remarks': '',
        })
    return out


def _parse_cover(html):
    m = OGIMG_RE.search(html or '')
    if m:
        cover = m.group(1).strip()
        if cover and not cover.endswith('favicon.ico'):
            return cover
    m = UPLOAD_IMG_RE.search(html or '')
    if m:
        return m.group(1).strip()
    return ''


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
        return '高清开苞处女'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=''):
        base = _resolve_base()
        html = _http_get(base + '/vod/', referer=base + '/')
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
        base = _resolve_base()
        if pg <= 1:
            url = '%s/vodtype/%s/' % (base, tid)
        else:
            url = '%s/vodtype/%s-%d/' % (base, tid, pg)
        html = _http_get(url, referer=base + '/')
        return _parse_cards(html)

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        items = self._catalog(_norm_id(tid), pg)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        vid = _norm_id(ids).strip()
        if not vid:
            return {'list': []}
        base = _resolve_base()
        html = _http_get('%s/voddetail/%s/' % (base, vid), referer=base + '/')
        if not html:
            return {'list': []}
        m = H1_RE.search(html)
        title = _clean(m.group(1)) if m else ''
        cover = _parse_cover(html)
        m = DESC_RE.search(html)
        synopsis = _unescape(m.group(1)) if m else ''
        play_html = _http_get('%s/vodplay/%s-1-1/' % (base, vid), referer=base + '/')
        m2 = PLAYER_RE.search(play_html)
        m3u8 = _unescape(m2.group(1)) if m2 else ''
        if not title or not m3u8:
            return {'list': []}
        return {'list': [{
            'vod_id': vid,
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
            'vod_play_url': '播放$' + m3u8,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        base = _resolve_base()
        enc = urllib.parse.quote(str(key or '').strip())
        url = '%s/vodsearch/%s-------------.html' % (base, enc)
        html = _http_get(url, referer=base + '/')
        items = _parse_cards(html)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        header = {'User-Agent': UA}
        if raw.startswith('http'):
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        vid = raw.strip()
        if not vid or not vid.isdigit():
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        base = _resolve_base()
        html = _http_get('%s/vodplay/%s-1-1/' % (base, vid), referer=base + '/')
        m = PLAYER_RE.search(html)
        m3u8 = _unescape(m.group(1)) if m else ''
        if not m3u8:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        return {'parse': 0, 'playUrl': m3u8, 'url': m3u8, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', b'', {}]

    def isVideoFormat(self, url):
        u = (url or '').lower()
        return u.endswith('.m3u8') or u.endswith('.mp4') or '.m3u8?' in u or '.mp4?' in u

    def manualVideoCheck(self):
        return False

    def action(self, action, params=None):
        return None
