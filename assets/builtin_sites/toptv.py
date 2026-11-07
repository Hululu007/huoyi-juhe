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
import re
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

try:
    import requests
    _HAS_REQ = True
except Exception:
    _HAS_REQ = False


BASE = 'https://toptv1504.lol'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

CATS = [
    ('1', '国产自拍'),
    ('2', '国产传媒'),
    ('3', '探花系列'),
    ('4', '人妻熟女'),
    ('5', '日本无码'),
    ('6', '美乳巨乳'),
    ('7', '强制侵犯'),
    ('8', '制服诱惑'),
    ('9', '绝色佳人'),
    ('10', '家庭乱伦'),
    ('11', '绝顶潮吹'),
    ('12', '网红主播'),
]


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _http_get(url, referer=None, timeout=25):
    h = {'User-Agent': UA, 'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8', 'Accept-Language': 'zh-CN,zh;q=0.9', 'Accept-Encoding': 'gzip, deflate'}
    if referer:
        h['Referer'] = referer
    for _ in range(3):
        if _HAS_REQ:
            try:
                r = requests.get(url, headers=h, timeout=timeout)
                if r.status_code == 200 and r.text:
                    return r.text
            except Exception:
                pass
        try:
            req = urllib.request.Request(url, headers=h)
            with urllib.request.urlopen(req, timeout=timeout, context=_ctx()) as resp:
                data = resp.read()
                enc = (resp.headers.get('Content-Encoding') or '').lower()
                if enc == 'gzip' or data[:2] == b'\x1f\x8b':
                    try:
                        data = gzip.decompress(data)
                    except Exception:
                        pass
                return data.decode('utf-8', 'replace')
        except urllib.error.HTTPError as e:
            try:
                return e.read().decode('utf-8', 'ignore')
            except http.client.IncompleteRead as ie:
                return ie.partial.decode('utf-8', 'ignore')
        except Exception:
            pass
        time.sleep(1)
    return ''


def _fix_url(raw):
    u = (raw or '').strip()
    if not u:
        return ''
    if u.startswith('//'):
        return 'https:' + u
    if u.startswith('/'):
        return BASE + u
    return u


def _unescape(s):
    if not s:
        return ''
    return _html.unescape(s).replace('\\/', '/')


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


def _cards(html):
    out = []
    seen = set()
    pat = re.compile(r'<a[^>]+href="/index\.php/vod/detail/id/(\d+)\.html"[^>]*>.*?<img[^>]*alt="([^"]+)"[^>]*data-original="([^"]+)"', re.S)
    for m in pat.finditer(html or ''):
        vid = m.group(1)
        if vid in seen:
            continue
        seen.add(vid)
        title = _unescape(m.group(2).strip())
        if not title:
            continue
        out.append({'vod_id': vid, 'vod_name': title, 'vod_pic': _fix_url(m.group(3)), 'vod_remarks': ''})
    return out


def _live_cats(html):
    out = []
    seen = set()
    pat = re.compile(r'href="/index\.php/vod/type/id/(\d+)\.html" title="([^"]+)"')
    for m in pat.finditer(html or ''):
        cid, name = m.group(1), m.group(2).strip()
        if not name or cid in seen:
            continue
        seen.add(cid)
        out.append((cid, name))
    return out


def _player_url(play_html):
    m = re.search(r'player_aaaa=.*?"url":"([^"]+)"', play_html or '', re.S)
    return _unescape(m.group(1)) if m else ''


class Spider(BaseSpider):
    def getName(self):
        return 'TOPTV'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cats(self):
        html = _http_get(BASE)
        live = _live_cats(html) if html else []
        return live or list(CATS)

    def homeContent(self, filter=''):
        cats = self._cats()
        items = []
        try:
            items = self.categoryContent(cats[0][0], 1).get('list') or []
        except Exception:
            items = []
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in cats],
            'list': items,
        }

    def homeVideoContent(self):
        try:
            items = self.categoryContent(self._cats()[0][0], 1).get('list') or []
        except Exception:
            items = []
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        if pg <= 1:
            url = '%s/index.php/vod/type/id/%s/' % (BASE, tid)
        else:
            url = '%s/index.php/vod/type/id/%s/page/%s.html' % (BASE, tid, pg)
        html = _http_get(url, referer=BASE + '/')
        items = _cards(html)
        nxt = '/index.php/vod/type/id/%s/page/%s.html' % (tid, pg + 1)
        has_more = bool(items) and nxt in (html or '')
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        raw = _norm_id(ids).strip().lstrip('/')
        vid = raw
        if vid.startswith('index.php/vod/detail/id/'):
            vid = vid[len('index.php/vod/detail/id/'):]
        vid = vid.rstrip('.html')
        vid = re.sub(r'\.html$', '', vid)
        if not vid:
            return {'list': []}
        html = _http_get('%s/index.php/vod/detail/id/%s.html' % (BASE, vid), referer=BASE + '/')
        if not html:
            return {'list': []}
        title = ''
        hm = re.search(r'<h1[^>]*>(.*?)</h1>', html, re.S)
        if hm:
            title = _unescape(hm.group(1).strip())
            if title.startswith('资源名称：'):
                title = title[len('资源名称：'):].strip()
        cover = ''
        cm = re.search(r'<img[^>]+src="([^"]*/upload/vod/[^"]+)"', html)
        if cm:
            cover = _fix_url(cm.group(1))
        synopsis = ''
        dm = re.search(r'<meta name="description"[^>]*content="([^"]+)"', html)
        if dm:
            synopsis = _unescape(dm.group(1).strip())
        play_path = ''
        pm = re.search(r'href="(/index\.php/vod/play/id/\d+/sid/1/nid/1\.html)"', html)
        if pm:
            play_path = pm.group(1)
        if not title or not play_path:
            return {'list': []}
        play_html = _http_get(BASE + play_path, referer='%s/index.php/vod/detail/id/%s.html' % (BASE, vid))
        m3u8 = _player_url(play_html)
        if not m3u8:
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
            'vod_play_url': '播放$%s' % m3u8,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        url = '%s/index.php/vod/search.html?wd=%s' % (BASE, urllib.parse.quote(str(key or '')))
        html = _http_get(url, referer=BASE + '/')
        items = _cards(html)
        return {'list': items, 'page': _norm_pg(pg), 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        if raw.startswith('http'):
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', b'', {}]

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
