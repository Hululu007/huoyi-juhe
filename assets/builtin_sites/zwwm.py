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

BASE = 'https://zwwmtekr.lol'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

CATS = [
    ('490', '网红主播'),
    ('491', '国产传媒'),
    ('492', '探花系列'),
    ('493', '人妻熟女'),
    ('494', '日本无码'),
    ('495', '美乳巨乳'),
    ('496', '强制侵犯'),
    ('497', '制服诱惑'),
    ('498', '绝色佳人'),
    ('499', '风俗泡泡浴'),
    ('500', '家庭乱伦'),
    ('501', 'AV解说'),
    ('502', '三级电影'),
    ('503', '少女萝莉'),
    ('504', 'SM调教'),
    ('505', '绝顶潮吹'),
    ('506', '魔镜系列'),
    ('507', '时间停止'),
    ('508', '催眠洗脑'),
    ('509', '漫改系列'),
    ('510', '电车痴汉'),
    ('511', '淫欲痴女'),
]

try:
    import requests
    _HAS_REQ = True
except Exception:
    _HAS_REQ = False

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

CARD_RE = re.compile(r'(?s)<li>.*?<a href="/info/id/(\d+)\.html"[^>]*>\s*<img[^>]*src="([^"]+)".*?<h3 class="video-title">.*?<text>(.*?)</text>')
CAT_RE = re.compile(r'href="/type/id/(\d+)\.html"[^>]*>(?:<text>)?([^<]+?)(?:</text>)?</a>')
H1_RE = re.compile(r'(?s)<h1[^>]*>.*?<text>(.*?)</text>')
TITLE_RE = re.compile(r'<title>(.*?)</title>')
COVER_RE = re.compile(r'<img[^>]*src="(https?://[^"]+/upload/vod/[^"]+)"')
DESC_RE = re.compile(r'<meta name="description"[^>]*content="([^"]+)"')
PLAY_RE = re.compile(r"playUrl\s*=\s*'([^']+)'")


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
            text = data.decode('utf-8', 'replace')
            if text.strip():
                return text
        except Exception:
            if attempt < 2:
                time.sleep(2)
    return ''


def _unescape(s):
    if not s:
        return ''
    return _html.unescape(s).strip()


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
        return '中文无码'

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
            url = '%s/type/id/%s.html' % (BASE, tid)
        else:
            url = '%s/type/id/%s/%d.html' % (BASE, tid, pg)
        html = _http_get(url, referer=BASE + '/')
        return _parse_cards(html)

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        items = self._catalog(_norm_id(tid), pg)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        nid = _norm_id(ids).strip().strip('/')
        if nid.startswith('info/id/'):
            nid = nid[len('info/id/'):]
        if nid.endswith('.html'):
            nid = nid[:-5]
        if not nid:
            return {'list': []}
        html = _http_get('%s/info/id/%s.html' % (BASE, nid), referer=BASE + '/')
        if not html:
            return {'list': []}
        m = H1_RE.search(html)
        title = _unescape(m.group(1)) if m else ''
        if title.endswith('详情页'):
            title = title[:-3]
        if not title:
            m = TITLE_RE.search(html)
            if m:
                title = _unescape(m.group(1))
                if title.endswith('-中文无码详情页面'):
                    title = title[:-len('-中文无码详情页面')]
        m = COVER_RE.search(html)
        cover = m.group(1) if m else ''
        m = DESC_RE.search(html)
        synopsis = _unescape(m.group(1)) if m else ''
        play_html = _http_get('%s/play/id/%s.html' % (BASE, nid), referer=BASE + '/')
        m3u8 = ''
        m = PLAY_RE.search(play_html)
        if m:
            m3u8 = m.group(1).strip()
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
            'type_name': '',
            'vod_tag': '',
            'vod_play_from': '在线播放',
            'vod_play_url': '播放$' + m3u8,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        url = '%s/lookup/%s.html' % (BASE, urllib.parse.quote(str(key or '').strip()))
        html = _http_get(url, referer=BASE + '/')
        items = _parse_cards(html)
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
