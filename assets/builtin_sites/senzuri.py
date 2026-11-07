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


HOST = 'https://senzuri.tube'
API = 'https://senzuri.tube/api'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

BASE164_ALPHABET = '\u0410\u0412\u0421D\u0415FGHIJKL\u041cNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.,~'

CATS = [
    ('latest-updates', '最新'),
    ('most-popular', '最热'),
    ('longest', '最长'),
    ('cat:jav-censored', 'JAV Censored'),
    ('cat:hd', 'HD'),
    ('cat:cuckold', 'Cuckold'),
    ('cat:asian', 'Asian'),
    ('cat:toys', 'Toys'),
    ('cat:japanese', 'Japanese'),
    ('cat:cheating', 'Cheating'),
    ('cat:female-orgasm', 'Female Orgasm'),
    ('cat:compilation', 'Compilation'),
    ('cat:blowjob-fera', 'Blowjob/Fera'),
]


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _http_get(url, referer, timeout=25):
    h = {'User-Agent': UA, 'Accept': 'application/json, text/html, */*', 'Referer': referer}
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


def _decode_entities(s):
    return (s or '').replace('&nbsp;', ' ').replace('&amp;', '&').replace('&#039;', "'").replace('&#39;', "'").replace('&quot;', '"').replace('&lt;', '<').replace('&gt;', '>').replace('&ndash;', '–').replace('&mdash;', '—').strip()


def _truncate(s, n):
    if len(s) > n:
        return s[:n]
    return s


def _base164_decode(input_s):
    alpha = list(BASE164_ALPHABET)
    clean = [c for c in (input_s or '') if c in alpha]

    def idx(c):
        try:
            return alpha.index(c)
        except Exception:
            return 64
    out = bytearray()
    i = 0
    while i < len(clean):
        a = idx(clean[i])
        b = idx(clean[i + 1]) if i + 1 < len(clean) else 64
        c = idx(clean[i + 2]) if i + 2 < len(clean) else 64
        d = idx(clean[i + 3]) if i + 3 < len(clean) else 64
        out.append(((a << 2) | (b >> 4)) & 0xFF)
        if c != 64:
            out.append((((b & 15) << 4) | (c >> 2)) & 0xFF)
        if d != 64:
            out.append((((c & 3) << 6) | d) & 0xFF)
        i += 4
    return bytes(out).decode('utf-8', 'replace')


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


def _videos_url(category_id, page):
    if category_id.startswith('cat:'):
        return '%s/json/videos2/86400/str/latest-updates/60/categories.%s.%s.all...json' % (API, category_id[4:], page)
    return '%s/json/videos2/86400/str/%s/60/..%s.all...json' % (API, category_id, page)


def _parse_videos(json_text):
    try:
        v = json.loads(json_text or '{}')
    except Exception:
        return []
    arr = v.get('videos') if isinstance(v, dict) else None
    if not isinstance(arr, list):
        return []
    out = []
    for video in arr:
        vid = _text(video, ['video_id'])
        if not vid:
            continue
        title = _decode_entities(_text(video, ['title']))
        if not title:
            continue
        cover = _text(video, ['thumbsrc']) or _text(video, ['thumb'])
        out.append({
            'vod_id': vid,
            'vod_name': _truncate(title, 90),
            'vod_pic': cover,
            'vod_remarks': _text(video, ['duration']),
        })
    return out


def _video_json_url(video_id):
    try:
        n = int(video_id)
    except Exception:
        return None
    m = 1000000 * (n // 1000000)
    k = 1000 * (n // 1000)
    return '%s/json/video/86400/%s/%s/%s.json' % (API, m, k, video_id)


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
        return 'Senzuri Tube'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=''):
        items = _parse_videos(_http_get(_videos_url('latest-updates', 1), HOST + '/'))
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in CATS],
            'list': items,
        }

    def homeVideoContent(self):
        items = _parse_videos(_http_get(_videos_url('latest-updates', 1), HOST + '/'))
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        items = _parse_videos(_http_get(_videos_url(tid, pg), HOST + '/'))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        url = _video_json_url(nid)
        if not url:
            return {'list': []}
        try:
            v = json.loads(_http_get(url, HOST + '/') or '{}')
        except Exception:
            return {'list': []}
        video = v.get('video') if isinstance(v, dict) else None
        if not isinstance(video, dict):
            return {'list': []}
        title = _decode_entities(_text(video, ['title']))
        if not title:
            return {'list': []}
        cover = _text(video, ['thumbsrc']) or _text(video, ['thumb'])
        desc = _decode_entities(_text(video, ['description']))
        duration = _text(video, ['duration'])
        cats = []
        cmap = video.get('categories')
        if isinstance(cmap, dict):
            for _, c in cmap.items():
                t = _text(c, ['title'])
                if t:
                    cats.append(t)
        lines = []
        if cats:
            lines.append('分类：' + '、'.join(cats))
        if duration:
            lines.append('时长：' + duration)
        synopsis = desc
        if lines:
            if synopsis:
                synopsis += '\n'
            synopsis += '\n'.join(lines)
        synopsis = _truncate(synopsis, 400)
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': duration,
            'vod_year': '',
            'vod_area': '',
            'vod_content': synopsis,
            'type_name': '',
            'vod_tag': '、'.join(cats),
            'vod_play_from': '在线播放',
            'vod_play_url': '正片$%s' % nid,
            'stills': [cover] if cover else [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        url = '%s/videos2.php?params=86400/str/relevance/60/search..1.all...&s=%s' % (API, urllib.parse.quote(key or ''))
        items = _parse_videos(_http_get(url, HOST + '/'))[:60]
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        header = {'User-Agent': UA, 'Referer': HOST + '/'}
        if '.mp4' in raw:
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        vid = raw.split('$')[-1]
        url = '%s/videofile.php?video_id=%s&lifetime=864000' % (API, vid)
        try:
            v = json.loads(_http_get(url, '%s/videos/%s/' % (HOST, vid)) or '[]')
        except Exception:
            v = []
        if not isinstance(v, list) or not v:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        chosen = None
        for entry in v:
            if _text(entry, ['is_default']) == '1':
                chosen = entry
                break
            if chosen is None:
                chosen = entry
        if not chosen:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        enc = _text(chosen, ['video_url'])
        if not enc:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        decoded = _base164_decode(enc)
        if not decoded or 'get_file/' not in decoded:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        if decoded.startswith('/'):
            stream = HOST + decoded
        elif decoded.startswith('http'):
            stream = decoded
        else:
            stream = HOST + '/' + decoded
        header['Referer'] = '%s/videos/%s/' % (HOST, vid)
        return {'parse': 0, 'playUrl': stream, 'url': stream, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', '']

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
