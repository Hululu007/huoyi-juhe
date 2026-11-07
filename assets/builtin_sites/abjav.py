import gzip
import json
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

BASE = 'https://abjav.com'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

B164_ALPHABET = '\u0410\u0412\u0421D\u0415FGHIJKL\u041cNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.,~'

FALLBACK_CATS = [
    ('asian', 'Asian'),
    ('japanese', 'Japanese'),
    ('hd', 'HD'),
    ('censored', 'Censored'),
    ('uncensored', 'Uncensored'),
    ('big-tits', 'Big Tits'),
    ('amateur', 'Amateur'),
    ('milf', 'MILF'),
    ('pov', 'POV'),
    ('creampie', 'Creampie'),
    ('brunette', 'Brunette'),
    ('hairy', 'Hairy'),
    ('toys', 'Toys'),
    ('deepthroat', 'Deepthroat'),
    ('shaved', 'Shaved'),
]

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

CACHE = {}
CATS_TTL = 3600


def _now():
    return time.time()


def _http_get(url, referer=None, timeout=25):
    hdr = {
        'User-Agent': UA,
        'Accept': 'application/json, */*',
        'Accept-Language': 'en-US,en;q=0.9',
        'Accept-Encoding': 'gzip, deflate',
        'Connection': 'keep-alive',
    }
    if referer:
        hdr['Referer'] = referer
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
                try:
                    time.sleep(1)
                except Exception:
                    pass
    return None


def _http_json(url, referer=None, timeout=25):
    raw = _http_get(url, referer=referer, timeout=timeout)
    if not raw:
        return None
    try:
        return json.loads(raw)
    except Exception:
        return None


def _b164_decode(text):
    if not text:
        return ''
    alpha = list(B164_ALPHABET)
    pos = {}
    for i, ch in enumerate(alpha):
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


def _txt(v):
    if v is None:
        return ''
    if isinstance(v, str):
        return v.strip()
    return str(v).strip()


def _list_url(section, obj, sort, pg):
    return '%s/api/json/videos2/86400/str/%s/60/%s.%s.%d.all...json' % (BASE, sort, section, obj, pg)


def _parse_videos(data):
    out = []
    if not isinstance(data, dict):
        return out
    arr = data.get('videos')
    if not isinstance(arr, list):
        return out
    seen = set()
    for v in arr:
        if not isinstance(v, dict):
            continue
        vid = _txt(v.get('video_id'))
        d = _txt(v.get('dir'))
        title = _txt(v.get('title'))
        if not vid or not d or not title:
            continue
        pid = '%s/video/%s/%s/' % (BASE, vid, d)
        if pid in seen:
            continue
        seen.add(pid)
        pic = _txt(v.get('scr'))
        if pic.startswith('//'):
            pic = 'https:' + pic
        out.append({
            'vod_id': pid,
            'vod_name': title,
            'vod_pic': pic,
            'vod_remarks': _txt(v.get('duration')),
        })
    return out


def _fetch_categories():
    v = CACHE.get('cats')
    if v and _now() - v[0] < v[2]:
        return v[1]
    cats = []
    data = _http_json('%s/api/json/categories/14400/str.toptn.en.json' % BASE, referer=BASE + '/')
    if isinstance(data, dict):
        arr = data.get('categories')
        if isinstance(arr, list):
            for c in arr:
                if not isinstance(c, dict):
                    continue
                d = _txt(c.get('dir'))
                t = _txt(c.get('title'))
                if d and t:
                    cats.append(('category:' + d, t))
    ttl = CATS_TTL
    if not cats:
        cats = [('category:' + d, t) for d, t in FALLBACK_CATS]
        ttl = 300
    if len(CACHE) > 20:
        CACHE.clear()
    CACHE['cats'] = (_now(), cats, ttl)
    return cats


def _numeric_id(raw):
    s = str(raw or '')
    if '$' in s:
        s = s.split('$')[-1]
    p = s.find('/video/')
    if p >= 0:
        rest = s[p + 7:]
        digits = ''
        for ch in rest:
            if ch.isdigit():
                digits += ch
            else:
                break
        if digits:
            return digits
    digits = ''.join([ch for ch in s if ch.isdigit()])
    return digits


