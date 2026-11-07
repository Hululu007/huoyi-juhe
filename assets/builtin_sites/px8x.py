try:
    from base.spider import BaseSpider
except Exception:
    try:
        from base import BaseSpider
    except Exception:
        class BaseSpider:
            pass


import base64
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


BASE = 'https://8xx6.lol'
UA = 'Mozilla/5.0 (Linux; Android 14; HarmonyOS; HUAWEI) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36'

CATS = [
    ('901179', '国产'),
    ('911179', '有码'),
    ('921179', '无码'),
    ('931179', '欧美'),
    ('941179', '传媒'),
    ('951179', '探花'),
    ('961179', '中文'),
    ('971179', '动漫'),
]


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _http_get(url, timeout=25):
    h = {'User-Agent': UA, 'Referer': BASE + '/'}
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


def _unescape(s):
    return (s or '').replace('&amp;', '&').replace('&quot;', '"').replace('&#39;', "'").replace('&lt;', '<').replace('&gt;', '>')


def _decode_obfuscated(payload):
    padded = (payload or '').strip()
    while len(padded) % 4 != 0:
        padded += '='
    try:
        raw = base64.b64decode(padded)
    except Exception:
        return ''
    html = raw.decode('utf-8', 'replace')
    html = re.sub(r'(?s)<span[^>]*display\s*:\s*none[^>]*>.*?</span>', '', html)
    plain = re.sub(r'<[^>]+>', '', html)
    return _unescape(re.sub(r'\s+', ' ', plain).strip())


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
        return 'Px8x'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cards(self, html):
        out = []
        seen = set()
        for mm in re.finditer(r'href="/video/(\d+)\.html"', html or ''):
            vid = '/video/%s.html' % mm.group(1)
            if vid in seen:
                continue
            seen.add(vid)
            start = mm.start()
            window = html[start:min(start + 4000, len(html))]
            cover = ''
            m2 = re.search(r'<img[^>]*src="([^"]+)"', window)
            if m2:
                cover = m2.group(1)
            title = ''
            m2 = re.search(r"d\('([^']+)'\)", window)
            if m2:
                title = _decode_obfuscated(m2.group(1))
            if not title:
                continue
            out.append({
                'vod_id': vid,
                'vod_name': title,
                'vod_pic': cover,
                'vod_remarks': '',
            })
        return out

    def _detail_url(self, series_id):
        sid = (series_id or '').strip()
        if sid.startswith('http'):
            return sid
        if sid.startswith('/'):
            return BASE + sid
        if sid.isdigit():
            return '%s/video/%s.html' % (BASE, sid)
        return BASE + '/' + sid

    def homeContent(self, filter=''):
        items = self._cards(_http_get('%s/list/%s-1.html' % (BASE, CATS[0][0])))
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in CATS],
            'list': items,
        }

    def homeVideoContent(self):
        items = self._cards(_http_get('%s/list/%s-1.html' % (BASE, CATS[0][0])))
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        items = self._cards(_http_get('%s/list/%s-%s.html' % (BASE, tid, pg)))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        html = _http_get(self._detail_url(nid))
        if not html:
            return {'list': []}
        title = ''
        m = re.search(r'(?s)<h1[^>]*>(.*?)</h1>', html)
        if m:
            m2 = re.search(r"d\('([^']+)'\)", m.group(1))
            if m2:
                title = _decode_obfuscated(m2.group(1))
        play_url = ''
        m = re.search(r"hls\.loadSource\('([^']+)'\)", html)
        if m:
            play_url = m.group(1)
        if not title or not play_url:
            return {'list': []}
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': '',
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': '',
            'vod_year': '',
            'vod_area': '',
            'vod_content': '',
            'type_name': '',
            'vod_tag': '',
            'vod_play_from': '在线播放',
            'vod_play_url': '播放$%s' % play_url,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        url = BASE + '/search.php?' + urllib.parse.urlencode({'content': key or ''})
        items = self._cards(_http_get(url))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        if raw.startswith('http'):
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        html = _http_get(self._detail_url(raw))
        found = ''
        m = re.search(r"hls\.loadSource\('([^']+)'\)", html or '')
        if m:
            found = m.group(1)
        if not found:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        return {'parse': 0, 'playUrl': found, 'url': found, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', '']

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
