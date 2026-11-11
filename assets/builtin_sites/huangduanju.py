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
import http.cookiejar
import json
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
    requests = None
    _HAS_REQ = False

BASE = 'https://hpkspvynq.buzz'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

CATS = [
    ('recent', '最新视频'),
    ('228', '国产传媒'),
    ('223', '国产视频'),
    ('583', '国产自拍'),
    ('295', '无码专区'),
    ('297', '制服师生'),
    ('298', '伦理系列'),
    ('299', '换脸AI'),
    ('300', '中文伦理'),
    ('301', '卡通动漫'),
    ('302', '欧美系列'),
    ('303', '美女主播'),
    ('304', '国产自拍'),
    ('305', '人妻热门'),
]

_JAR = http.cookiejar.CookieJar()


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


_OPENER = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(_JAR), urllib.request.HTTPSHandler(context=_ctx()))


def _fetch_once(url, timeout=30):
    h = {'User-Agent': UA}
    if _HAS_REQ:
        r = requests.get(url, headers=h, timeout=timeout)
        if r.status_code == 200 and r.text and r.text.strip():
            return r.text
    req = urllib.request.Request(url, headers=h)
    with _OPENER.open(req, timeout=timeout) as resp:
        raw = resp.read()
        enc = (resp.headers.get('Content-Encoding') or '').lower()
        if enc == 'gzip' or raw[:2] == b'\x1f\x8b':
            try:
                raw = gzip.decompress(raw)
            except Exception:
                pass
        return raw.decode('utf-8', 'replace')


def _get(url, timeout=30):
    last = ''
    for _ in range(3):
        try:
            return _fetch_once(url, timeout)
        except urllib.error.HTTPError as e:
            try:
                return e.read().decode('utf-8', 'ignore')
            except http.client.IncompleteRead as ie:
                return ie.partial.decode('utf-8', 'ignore')
        except http.client.IncompleteRead as e:
            try:
                txt = e.partial.decode('utf-8', 'ignore')
            except Exception:
                txt = ''
            if txt.strip():
                return txt
            last = 'IncompleteRead'
            time.sleep(2)
        except Exception as e:
            last = str(e)
            time.sleep(2)
    return ''


def _unescape(s):
    return _html.unescape(s or '').replace('&amp;', '&').replace('&quot;', '"').replace('&#39;', "'").replace('&lt;', '<').replace('&gt;', '>').replace('&nbsp;', ' ')


def _strip_tags(s):
    if not s:
        return ''
    t = re.sub(r'<[^>]+>', ' ', s)
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


def _parse_cards(html):
    card_re = re.compile(r"(?s)<a[^>]*href='/video/info/(\d+)\.html'[^>]*title=\"([^\"]+)\"[^>]*>.*?<img[^>]*src=\"([^\"]+)\"")
    out = []
    seen = set()
    for m in card_re.finditer(html or ''):
        vid = m.group(1)
        if vid in seen:
            continue
        seen.add(vid)
        title = _unescape(m.group(2).strip())
        if not title:
            continue
        cover = m.group(3).strip()
        out.append({'vod_id': vid, 'vod_name': title, 'vod_pic': cover, 'vod_remarks': ''})
    return out


def _catalog_url(tid, pg):
    if tid == 'recent':
        if pg <= 1:
            return BASE + '/video/show/recent.html'
        return BASE + '/video/show/recent/%d.html' % pg
    if pg <= 1:
        return BASE + '/video/type/%s.html' % tid
    return BASE + '/video/type/%s/%d.html' % (tid, pg)


def _next_page_url(tid, pg):
    if tid == 'recent':
        return BASE + '/video/show/recent/%d.html' % (pg + 1)
    return BASE + '/video/type/%s/%d.html' % (tid, pg + 1)


def _detail_id(sid):
    s = (sid or '').strip().lstrip('/')
    if s.startswith('video/info/'):
        s = s[len('video/info/'):]
    return s.replace('.html', '')


def _parse_play_url(html):
    m = re.search(r"var playUrl\s*=\s*'([^']+)'", html or '')
    if m:
        return m.group(1).strip()
    m = re.search(r'"contentUrl":\s*"([^"]+)"', html or '')
    if m:
        return m.group(1).strip()
    return ''


class Spider(BaseSpider):
    def getName(self):
        return '黄.短剧'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=''):
        html = _get(BASE)
        cats = [('recent', '最新视频')]
        seen = {'recent'}
        for m in re.finditer(r"(?s)href='/video/type/(\d+)\.html'[^>]*?title=\"([^\"]+)\"", html or ''):
            cid, name = m.group(1), m.group(2).strip()
            if not name or cid in seen:
                continue
            seen.add(cid)
            cats.append((cid, name))
        if len(cats) <= 1:
            cats = list(CATS)
        items = []
        if cats:
            items = _parse_cards(_get(_catalog_url(cats[0][0], 1)))
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in cats],
            'list': items,
        }

    def homeVideoContent(self):
        html = _get(_catalog_url('recent', 1))
        return {'list': _parse_cards(html), 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        tid = _norm_id(tid) or 'recent'
        url = _catalog_url(tid, pg)
        html = _get(url)
        items = _parse_cards(html)
        has_more = bool(items) and _next_page_url(tid, pg) in (html or '')
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': len(items) if not has_more else 0}

    def detailContent(self, ids):
        nid = _detail_id(_norm_id(ids))
        if not nid:
            return {'list': []}
        html = _get(BASE + '/video/info/%s.html' % nid)
        title = ''
        m = re.search(r'(?s)<h1[^>]*>(.*?)</h1>', html or '')
        if m:
            title = _unescape(m.group(1).strip())
        cover = ''
        m = re.search(r'(?s)class="info-cover-img"[^>]*src="([^"]+)"', html or '')
        if m:
            cover = m.group(1).strip()
        genre = ''
        m = re.search(r"href='/video/type/(\d+)\.html'[^>]*>([^<]+)<", html or '')
        if m:
            genre = _unescape(m.group(2).strip())
        synopsis = ''
        m = re.search(r'(?s)<span class="meta-label">简\s*介</span>\s*<span class="meta-value">(.*?)</span>', html or '')
        if m:
            synopsis = _unescape(m.group(1).strip())
        if not title:
            return {'list': []}
        play_url = BASE + '/video/play/%s.html' % nid
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': genre,
            'vod_year': '',
            'vod_area': '',
            'vod_content': synopsis,
            'type_name': genre,
            'vod_tag': genre,
            'vod_play_from': '在线播放',
            'vod_play_url': '播放$%s' % play_url,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        enc = urllib.parse.quote(str(key or '').strip(), safe='')
        html = _get(BASE + '/video/lookup/%s.html' % enc)
        items = _parse_cards(html)
        return {'list': items, 'page': _norm_pg(pg), 'pagecount': 0, 'total': len(items)}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        if raw.endswith('.m3u8') or raw.endswith('.mp4'):
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        if raw.startswith('http'):
            url = raw
        else:
            url = BASE + '/video/play/%s.html' % _detail_id(raw)
        html = _get(url)
        m3u8 = _parse_play_url(html)
        if not m3u8:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
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
