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

BASE = 'https://klxq1141.lol'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

CATS = [
    ('20', '国产视频'),
    ('21', '中文字幕'),
    ('22', '国产传媒'),
    ('23', '日本有码'),
    ('24', '日本无码'),
    ('25', '欧美无码'),
    ('26', '强奸乱伦'),
    ('27', '制服诱惑'),
    ('28', '国产主播'),
    ('29', '激情动漫'),
    ('30', '明星换脸'),
    ('31', '抖阴视频'),
    ('32', '女优明星'),
    ('33', 'AV解说'),
    ('34', 'SM调教'),
    ('35', '萝莉少女'),
    ('36', '极品媚黑'),
    ('37', '女同性恋'),
    ('38', '网红头条'),
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
            except Exception:
                pass
        except Exception:
            pass
        time.sleep(1)
    return ''


def _clean(t):
    if not t:
        return ''
    t = re.sub(r'<[^>]+>', ' ', t)
    return _html.unescape(re.sub(r'\s+', ' ', t)).strip()


def _unescape(s):
    out = _html.unescape((s or '').replace('\\/', '/')).strip()
    if '\\u' in out:
        def rep(m):
            try:
                return chr(int(m.group(1), 16))
            except Exception:
                return m.group(0)
        out = re.sub(r'\\u([0-9a-fA-F]{4})', rep, out)
    return out


def _fix_url(raw):
    u = (raw or '').strip()
    if not u:
        return ''
    if u.startswith('//'):
        return 'https:' + u
    if u.startswith('/'):
        return BASE + u
    return u


def _trunc(s, n):
    s = s or ''
    return s[:n] if len(s) > n else s


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
    pat = re.compile(r'(?s)<a[^>]+href="/index\.php/vod/play/id/(\d+)/sid/1/nid/1\.html"[^>]*>\s*<img[^>]+data-src="([^"]+)"[^>]*alt="([^"]+)"')
    for m in pat.finditer(html or ''):
        vid = m.group(1).strip()
        if not vid or vid in seen:
            continue
        title = _unescape(m.group(3).strip())
        if not title:
            continue
        seen.add(vid)
        out.append({'vod_id': vid, 'vod_name': title, 'vod_pic': _fix_url(m.group(2)), 'vod_remarks': ''})
    return out


def _parse_categories(html):
    out = []
    seen = set()
    pat = re.compile(r'href="/index\.php/vod/type/id/(\d+)\.html"[^>]*>([^<]+)<')
    for m in pat.finditer(html or ''):
        cid = m.group(1)
        name = m.group(2).strip()
        if not name or cid in seen:
            continue
        seen.add(cid)
        out.append((cid, name))
    return out


def _parse_player_url(html):
    m = re.search(r'(?s)player_aaaa=.*?"url":"([^"]+)"', html or '')
    if not m:
        return ''
    return _unescape(m.group(1))


def _parse_genre(html):
    m = re.search(r'(?s)player_aaaa=.*?"vod_class":"([^"]*)"', html or '')
    if not m:
        return ''
    return _unescape(m.group(1))


def _parse_title(html):
    m = re.search(r'(?s)<h1[^>]*>(.*?)</h1>', html or '')
    if not m:
        return ''
    return _unescape(_clean(m.group(1)))


def _parse_cover(html, title):
    if not title:
        return ''
    pat = re.compile(r'<img[^>]+(?:data-src|src)="([^"]+)"[^>]*alt="([^"]*)"')
    for m in pat.finditer(html or ''):
        if m.group(2).strip() == title:
            return _fix_url(m.group(1))
    return ''


def _parse_synopsis(html):
    m = re.search(r'<meta name="description"[^>]*content="([^"]+)"', html or '')
    if not m:
        return ''
    return _unescape(m.group(1).strip())


class Spider(BaseSpider):
    def getName(self):
        return '快乐星球'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cats(self):
        html = _http_get(BASE, referer=BASE + '/')
        lst = _parse_categories(html)
        return lst or list(CATS)

    def homeContent(self, filter=''):
        cats = self._cats()
        tid = cats[0][0] if cats else '20'
        items = _cards(_http_get('%s/index.php/vod/type/id/%s/' % (BASE, tid), referer=BASE + '/'))
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in cats],
            'list': items,
        }

    def homeVideoContent(self):
        cats = self._cats()
        tid = cats[0][0] if cats else '20'
        items = _cards(_http_get('%s/index.php/vod/type/id/%s/' % (BASE, tid), referer=BASE + '/'))
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        tid = _norm_id(tid)
        if pg <= 1:
            url = '%s/index.php/vod/type/id/%s/' % (BASE, tid)
        else:
            url = '%s/index.php/vod/type/id/%s/page/%d.html' % (BASE, tid, pg)
        html = _http_get(url, referer=BASE + '/')
        items = _cards(html)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        nid = _norm_id(ids).strip().strip('/')
        nid = nid.replace('index.php/vod/play/id/', '').rstrip('.html')
        nid = nid.split('/')[0]
        if not nid:
            return {'list': []}
        html = _http_get('%s/index.php/vod/play/id/%s/sid/1/nid/1.html' % (BASE, nid), referer=BASE + '/')
        if not html:
            return {'list': []}
        title = _parse_title(html)
        cover = _parse_cover(html, title)
        synopsis = _parse_synopsis(html)
        genre = _parse_genre(html)
        m3u8 = _parse_player_url(html)
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
            'vod_play_url': '播放$%s' % m3u8,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        url = '%s/index.php/vod/search/wd/%s.html' % (BASE, urllib.parse.quote(str(key or ''), safe=''))
        html = _http_get(url, referer=BASE + '/')
        return {'list': _cards(html), 'page': _norm_pg(pg), 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        if raw.startswith('http'):
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', '']

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
