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


BASES = ['https://wap.heitaoduanju7.cc', 'https://hei.heitaoduanju8.cc']
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

CATS = [
    ('386', '黄瓜资源'),
    ('358', '番号资源'),
    ('119', '不卡资源'),
    ('421', '黑桃资源'),
    ('286', '玉兔资源'),
    ('329', '裤子资源'),
    ('370', '森林资源'),
    ('244', '163资源'),
]

CARD_RE = re.compile(r'<a class="vod-card-item" href="/a/index\.php/vod/detail/id/(\d+)\.html".*?<div class="vod-card-name">(.*?)</div>.*?<span class="vod-card-remarks">([^<]*)</span>', re.S)
COVER_RE = re.compile(r'data-original="([^"]+)"')
CAT_RE = re.compile(r'<a href="/a/index\.php/vod/type/id/(\d+)\.html" class="cat-icon-item"[^>]*>.*?<span[^>]*>([^<]+)</span>', re.S)
H1_RE = re.compile(r'<h1[^>]*>(.*?)</h1>', re.S)
MAIN_IMG_RE = re.compile(r'<img class="main-img" src="([^"]+)"')
DESC_RE = re.compile(r'<meta name="description"[^>]*content="([^"]+)"')
EP_RE = re.compile(r'<a[^>]*href="(/a/index\.php/vod/play/id/\d+/sid/\d+/nid/\d+\.html)"[^>]*>([^<]+)</a>')
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
    for _ in range(2):
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


def _get_text(path):
    for base in BASES:
        html = _http_get(base + path, referer=base + '/')
        if html:
            return html, base
    return '', BASES[0]


def _fix_url(raw, base=None):
    u = (raw or '').strip()
    if not u:
        return ''
    if u.startswith('//'):
        return 'https:' + u
    if u.startswith('/'):
        return (base or BASES[0]) + u
    return u


def _parse_cards(html, base):
    out = []
    seen = set()
    for m in CARD_RE.finditer(html or ''):
        vid = m.group(1).strip()
        if not vid or vid in seen:
            continue
        title = _unescape(m.group(2))
        if not title:
            continue
        seen.add(vid)
        seg = m.group(0)
        cm = COVER_RE.search(seg)
        cover = _fix_url(cm.group(1), base) if cm else ''
        out.append({
            'vod_id': vid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_remarks': m.group(3).strip(),
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


def _parse_detail_cover(html, base):
    m = MAIN_IMG_RE.search(html or '')
    if m:
        return _fix_url(m.group(1), base)
    m = COVER_RE.search(html or '')
    if m:
        return _fix_url(m.group(1), base)
    return ''


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
        return '黑桃短剧'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cats(self):
        html, _base = _get_text('/a/')
        cats = _parse_categories(html)
        return cats or list(CATS)

    def _catalog(self, tid, pg):
        if pg <= 1:
            path = '/a/index.php/vod/type/id/%s.html' % tid
        else:
            path = '/a/index.php/vod/type/id/%s/page/%s.html' % (tid, pg)
        html, base = _get_text(path)
        return _parse_cards(html, base)

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
        if not nid:
            return {'list': []}
        html, base = _get_text('/a/index.php/vod/detail/id/%s.html' % nid)
        if not html:
            return {'list': []}
        hm = H1_RE.search(html)
        title = _unescape(hm.group(1)) if hm else ''
        if '<' in title:
            title = title[:title.find('<')].strip()
        if not title:
            return {'list': []}
        cover = _parse_detail_cover(html, base)
        dm = DESC_RE.search(html)
        synopsis = _unescape(dm.group(1)) if dm else ''
        eps = []
        seen = set()
        for m in EP_RE.finditer(html):
            href = m.group(1).strip()
            name = m.group(2).strip()
            if name == '▶ 立即播放' or href in seen:
                continue
            seen.add(href)
            eps.append('%s$heitaoduanju:%s' % (name, _fix_url(href, base)))
        if not eps:
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
        q = urllib.parse.quote(key or '')
        html, base = _get_text('/a/index.php/vod/search/wd/%s.html' % q)
        items = _parse_cards(html, base)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        if raw.startswith('heitaoduanju:'):
            raw = raw[len('heitaoduanju:'):]
        url = _fix_url(raw)
        header = {'User-Agent': UA, 'Referer': BASES[0] + '/'}
        m3u8 = ''
        if '/vod/play/' in url:
            if '/a/index.php' in url:
                path = url[url.find('/a/index.php'):]
            else:
                path = url
            html, _base = _get_text(path)
            if html:
                m = PLAYER_RE.search(html)
                if m:
                    m3u8 = _unescape(m.group(1))
        elif url.startswith('http') and url.endswith('.m3u8'):
            m3u8 = url
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