def _detail_json(nid):
    try:
        n = int(nid)
    except Exception:
        return None
    million = (n // 1000000) * 1000000
    thousand = (n // 1000) * 1000
    url = '%s/api/json/video/86400/%d/%d/%s.json' % (BASE, million, thousand, nid)
    data = _http_json(url, referer=BASE + '/')
    if isinstance(data, dict) and isinstance(data.get('video'), dict):
        return data['video']
    return None


def _resolve_redirect(url, referer):
    for _ in range(2):
        try:
            hdr = {'User-Agent': UA, 'Referer': referer or (BASE + '/')}
            req = urllib.request.Request(url, headers=hdr)
            with urllib.request.urlopen(req, timeout=25, context=CTX) as resp:
                final = resp.geturl()
                if final and final != url:
                    return final
                return url
        except Exception:
            continue
    return None


def _norm_id(ids):
    if isinstance(ids, (list, tuple)):
        return str(ids[0]) if ids else ''
    return str(ids)


def _norm_pg(pg):
    try:
        return int(pg)
    except Exception:
        try:
            return int(str(pg).strip())
        except Exception:
            return 1


class Spider(BaseSpider):

    def getName(self):
        return 'ABJAV'

    def getDependence(self):
        return []

    def init(self, extend=None):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=False):
        cats = [
            {'type_id': 'latest-updates', 'type_name': 'Latest'},
            {'type_id': 'most-popular', 'type_name': 'Most Popular'},
            {'type_id': 'top-rated', 'type_name': 'Top Rated'},
        ]
        for tid, name in _fetch_categories():
            cats.append({'type_id': tid, 'type_name': name})
        return {'class': cats, 'filters': {}}

    def homeVideoContent(self):
        data = _http_json(_list_url('', '', 'latest-updates', 1), referer=BASE + '/')
        items = _parse_videos(data)
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        tid = _norm_id(tid)
        pg = _norm_pg(pg)
        if pg < 1:
            pg = 1
        if tid in ('latest-updates', 'most-popular', 'top-rated'):
            url = _list_url('', '', tid, pg)
        elif tid.startswith('category:'):
            url = _list_url('categories', tid[len('category:'):], 'latest-updates', pg)
        else:
            url = _list_url('', '', 'latest-updates', pg)
        data = _http_json(url, referer=BASE + '/')
        items = _parse_videos(data)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        raw = _norm_id(ids)
        nid = _numeric_id(raw)
        page_url = raw if raw.startswith('http') else ''
        v = _detail_json(nid) if nid else None
        if not v:
            return {'list': [{
                'vod_id': page_url or raw,
                'vod_name': '',
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
                'vod_play_url': '',
            }]}
        title = _txt(v.get('title'))
        d = _txt(v.get('dir'))
        if not page_url:
            page_url = '%s/video/%s/%s/' % (BASE, nid, d)
        thumb = _txt(v.get('thumb'))
        if thumb.startswith('//'):
            thumb = 'https:' + thumb
        actors = []
        md = v.get('models_data') or v.get('models')
        if isinstance(md, dict):
            for _, m in md.items():
                if isinstance(m, dict):
                    t = _txt(m.get('title'))
                    if t and t not in actors:
                        actors.append(t)
        elif isinstance(md, list):
            for m in md:
                if isinstance(m, dict):
                    t = _txt(m.get('title'))
                    if t and t not in actors:
                        actors.append(t)
        tags = []
        tg = v.get('tags')
        if isinstance(tg, dict):
            for _, t in tg.items():
                if isinstance(t, dict):
                    name = _txt(t.get('title'))
                    if name and name not in tags:
                        tags.append(name)
        elif isinstance(tg, list):
            for t in tg:
                if isinstance(t, dict):
                    name = _txt(t.get('title'))
                    if name and name not in tags:
                        tags.append(name)
        channel = ''
        ch = v.get('channel')
        if isinstance(ch, dict):
            channel = _txt(ch.get('title'))
        parts = []
        desc = _txt(v.get('description'))
        if desc:
            parts.append(desc)
        dur = _txt(v.get('duration'))
        if dur:
            parts.append('时长：' + dur)
        if channel:
            parts.append('频道：' + channel)
        if tags:
            parts.append('标签：' + '、'.join(tags))
        year = ''
        pd = _txt(v.get('post_date'))
        if len(pd) >= 4 and pd[:4].isdigit():
            year = pd[:4]
        stills = []
        thumbsrc = _txt(v.get('thumbsrc'))
        tnc = v.get('tnc')
        try:
            tnc = int(tnc)
        except Exception:
            tnc = 0
        if thumbsrc and tnc > 0:
            base = thumbsrc.rsplit('/', 1)[0]
            for i in range(1, min(tnc, 12) + 1):
                stills.append('%s/%d.jpg' % (base, i))
        play_url = '正片$abjav:%s' % nid if nid else ''
        return {'list': [{
            'vod_id': page_url,
            'vod_name': title,
            'vod_pic': thumb,
            'vod_actor': ' / '.join(actors),
            'vod_director': '',
            'vod_remarks': dur,
            'vod_year': year,
            'vod_area': '',
            'vod_content': '\n'.join(parts),
            'type_name': ' / '.join(tags[:3]),
            'vod_tag': '、'.join(tags),
            'vod_play_from': '在线播放',
            'vod_play_url': play_url,
            'stills': stills,
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        if pg < 1:
            pg = 1
        kw = urllib.parse.quote(str(key).strip())
        url = '%s/api/videos2.php?params=86400/str/relevance/60/search..%d.all...&s=%s' % (BASE, pg, kw)
        data = _http_json(url, referer=BASE + '/')
        items = _parse_videos(data)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        if raw.startswith('http') and '.m3u8' in raw:
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        nid = ''
        if raw.startswith('abjav:'):
            nid = raw.split(':', 1)[1].strip()
            nid = ''.join([ch for ch in nid if ch.isdigit()])
        else:
            nid = _numeric_id(raw)
        if not nid:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        url = '%s/api/videofile.php?video_id=%s&lifetime=8640000' % (BASE, nid)
        data = _http_json(url, referer=BASE + '/')
        if not isinstance(data, list) or not data:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        chosen = None
        for item in data:
            if isinstance(item, dict) and _txt(item.get('format')) == '.mp4' and item.get('is_default'):
                chosen = item
                break
        if chosen is None:
            for item in data:
                if isinstance(item, dict) and _txt(item.get('format')) == '.mp4':
                    chosen = item
                    break
        if chosen is None:
            for item in data:
                if isinstance(item, dict):
                    chosen = item
                    break
        if chosen is None:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        path = _b164_decode(_txt(chosen.get('video_url')))
        if not path.startswith('/get_file/'):
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        hls = '%s%s&f=video.m3u8' % (BASE, path)
        final = _resolve_redirect(hls, BASE + '/')
        play = final if final else hls
        return {'parse': 0, 'playUrl': play, 'url': play, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', b'', {}]

    def isVideoFormat(self, url):
        return False

    def manualVideoCheck(self):
        return True

    def action(self, action, params=None):
        return {'code': 0, 'msg': 'ok'}
