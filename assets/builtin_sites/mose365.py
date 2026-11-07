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


BASE = 'https://exwxfmd4.work'
API = 'https://exwxfmd4.work/api/public'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

FALLBACK_CATS = [
    ('missav', 'MissAV'),
    ('xvideos', 'XVideos'),
    ('xnxx', 'XNXX'),
    ('eporner', 'Eporner'),
]


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _http_get(url, timeout=25):
    h = {'User-Agent': UA, 'Accept': 'application/json', 'Referer': BASE + '/'}
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


def _get_json(url):
    try:
        return json.loads(_http_get(url) or '{}')
    except Exception:
        return {}


def _fix_cover(raw):
    u = (raw or '').strip()
    if not u:
        return ''
    if u.startswith('http'):
        return u
    if u.startswith('//'):
        return 'https:' + u
    if u.startswith('/'):
        return BASE + u
    return BASE + '/' + u


def _resolve_stream(source_url):
    u = (source_url or '').strip()
    if not u:
        return ''
    if u.startswith('http'):
        return u
    if '://' in u:
        scheme, rest = u.split('://', 1)
        if scheme and rest:
            return '%s/%s/%s' % (API, scheme, rest)
    return ''


def _text(v, keys):
    if not isinstance(v, dict):
        return ''
    for k in keys:
        x = v.get(k)
        if x is None:
            continue
        if isinstance(x, bool):
            continue
        s = str(x)
        if s:
            return s
    return ''


def _int(v, keys):
    s = _text(v, keys)
    try:
        return int(float(s))
    except Exception:
        return 0


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
        return '魔色365'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cats(self):
        root = _get_json(API + '/home')
        out = []
        data = root.get('data') if isinstance(root, dict) else None
        if isinstance(data, dict):
            sections = data.get('sections') or []
            for s in sections:
                slug = _text(s, ['slug'])
                name = _text(s, ['name'])
                if slug and name:
                    out.append((slug, name))
        return out or list(FALLBACK_CATS)

    def _cards(self, data):
        out = []
        if not isinstance(data, dict):
            return out
        for v in data.get('videos') or []:
            vid = _text(v, ['id'])
            title = _text(v, ['title'])
            if not vid or not title:
                continue
            out.append({
                'vod_id': vid,
                'vod_name': title,
                'vod_pic': _fix_cover(_text(v, ['cover'])),
                'vod_remarks': _text(v, ['source_name']),
            })
        return out

    def _catalog(self, tid, pg):
        url = '%s/category/%s?page=%s&pageSize=24' % (API, urllib.parse.quote(tid), pg)
        root = _get_json(url)
        data = root.get('data') if isinstance(root, dict) else None
        if not isinstance(data, dict):
            return [], 0
        return self._cards(data), _int(data, ['total'])

    def homeContent(self, filter=''):
        cats = self._cats()
        items = []
        if cats:
            items, _ = self._catalog(cats[0][0], 1)
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in cats],
            'list': items,
        }

    def homeVideoContent(self):
        cats = self._cats()
        items = []
        if cats:
            items, _ = self._catalog(cats[0][0], 1)
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        items, total = self._catalog(tid, pg)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': total}

    def detailContent(self, ids):
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        vid = nid.strip().lstrip('/').replace('video/', '').rstrip('/')
        root = _get_json('%s/video/%s' % (API, urllib.parse.quote(vid)))
        data = root.get('data') if isinstance(root, dict) else None
        video = data.get('video') if isinstance(data, dict) else None
        if not isinstance(video, dict):
            return {'list': []}
        title = _text(video, ['title'])
        cover = _fix_cover(_text(video, ['cover']))
        stream = _resolve_stream(_text(video, ['source_url']))
        if not title or not stream:
            return {'list': []}
        synopsis = _text(video, ['description']) or title
        parts = []
        if synopsis:
            parts.append(synopsis)
        dur = _int(video, ['duration'])
        if dur:
            parts.append('时长：%s 秒' % dur)
        views = _int(video, ['view_count'])
        if views:
            parts.append('播放：%s' % views)
        src = _text(video, ['source_name'])
        if src:
            parts.append('来源：' + src)
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': src,
            'vod_year': '',
            'vod_area': '',
            'vod_content': '\n'.join(parts),
            'type_name': _text(video, ['category_name']),
            'vod_tag': _text(video, ['tags']),
            'vod_play_from': '在线播放',
            'vod_play_url': '播放$%s' % stream,
            'stills': [cover] if cover else [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        url = '%s/search?q=%s&page=1' % (API, urllib.parse.quote(key or ''))
        root = _get_json(url)
        data = root.get('data') if isinstance(root, dict) else None
        items = self._cards(data) if isinstance(data, dict) else []
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

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
