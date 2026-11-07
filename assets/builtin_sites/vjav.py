import gzip
import json
import re
import ssl
import time
import urllib.parse
import urllib.request

try:
    from base.spider import BaseSpider
except Exception:
    try:
        from base import BaseSpider
    except Exception:
        class BaseSpider:
            pass

BASE = 'https://vjav.com'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

B64_ALPHA = '\u0410\u0412\u0421D\u0415FGHIJKL\u041cNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.,~'

SORT_CATS = [
    ('latest', '最新影片', 'latest-updates'),
    ('most-viewed', '最多观看', 'most-viewed'),
    ('top-rated', '最高评分', 'top-rated'),
    ('longest', '最长影片', 'longest'),
    ('most-commented', '最多评论', 'most-commented'),
]

FALLBACK_CATS = [
    ('cat:asian', 'Asian'),
    ('cat:japanese', 'Japanese'),
    ('cat:hd', 'HD'),
    ('cat:jav-censored', 'Censored'),
    ('cat:jav-uncensored', 'Uncensored'),
    ('cat:big-tits', 'Big Tits'),
    ('cat:amateur', 'Amateur'),
    ('cat:milf', 'MILF'),
    ('cat:creampie', 'Creampie/Nakadashi'),
    ('cat:brunette', 'Brunette'),
    ('cat:blowjob', 'Blowjob/Fera'),
    ('cat:hairy', 'Hairy'),
]

try:
    import requests
    _HAS_REQ = True
except Exception:
    _HAS_REQ = False

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE


def _http_get(url, referer=None, timeout=25):
    hdr = {
        'User-Agent': UA,
        'Accept': 'application/json, text/plain, */*',
        'Accept-Language': 'en-US,en;q=0.9',
        'Accept-Encoding': 'gzip, deflate',
    }
    if referer:
        hdr['Referer'] = referer
    if _HAS_REQ:
        try:
            r = requests.get(url, headers=hdr, timeout=timeout)
            if r.status_code == 200 and r.text and r.text.strip():
                return r.text
        except Exception:
            pass
    for attempt in range(3):
        try:
            req = urllib.request.Request(url, headers=hdr)
            with urllib.request.urlopen(req, timeout=timeout, context=CTX) as resp:
                data = resp.read()
                enc = (resp.headers.get('Content-Encoding') or '').lower()
            if enc == 'gzip' or data[:2] == b'\x1f\x8b':
                try:
                    data = gzip.decompress(data)
                except Exception:
                    pass
            return data.decode('utf-8', 'replace')
        except Exception:
            if attempt < 2:
                time.sleep(1)
    return None


def _http_json(url, referer=None):
    raw = _http_get(url, referer=referer)
    if not raw:
        return None
    try:
        return json.loads(raw)
    except Exception:
        return None


def _txt(v):
    if v is None:
        return ''
    if isinstance(v, str):
        return v.strip()
    return str(v).strip()


def _unescape(s):
    if not s:
        return ''
    return (s.replace('&nbsp;', ' ').replace('&amp;', '&').replace('&#039;', "'")
             .replace('&#39;', "'").replace('&quot;', '"').replace('&lt;', '<')
             .replace('&gt;', '>').strip())


def _b64_decode(text):
    if not text:
        return ''
    pos = {}
    for i, ch in enumerate(B64_ALPHA):
        pos[ch] = i
    cleaned = [c for c in text if c in pos]
    out = bytearray()
    n = 0
    while n + 4 <= len(cleaned):
        o = pos[cleaned[n]]
        r = pos[cleaned[n + 1]]
        a = pos[cleaned[n + 2]]
        c = pos[cleaned[n + 3]]
        out.append(((o << 2) | (r >> 4)) & 0xFF)
        if a != 64:
            out.append((((15 & r) << 4) | (a >> 2)) & 0xFF)
        if c != 64:
            out.append((((3 & a) << 6) | c) & 0xFF)
        n += 4
    try:
        raw = urllib.parse.unquote_to_bytes(bytes(out))
    except Exception:
        raw = bytes(out)
    try:
        return raw.decode('utf-8')
    except Exception:
        return raw.decode('utf-8', 'replace')


def _videos2_url(sort, section, obj, pg):
    return '%s/api/json/videos2/86400/str/%s/60/%s.%s.%d.all...json' % (BASE, sort, section, obj, pg)


