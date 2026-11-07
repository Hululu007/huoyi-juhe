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


BASES = ['https://wap.snq2.cc', 'https://wap.snq3.cc', 'https://5g.snq3.cc']
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

CATS = [
    ('386', '黄瓜资源'),
    ('358', '熟女资源'),
    ('244', '55资源'),
    ('119', '不卡资源'),
    ('286', '兔儿资源'),
    ('370', '森林资源'),
    ('329', '库库资源'),
]


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _fetch_once(url, timeout=25):
    h = {'User-Agent': UA, 'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8', 'Accept-Language': 'zh-CN,zh;q=0.9', 'Accept-Encoding': 'gzip, deflate'}
    if _HAS_REQ:
        try:
            r = requests.get(url, headers=h, timeout=timeout)
            if r.status_code == 200 and r.text:
                return r.text
        except Exception:
            pass
    req = urllib.request.Request(url, headers=h)
    with urllib.request.urlopen(req, timeout=timeout, context=_ctx()) as resp:
        if resp.status != 200:
            raise Exception('HTTP %s' % resp.status)
        data = resp.read()
        enc = (resp.headers.get('Content-Encoding') or '').lower()
        if enc == 'gzip' or data[:2] == b'\x1f\x8b':
            try:
                data = gzip.decompress(data)
            except Exception:
                pass
        return data.decode('utf-8', 'replace')


def _http_get(path, timeout=25):
    last = ''
    for base in BASES:
        url = base + path
        for _ in range(2):
            try:
                return _fetch_once(url, timeout=timeout)
            except urllib.error.HTTPError as e:
                try:
                    return e.read().decode('utf-8', 'ignore')
                except http.client.IncompleteRead as ie:
                    return ie.partial.decode('utf-8', 'ignore')
            except Exception as e:
                last = str(e)
                time.sleep(1)
    return ''


def _fix_url(raw):
    u = (raw or '').strip()
    if not u:
        return ''
    if u.startswith('//'):
        return 'https:' + u
    if u.startswith('/'):
        return BASES[0] + u
    return u


def _unescape(s):
    if not s:
        return ''
    return _html.unescape(s).replace('\\/', '/')


def _clean(t):
    if not t:
        return ''
    t = re.sub(r'<[^>]+>', ' ', t)
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


def _cards(html):
    out = []
    seen = set()
    pat = re.compile(r'<a class="qx" href="/a/index\.php/vod/detail/id/(\d+)\.html".*?<img[^>]+data-original="([^"]+)"[^>]*>.*?<div class="listitem-info">\s*(.*?)\s*</div>', re.S)
    for m in pat.finditer(html or ''):
        vid = m.group(1)
        if vid in seen:
            continue
        seen.add(vid)
        title = _clean(_unescape(m.group(3)))
        if not title:
            continue
        out.append({'vod_id': vid, 'vod_name': title, 'vod_pic': _fix_url(m.group(2)), 'vod_remarks': ''})
    return out


def _live_cats(html):
    out = []
    seen = set()
    pat = re.compile(r'<a href="/a/index\.php/vod/type/id/(\d+)\.html" class="now"[^>]*>([^<]+)</a>')
    for m in pat.finditer(html or ''):
        cid, name = m.group(1), m.group(2).strip()
        if not name or cid in seen:
            continue
        seen.add(cid)
        out.append((cid, name))
    return out


def _player_url(play_path):
    html = _http_get(play_path)
    if not html:
        return ''
    m = re.search(r'player_aaaa=.*?"url":"([^"]+)"', html, re.S)
    return _unescape(m.group(1)) if m else ''


class Spider(BaseSpider):
    def getName(self):
        return '熟女群'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cats(self):
        html = _http_get('/a/')
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
            path = '/a/index.php/vod/type/id/%s.html' % tid
        else:
            path = '/a/index.php/vod/type/id/%s/page/%s.html' % (tid, pg)
        html = _http_get(path)
        items = _cards(html)
        nxt = '/a/index.php/vod/type/id/%s/page/%s.html' % (tid, pg + 1)
        has_more = bool(items) and nxt in (html or '')
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        vid = _norm_id(ids).strip().lstrip('/')
        if not vid:
            return {'list': []}
        html = _http_get('/a/index.php/vod/detail/id/%s.html' % vid)
        if not html:
            return {'list': []}
        title = ''
        hm = re.search(r'<h1[^>]*>(.*?)</h1>', html, re.S)
        if hm:
            title = _clean(_unescape(hm.group(1))).split('<')[0].strip()
        cover = ''
        cm = re.search(r'<img src="(https?://[^"]+)"', html)
        if cm:
            cover = _fix_url(cm.group(1))
        synopsis = ''
        dm = re.search(r'<meta name="description"[^>]*content="([^"]+)"', html)
        if dm:
            synopsis = _unescape(dm.group(1).strip())
        eps = []
        seen = set()
        epat = re.compile(r'<a[^>]*href="(/a/index\.php/vod/play/id/\d+/sid/\d+/nid/\d+\.html)"[^>]*>([^<]*)</a>')
        for m in epat.finditer(html):
            href = m.group(1)
            if href in seen:
                continue
            seen.add(href)
            name = m.group(2).strip()
            if not name or name == '立即播放':
                name = '第1集'
            eps.append('%s$%s' % (name, _fix_url(href)))
        if not title or not eps:
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
            'vod_play_url': '#'.join(eps),
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        enc = urllib.parse.quote(str(key or ''), safe='')
        html = _http_get('/a/index.php/vod/search/wd/%s.html' % enc)
        items = _cards(html)
        return {'list': items, 'page': _norm_pg(pg), 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        header = {'User-Agent': UA, 'Referer': BASES[0] + '/'}
        url = raw if raw.startswith('http') else _fix_url(raw)
        if '/vod/play/' not in url:
            if url.startswith('http') and url.endswith('.m3u8'):
                return {'parse': 0, 'playUrl': url, 'url': url, 'header': header}
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        pos = url.find('/a/index.php')
        path = url[pos:] if pos >= 0 else url
        m3u8 = _player_url(path)
        if not m3u8:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        header['Referer'] = url
        return {'parse': 0, 'playUrl': m3u8, 'url': m3u8, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', b'', {}]

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
