import base64
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

BASE = 'https://89-ew-e.yunmengv.shop'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

CATS = [
    ('2', '欧美情色'),
    ('6', '精品推荐'),
    ('7', '国产情色'),
    ('8', '日本无码'),
    ('9', 'AV明星'),
    ('10', '中文字幕'),
    ('11', '网红主播'),
    ('12', '成人动漫'),
    ('13', '国模私拍'),
    ('14', '长腿丝袜'),
    ('15', '邻家人妻'),
    ('16', '日韩无码'),
    ('17', '国产精品'),
    ('18', '日韩精品'),
    ('20', '欧美精品'),
    ('21', '制服诱惑'),
    ('22', '强奸乱伦'),
    ('23', '自拍偷拍'),
    ('24', '3P合辑'),
    ('25', '巨乳系列'),
    ('26', '颜射系列'),
    ('27', '口交视频'),
    ('28', '自慰系列'),
    ('29', 'SM重味'),
    ('30', '教师学生'),
    ('31', '大秀视频'),
    ('32', '重口味'),
    ('33', '传媒系列'),
    ('34', '明星系列'),
    ('35', '热门大瓜'),
    ('36', '人妻系列'),
]

try:
    import requests
    _HAS_REQ = True
except Exception:
    _HAS_REQ = False

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

KEY_RE = re.compile(r'window\.__PAGE_KEY="([^"]+)"')
JS_RE = re.compile(r'src="([^"]*?/static/encrypt/[^"]+\.js)"')
ENC_RE = re.compile(r"window\.__PAGE_ENC='([^']+)'")
CAT_RE = re.compile(r'href="/vodtype/(\d+)\.html"[^>]*title="([^"]+)"')
CARD_RE = re.compile(r'(?s)<a href="/voddetail/(\d+)\.html"[^>]*>.*?<img[^>]*src="([^"]+)"[^>]*alt="([^"]+)"')
TITLE_RE = re.compile(r'<title>(.*?)</title>')
COVER_RE = re.compile(r'(?s)<img[^>]*src="(https?://[^"]*?/upload/vod/[^"]+)"')
DESC_RE = re.compile(r'<meta name="description"[^>]*content="([^"]+)"')
GENRE_RE = re.compile(r'在线观看_(.*?)全集_云梦v')
PLAYER_RE = re.compile(r'(?s)player_aaaa=.*?"url":"([^"]+)"')


def _http_get(url, referer=None, timeout=25):
    hdr = {'User-Agent': UA, 'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8', 'Accept-Encoding': 'gzip, deflate'}
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
                time.sleep(2)
    return ''


def _unescape(s):
    if not s:
        return ''
    return _html.unescape(s.replace('\\/', '/')).strip()


def _fix_url(raw):
    u = (raw or '').strip()
    if not u:
        return ''
    if u.startswith('//'):
        return 'https:' + u
    if u.startswith('/'):
        return BASE + u
    return u


def _xor_decrypt(cipher_b64, key):
    try:
        raw = base64.b64decode(cipher_b64.strip())
    except Exception:
        return ''
    if not key:
        return ''
    plain = bytes(b ^ key[i % len(key)] for i, b in enumerate(raw))
    try:
        return plain.decode('utf-8')
    except Exception:
        return plain.decode('utf-8', 'replace')


def _get_page(url):
    shell = _http_get(url, referer=BASE + '/')
    if not shell:
        return ''
    m = KEY_RE.search(shell)
    key_b64 = m.group(1) if m else ''
    try:
        key = base64.b64decode(key_b64.strip())
    except Exception:
        key = b''
    m = JS_RE.search(shell)
    if not m:
        return ''
    js = _http_get(_fix_url(m.group(1)), referer=url)
    m = ENC_RE.search(js)
    if not m:
        return ''
    return _xor_decrypt(m.group(1), key)


def _parse_categories(html):
    out = []
    seen = set()
    for m in CAT_RE.finditer(html or ''):
        cid = m.group(1)
        name = _unescape(m.group(2))
        if not name or cid in seen:
            continue
        seen.add(cid)
        out.append({'type_id': cid, 'type_name': name})
    return out


def _parse_cards(html):
    out = []
    seen = set()
    for m in CARD_RE.finditer(html or ''):
        vid = m.group(1)
        if vid in seen:
            continue
        title = _unescape(m.group(3))
        if not title:
            continue
        seen.add(vid)
        out.append({
            'vod_id': vid,
            'vod_name': title,
            'vod_pic': _fix_url(m.group(2)),
            'vod_remarks': '',
        })
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
        return '云梦在线'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=''):
        html = _get_page(BASE)
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
            url = '%s/vodtype/%s.html' % (BASE, tid)
        else:
            url = '%s/vodtype/%s-%d.html' % (BASE, tid, pg)
        html = _get_page(url)
        return _parse_cards(html)

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        items = self._catalog(_norm_id(tid), pg)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        nid = _norm_id(ids).strip().strip('/')
        if nid.startswith('voddetail/'):
            nid = nid[len('voddetail/'):]
        if nid.endswith('.html'):
            nid = nid[:-5]
        if not nid:
            return {'list': []}
        html = _get_page('%s/voddetail/%s.html' % (BASE, nid))
        if not html:
            return {'list': []}
        m = TITLE_RE.search(html)
        title = _unescape(m.group(1)) if m else ''
        if '免费高清在线观看' in title:
            title = title.split('免费高清在线观看')[0].strip().strip('《》')
        m = COVER_RE.search(html)
        cover = m.group(1).strip() if m else ''
        m = DESC_RE.search(html)
        synopsis = _unescape(m.group(1)) if m else ''
        m = GENRE_RE.search(html)
        genre = _unescape(m.group(1)) if m else ''
        if not title:
            return {'list': []}
        play_url = '%s/vodplay/%s-1-1.html' % (BASE, nid)
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
            'vod_play_url': '播放$' + play_url,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        url = '%s/vodsearch/-------------.html?wd=%s' % (BASE, urllib.parse.quote(str(key or '').strip()))
        html = _get_page(url)
        items = _parse_cards(html)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        if raw.endswith('.m3u8') or raw.endswith('.mp4'):
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        url = raw
        if url.startswith('http'):
            pass
        elif url.startswith('/'):
            url = BASE + url
        else:
            url = BASE + '/vodplay/' + url.lstrip('vodplay/').lstrip('/')
            if not url.endswith('.html'):
                url += '.html'
        html = _get_page(url)
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
