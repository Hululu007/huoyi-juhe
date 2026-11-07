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


BASE = 'https://5g.guzhuangai8.cc/rukou'
HOST = 'https://5g.guzhuangai8.cc'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

CATS = [
    ('119', '斯卡资源'),
    ('244', '51资源'),
    ('386', '黄瓜资源'),
    ('358', '番茄资源'),
    ('286', '兔兔资源'),
    ('370', '森林资源'),
    ('329', '库库资源'),
    ('127', '制服诱惑'),
    ('390', 'AI短剧'),
]

CARD_RE = re.compile(r'<a href="[^"]*/vod/detail/id/(\d+)\.html" class="group-item[^"]*">\s*<img[^>]*data-original="([^"]+)"[^>]*>\s*<p[^>]*>(.*?)</p>', re.S)
CAT_RE = re.compile(r'href="[^"]*/vod/type/id/(\d+)\.html"[^>]*>([^<]+)</a>')
TITLE_RE = re.compile(r'<p class="group-title">(.*?)</p>')
COVER_RE = re.compile(r'data-original="(https?://[^"]+)"')
DESC_RE = re.compile(r'<meta name="description"[^>]*content="([^"]*)"')
EP_RE = re.compile(r'href="([^"]*/vod/play/id/\d+/sid/1/nid/(\d+)\.html)"')
PLAYER_RE = re.compile(r'player_aaaa=.*?"url":"([^"]+)"', re.S)


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _unescape(s):
    if not s:
        return ''
    return _html.unescape(s).replace('\\/', '/').strip()


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
        time.sleep(2)
    return ''


def _fix_url(raw):
    u = (raw or '').strip()
    if not u:
        return ''
    if u.startswith('http'):
        return u
    if u.startswith('//'):
        return 'https:' + u
    if u.startswith('/'):
        return HOST + u
    return u


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
        name = m.group(2).strip()
        if not name or cid in seen:
            continue
        seen.add(cid)
        out.append((cid, name))
    return out


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


class Spider(BaseSpider):
    def getName(self):
        return '古装AI'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cats(self):
        cats = _parse_categories(_http_get(BASE + '/', referer=BASE + '/'))
        return cats or list(CATS)

    def _catalog(self, tid, pg):
        if pg <= 1:
            url = '%s/index.php/vod/type/id/%s.html' % (BASE, tid)
        else:
            url = '%s/index.php/vod/type/id/%s/page/%s.html' % (BASE, tid, pg)
        return _parse_cards(_http_get(url, referer=BASE + '/'))

    def homeContent(self, filter=''):
        cats = self._cats()
        items = []
        if cats:
            items = self._catalog(cats[0][0], 1)
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in cats],
            'list': items,
        }

    def homeVideoContent(self):
        cats = self._cats()
        items = []
        if cats:
            items = self._catalog(cats[0][0], 1)
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        items = self._catalog(tid, pg)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        nid = _norm_id(ids).strip().lstrip('/')
        if '/vod/detail/id/' in nid:
            nid = nid.rsplit('/vod/detail/id/', 1)[-1]
        nid = nid.lstrip('/')
        if nid.endswith('.html'):
            nid = nid[:-5]
        if not nid:
            return {'list': []}
        html = _http_get('%s/index.php/vod/detail/id/%s.html' % (BASE, nid), referer=BASE + '/')
        if not html:
            return {'list': []}
        tm = TITLE_RE.search(html)
        title = _unescape(tm.group(1)) if tm else ''
        cm = COVER_RE.search(html)
        cover = cm.group(1) if cm else ''
        dm = DESC_RE.search(html)
        synopsis = _unescape(dm.group(1)) if dm else ''
        if synopsis.endswith('-古装AI'):
            synopsis = synopsis[:-len('-古装AI')]
        eps = []
        seen = set()
        pairs = []
        for m in EP_RE.finditer(html):
            n = m.group(2)
            if n in seen:
                continue
            seen.add(n)
            try:
                pairs.append((int(n), m.group(1)))
            except Exception:
                continue
        pairs.sort(key=lambda x: x[0])
        for n, link in pairs:
            eps.append('第%s集$guzhuang:%s' % (n, _fix_url(link)))
        if not title or not eps:
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
            'vod_play_url': '#'.join(eps),
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        url = '%s/index.php/vod/search/wd/%s.html' % (BASE, urllib.parse.quote(key or ''))
        items = _parse_cards(_http_get(url, referer=BASE + '/'))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        if raw.startswith('guzhuang:'):
            raw = raw[len('guzhuang:'):]
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        m3u8 = ''
        if '/vod/play/' in raw:
            html = _http_get(raw, referer=BASE + '/')
            if html:
                m = PLAYER_RE.search(html)
                if m:
                    m3u8 = _unescape(m.group(1))
        elif raw.startswith('http'):
            m3u8 = raw
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