def _video_url(nid):
    million = (nid // 1000000) * 1000000
    thousand = (nid // 1000) * 1000
    return '%s/api/json/video/86400/%d/%d/%d.json' % (BASE, million, thousand, nid)


def _parse_videos(data):
    out = []
    if not isinstance(data, dict):
        return out
    if data.get('error') is not None:
        return out
    arr = data.get('videos')
    if not isinstance(arr, list):
        return out
    for v in arr:
        if not isinstance(v, dict):
            continue
        vid = _txt(v.get('video_id'))
        d = _txt(v.get('dir'))
        title = _txt(v.get('title'))
        if not vid or not title:
            continue
        out.append({
            'vod_id': '%s/videos/%s/%s/' % (BASE, vid, d),
            'vod_name': _unescape(title)[:90],
            'vod_pic': _txt(v.get('scr')),
            'vod_remarks': _txt(v.get('duration')),
        })
    return out


def _norm_id(ids):
    if isinstance(ids, (list, tuple)):
        return str(ids[0]) if ids else ''
    return str(ids or '')


def _norm_pg(pg):
    try:
        pg = int(pg)
    except Exception:
        pg = 1
    return pg if pg >= 1 else 1


class Spider(BaseSpider):

    def getName(self):
        return 'VJAV'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cats(self):
        cats = [{'type_id': tid, 'type_name': name} for tid, name, _ in SORT_CATS]
        cats.append({'type_id': 'models', 'type_name': '女优'})
        data = _http_json(BASE + '/api/json/categories/14400/str.all.en.json', referer=BASE + '/')
        got = False
        if isinstance(data, dict):
            arr = data.get('categories')
            if isinstance(arr, list):
                for c in arr:
                    if not isinstance(c, dict):
                        continue
                    d = _txt(c.get('dir'))
                    t = _txt(c.get('title'))
                    if d and t:
                        cats.append({'type_id': 'cat:' + d, 'type_name': t})
                        got = True
        if not got:
            for tid, name in FALLBACK_CATS:
                cats.append({'type_id': tid, 'type_name': name})
        return cats

    def _catalog_items(self, tid, pg):
        if tid == 'models':
            url = '%s/api/json/models/86400/female/filt........../latest-updates/60/%d.json' % (BASE, pg)
            data = _http_json(url, referer=BASE + '/')
            out = []
            if isinstance(data, dict):
                arr = data.get('models')
                if isinstance(arr, list):
                    for m in arr:
                        if not isinstance(m, dict):
                            continue
                        mid = _txt(m.get('id'))
                        d = _txt(m.get('dir'))
                        title = _txt(m.get('title'))
                        if not mid or not title:
                            continue
                        count = ''
                        st = m.get('statistics')
                        if isinstance(st, dict):
                            count = _txt(st.get('videos'))
                        out.append({
                            'vod_id': 'modelid:' + mid,
                            'vod_name': title,
                            'vod_pic': _txt(m.get('img')),
                            'vod_remarks': (count + ' 部') if count else d,
                        })
            return out
        if tid.startswith('cat:'):
            url = _videos2_url('latest-updates', 'categories', tid[4:], pg)
        elif tid.startswith('modelid:'):
            url = _videos2_url('latest-updates', 'model', tid[8:], pg)
        else:
            sort = 'latest-updates'
            for cid, _, s in SORT_CATS:
                if cid == tid:
                    sort = s
                    break
            url = _videos2_url(sort, '', '', pg)
        data = _http_json(url, referer=BASE + '/')
        return _parse_videos(data)

    def homeContent(self, filter=''):
        cats = self._cats()
        items = self._catalog_items('latest', 1)
        return {'class': cats, 'filters': {}, 'list': items}

    def homeVideoContent(self):
        items = self._catalog_items('latest', 1)
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        items = self._catalog_items(_norm_id(tid), pg)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        raw = _norm_id(ids)
        m = re.search(r'/videos/(\d+)', raw)
        if not m:
            return {'list': []}
        nid = m.group(1)
        try:
            n = int(nid)
        except Exception:
            return {'list': []}
        data = _http_json(_video_url(n), referer=raw)
        v = None
        if isinstance(data, dict) and isinstance(data.get('video'), dict):
            v = data['video']
        if not v:
            return {'list': []}
        title = _unescape(_txt(v.get('title')))
        if not title:
            return {'list': []}
        cover = _txt(v.get('thumb'))
        parts = []
        desc = _unescape(_txt(v.get('description')))
        if desc:
            parts.append(desc)
        cats = []
        cm = v.get('categories')
        if isinstance(cm, dict):
            for _, c in cm.items():
                if isinstance(c, dict):
                    t = _txt(c.get('title'))
                    if t:
                        cats.append(t)
        if cats:
            parts.append('分类：' + '、'.join(cats))
        models = _txt(v.get('models'))
        if models:
            parts.append('女优：' + models)
        d = _txt(v.get('dir'))
        page_url = '%s/videos/%s/%s/' % (BASE, nid, d)
        return {'list': [{
            'vod_id': page_url,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': models,
            'vod_director': '',
            'vod_remarks': _txt(v.get('duration')),
            'vod_year': '',
            'vod_area': '',
            'vod_content': '\n'.join(parts)[:400],
            'type_name': ' / '.join(cats[:3]),
            'vod_tag': '、'.join(cats),
            'vod_play_from': '在线播放',
            'vod_play_url': '%s$%s' % (title[:60], page_url),
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        kw = urllib.parse.quote(str(key or '').strip())
        url = '%s/api/videos2.php?params=86400/str/relevance/60/search..%d.all...&s=%s' % (BASE, pg, kw)
        data = _http_json(url, referer=BASE + '/')
        items = _parse_videos(data)[:60]
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        if raw.startswith('http') and '.mp4' in raw:
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        m = re.search(r'/videos/(\d+)', raw)
        if not m:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        url = '%s/api/videofile.php?video_id=%s&lifetime=8640000' % (BASE, m.group(1))
        data = _http_json(url, referer=raw)
        chosen = None
        fallback = None
        if isinstance(data, list):
            for item in data:
                if not isinstance(item, dict):
                    continue
                enc = _txt(item.get('video_url'))
                if not enc:
                    continue
                dec = _b64_decode(enc)
                if not dec:
                    continue
                if fallback is None:
                    fallback = dec
                if _txt(item.get('format')) == '_hq.mp4':
                    chosen = dec
                    break
        path = chosen or fallback
        if not path:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        play = BASE + path
        header['Referer'] = raw
        return {'parse': 0, 'playUrl': play, 'url': play, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', b'', {}]

    def isVideoFormat(self, url):
        u = (url or '').lower()
        return u.endswith('.m3u8') or u.endswith('.mp4') or '.m3u8?' in u or '.mp4?' in u

    def manualVideoCheck(self):
        return False

    def action(self, action, params=None):
        return None
