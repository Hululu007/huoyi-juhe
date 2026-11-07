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
    _HAS_REQ = False


BASE = 'https://pandatv1346.lol'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

FALLBACK_CATS = [
    ('75', '国产'),
    ('83', '高清无码'),
    ('84', '中文字幕'),
]


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _http_get(url, timeout=25):
    h = {'User-Agent': UA, 'Referer': BASE}
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


def _http_post_search(query, timeout=25):
    body = 'wd=' + urllib.parse.quote(query or '')
    h = {'User-Agent': UA, 'Referer': BASE, 'Content-Type': 'application/x-www-form-urlencoded'}
    for _ in range(3):
        if _HAS_REQ:
            try:
                r = requests.post(BASE + '/index.php/vod/search.html', data=body, headers=h, timeout=timeout)
                if r.status_code == 200 and r.text:
                    return r.text
            except Exception:
                pass
        try:
            req = urllib.request.Request(BASE + '/index.php/vod/search.html', data=body.encode('utf-8'), headers=h, method='POST')
            with urllib.request.urlopen(req, timeout=timeout, context=_ctx()) as resp:
                return resp.read().decode('utf-8', 'replace')
        except urllib.error.HTTPError as e:
            try:
                return e.read().decode('utf-8', 'ignore')
            except Exception:
                pass
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
    return (s or '').replace('&amp;', '&').replace('&quot;', '"').replace('&#39;', "'").replace('&lt;', '<').replace('&gt;', '>').replace('\\/', '/')


def _clean(t):
    if not t:
        return ''
    t = re.sub(r'<[^>]+>', ' ', t)
    return _html.unescape(re.sub(r'\s+', ' ', t)).strip()


def _text(v, keys):
    if not isinstance(v, dict):
        return ''
    for k in keys:
        x = v.get(k)
        if x is None or isinstance(x, bool):
            continue
        s = str(x)
        if s:
            return s
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
        return 'PANDATV'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cats(self):
        html = _http_get(BASE)
        out = []
        seen = set()
        for mm in re.finditer(r'href="/index\.php/vod/type/id/(\d+)\.html"[^>]*>([^<]+)<', html or ''):
            cid = mm.group(1)
            name = mm.group(2).strip()
            if name and name != '+更多' and cid not in seen:
                seen.add(cid)
                out.append((cid, name))
        return out or list(FALLBACK_CATS)

    def _cards(self, html):
        out = []
        seen = set()
        for mm in re.finditer(r'(?s)<a href="/index\.php/vod/play/id/(\d+)/sid/1/nid/1\.html" title="([^"]+)"[^>]*>.*?<img src="([^"]+)"', html or ''):
            vid = mm.group(1).strip()
            if not vid or vid in seen:
                continue
            title = _unescape(mm.group(2).strip())
            if not title:
                continue
            seen.add(vid)
            out.append({
                'vod_id': vid,
                'vod_name': title,
                'vod_pic': _fix_url(mm.group(3)),
                'vod_remarks': '',
            })
        return out

    def _catalog(self, tid, pg):
        if pg <= 1:
            url = '%s/index.php/vod/type/id/%s.html' % (BASE, tid)
        else:
            url = '%s/index.php/vod/type/id/%s/page/%s.html' % (BASE, tid, pg)
        return self._cards(_http_get(url))

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
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        vid = nid.strip().lstrip('/')
        if vid.startswith('index.php/vod/play/id/'):
            vid = vid[len('index.php/vod/play/id/'):]
        vid = vid.split('/')[0]
        html = _http_get('%s/index.php/vod/play/id/%s/sid/1/nid/1.html' % (BASE, vid))
        if not html:
            return {'list': []}
        player = None
        m = re.search(r'(?s)var player_aaaa=(\{.*?\})\s*</script>', html)
        if m:
            try:
                player = json.loads(m.group(1))
            except Exception:
                player = None
        if not player:
            return {'list': []}
        vod_data = player.get('vod_data') if isinstance(player.get('vod_data'), dict) else {}
        title = _text(vod_data, ['vod_name'])
        m3u8 = _text(player, ['url'])
        if not title or not m3u8:
            return {'list': []}
        genre = _text(vod_data, ['vod_class'])
        cover = ''
        for mm in re.finditer(r'<img[^>]*src="([^"]+)"', html):
            src = _fix_url(mm.group(1))
            if src and '/template/' not in src:
                cover = src
                break
        synopsis = ''
        m = re.search(r'<meta name="description"[^>]*content="([^"]+)"', html)
        if m:
            synopsis = _unescape(m.group(1).strip())
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': _text(vod_data, ['vod_actor']),
            'vod_director': _text(vod_data, ['vod_director']),
            'vod_remarks': '',
            'vod_year': '',
            'vod_area': '',
            'vod_content': synopsis,
            'type_name': genre,
            'vod_tag': genre,
            'vod_play_from': '在线播放',
            'vod_play_url': '播放$%s' % m3u8,
            'stills': [cover] if cover else [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        items = self._cards(_http_post_search(key or ''))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        header = {'User-Agent': UA, 'Referer': BASE}
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
