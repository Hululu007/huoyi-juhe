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

BASE = 'https://yiren234.cc'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

CATS = [
    ('14', 'AI Shortplay'),
    ('13', 'Wanderer.'),
    ('12', "I don't know."),
    ('11', 'AV explains.'),
    ('10', 'JAV Blacks Temptation'),
    ('9', 'Chinese subtitle for JAV'),
    ('8', 'Cavalry crack.'),
    ('7', 'Comics.'),
    ('6', 'America and America'),
    ('5', 'Domestic video'),
    ('4', 'Japanese Codeless'),
    ('3', 'Subtitles in Chinese'),
    ('2', 'Japan has codes.'),
    ('1', 'Chinese subtitles.'),
]

try:
    import requests
    _HAS_REQ = True
except Exception:
    _HAS_REQ = False

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

CARD_RE = re.compile(r'(?s)<a class="card" href="/video/(\d+)" title="([^"]+)">.*?<img src="([^"]+)"')
DUR_RE = re.compile(r'<span class="card-status">([^<]+)</span>')
CAT_RE = re.compile(r'href="/latest\?category=(\d+)"[^>]*>([^<]{1,40})<')
LD_RE = re.compile(r'(?s)<script type="application/ld\+json">(.*?)</script>')


def _http_get(url, referer=None, timeout=25):
    hdr = {
        'User-Agent': UA,
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
        'Referer': referer or (BASE + '/'),
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
        vid = m.group(1)
        if vid in seen:
            continue
        title = _unescape(m.group(2))
        if not title:
            continue
        seen.add(vid)
        cover = m.group(3).strip()
        tail = html[m.end():]
        window = tail[:2000]
        dm = DUR_RE.search(window)
        remark = dm.group(1).strip() if dm else ''
        out.append({
            'vod_id': vid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_remarks': remark,
        })
    return out


def _parse_categories(html):
    out = []
    seen = set()
    for m in CAT_RE.finditer(html or ''):
        cid = m.group(1)
        name = _unescape(m.group(2))
        if not name or name.startswith('All videos') or cid in seen:
            continue
        seen.add(cid)
        out.append({'type_id': cid, 'type_name': name})
    return out


def _vo_field(vo, key):
    if not isinstance(vo, dict):
        return ''
    v = vo.get(key)
    if isinstance(v, str):
        return v.strip()
    if isinstance(v, list) and v and isinstance(v[0], str):
        return v[0].strip()
    return ''


def _parse_video_object(html):
    for m in LD_RE.finditer(html or ''):
        try:
            v = json.loads(m.group(1))
        except Exception:
            continue
        if isinstance(v, dict) and v.get('@type') == 'VideoObject':
            return v
    return None


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
        return '伊人AV'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=''):
        html = _http_get(BASE + '/categories', referer=BASE + '/')
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
        pg = pg if pg >= 1 else 1
        url = '%s/latest?%s' % (BASE, urllib.parse.urlencode({'category': tid, 'page': str(pg)}))
        html = _http_get(url, referer=BASE + '/')
        return _parse_cards(html)

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        items = self._catalog(_norm_id(tid), pg)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        vid = _norm_id(ids).strip()
        vid = vid[len('/video/'):] if vid.startswith('/video/') else vid
        vid = vid.rstrip('/')
        if not vid:
            return {'list': []}
        html = _http_get('%s/video/%s' % (BASE, vid), referer=BASE + '/')
        vo = _parse_video_object(html)
        if not vo:
            return {'list': []}
        title = _vo_field(vo, 'name')
        stream = _vo_field(vo, 'contentUrl')
        if not title or not stream:
            return {'list': []}
        return {'list': [{
            'vod_id': vid,
            'vod_name': title,
            'vod_pic': _vo_field(vo, 'thumbnailUrl'),
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': '',
            'vod_year': '',
            'vod_area': '',
            'vod_content': _vo_field(vo, 'description'),
            'type_name': '',
            'vod_tag': _vo_field(vo, 'keywords'),
            'vod_play_from': '在线播放',
            'vod_play_url': '播放$' + stream,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        url = '%s/search?%s' % (BASE, urllib.parse.urlencode({'q': str(key or '')}))
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
