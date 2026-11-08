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

try:
    import requests as _requests
except Exception:
    _requests = None

BASE = 'https://chinaxselecla08.xyz/c2'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

FALLBACK_CATS = [
    ('domestic-media', '国产传媒'),
    ('japanese-av', '日本AV'),
    ('uncensored-video', '无码视频'),
    ('chinese-subtitles', '中文字幕'),
]

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

CACHE = {}
CATS_TTL = 3600


def _now():
    return time.time()


def _http_get(url, referer=None, timeout=30):
    hdr = {
        'User-Agent': UA,
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9',
        'Accept-Encoding': 'gzip, deflate',
        'Connection': 'keep-alive',
    }
    if referer:
        hdr['Referer'] = referer
    for attempt in range(3):
        raw = None
        if _requests is not None:
            try:
                resp = _requests.get(url, headers=hdr, timeout=timeout)
                if resp.status_code == 200:
                    raw = resp.text
            except Exception:
                raw = None
        if raw is None:
            try:
                req = urllib.request.Request(url, headers=hdr)
                with urllib.request.urlopen(req, timeout=timeout, context=CTX) as resp:
                    if resp.status != 200:
                        raw = None
                    else:
                        data = resp.read()
                        enc = (resp.headers.get('Content-Encoding') or '').lower()
                        if enc == 'gzip' or data[:2] == b'\x1f\x8b':
                            try:
                                data = gzip.decompress(data)
                            except Exception:
                                pass
                        raw = data.decode('utf-8', 'replace')
            except Exception:
                raw = None
        if raw is not None:
            if 'Checking your browser' in raw:
                raw = None
            else:
                return raw
        if attempt < 2:
            try:
                time.sleep(1)
            except Exception:
                pass
    return None


def _unescape(s):
    if not s:
        return ''
    return (s.replace('&nbsp;', ' ')
             .replace('&amp;', '&')
             .replace('&quot;', '"')
             .replace('&#39;', "'")
             .replace('&lt;', '<')
             .replace('&gt;', '>')
             .replace('\\/', '/'))


def _fix_url(raw):
    u = (raw or '').strip()
    if not u:
        return ''
    if u.startswith('//'):
        return 'https:' + u
    if u.startswith('/'):
        return BASE + u
    return u


def _strip_tags(s):
    if not s:
        return ''
    s = re.sub(r'<[^>]+>', ' ', s)
    s = _unescape(s)
    s = re.sub(r'\s+', ' ', s)
    return s.strip()


def _clean_title(t):
    t = (t or '').strip()
    for suf in (' 视频缩图', ' 高清在线观看', ' 高清在线播放'):
        if t.endswith(suf):
            t = t[:-len(suf)]
    return t.strip()


def _parse_cards(html):
    out = []
    if not html:
        return out
    blocks = re.split(r'<div class="thumbnail group">', html)
    seen = set()
    for blk in blocks[1:]:
        m = re.search(r'href="/c2/vodplay/([^"]+)"', blk)
        if not m:
            continue
        slug = m.group(1).strip()
        if not slug or slug in seen:
            continue
        im = re.search(r'<img alt="([^"]+?)"[^>]* src="([^"]+)"', blk)
        if im:
            title_raw, cover_raw = im.group(1), im.group(2)
        else:
            im2 = re.search(r'<img[^>]*src="([^"]+)"[^>]*alt="([^"]+?)"', blk)
            if not im2:
                continue
            cover_raw, title_raw = im2.group(1), im2.group(2)
        title = _clean_title(_unescape(title_raw.strip()))
        if not title:
            continue
        seen.add(slug)
        out.append({
            'vod_id': slug,
            'vod_name': title,
            'vod_pic': _fix_url(cover_raw).split('?')[0],
            'vod_remarks': '',
        })
    return out


def _fetch_categories():
    v = CACHE.get('cats')
    if v and _now() - v[0] < v[2]:
        return v[1]
    cats = []
    html = _http_get(BASE + '/', referer=BASE + '/')
    if html:
        pat = re.compile(r'href="/c2/vodtype/([a-z-]+)/"[^>]*>([^<]+)<')
        seen = {}
        for m in pat.finditer(html):
            cid = m.group(1).strip()
            name = m.group(2).strip()
            if not name:
                continue
            if cid not in seen:
                seen[cid] = name
        cats = [(cid, seen[cid]) for cid in seen]
    ttl = CATS_TTL
    if not cats:
        cats = list(FALLBACK_CATS)
        ttl = 300
    if len(CACHE) > 20:
        CACHE.clear()
    CACHE['cats'] = (_now(), cats, ttl)
    return cats


def _parse_player_url(html):
    if not html:
        return ''
    m = re.search(r'(?s)player_aaaa=.*?"url":"([^"]+)"', html)
    if m:
        return _unescape(m.group(1))
    m = re.search(r'"url":"(https?://[^"]+\.m3u8[^"]*)"', html)
    if m:
        return _unescape(m.group(1))
    return ''


def _label_text(html, label):
    if not html:
        return ''
    m = re.search(r'(?s)<span>\s*' + re.escape(label) + r':</span>\s*<a[^>]*>([^<]+)</a>', html)
    if m:
        return _unescape(m.group(1).strip())
    return ''


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


def _empty_detail(vod_id):
    return {'list': [{
        'vod_id': vod_id,
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
        'stills': [],
    }]}


class Spider(BaseSpider):

    def getName(self):
        return '中国X站精选'

    def getDependence(self):
        return []

    def init(self, extend=None):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=False):
        cats = [{'type_id': cid, 'type_name': name}
                for cid, name in _fetch_categories()]
        return {'class': cats, 'filters': {}}

    def homeVideoContent(self):
        html = _http_get(BASE + '/', referer=BASE + '/')
        items = _parse_cards(html)
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        tid = _norm_id(tid).strip()
        pg = _norm_pg(pg)
        if pg < 1:
            pg = 1
        if not tid or tid == 'all':
            tid = 'domestic-media'
        if pg <= 1:
            path = '/vodtype/%s/' % tid
        else:
            path = '/vodtype/%s-%d/' % (tid, pg)
        html = _http_get(BASE + path, referer=BASE + '/')
        items = _parse_cards(html)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        raw = _norm_id(ids).strip()
        slug = raw
        if slug.startswith('vodplay/'):
            slug = slug[len('vodplay/'):]
        if slug.startswith('c2/vodplay/'):
            slug = slug[len('c2/vodplay/'):]
        slug = slug.strip('/').strip()
        if not slug:
            return _empty_detail(raw)
        html = _http_get(BASE + '/vodplay/' + slug, referer=BASE + '/')
        if not html:
            return _empty_detail(slug)
        title = ''
        m = re.search(r'(?s)<h1[^>]*>(.*?)</h1>', html)
        if m:
            title = _clean_title(_unescape(_strip_tags(m.group(1))))
        if not title:
            m = re.search(r'"name":\s*"([^"]+)"', html)
            if m:
                title = _unescape(m.group(1).strip())
        if not title:
            return _empty_detail(slug)
        cover = ''
        m = re.search(r'"thumbnailUrl":\s*"([^"]+)"', html)
        if m:
            cover = _fix_url(m.group(1))
        synopsis = ''
        m = re.search(r'<meta name="description"[^>]*content="([^"]+)"', html)
        if m:
            synopsis = _unescape(m.group(1).strip())
        genre = ''
        m = re.search(r'"genre":\s*"([^"]+)"', html)
        if m:
            genre = _unescape(m.group(1).strip())
        year = ''
        m = re.search(r'<time[^>]*datetime="(\d{4})-', html)
        if m:
            year = m.group(1)
        if not year:
            year = _label_text(html, '年代')
        area = _label_text(html, '地区')
        actor = ''
        m = re.search(r'(?s)player_aaaa=.*?"vod_actor":"([^"]*)"', html)
        if m:
            actor = _unescape(m.group(1).strip())
        return {'list': [{
            'vod_id': slug,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': actor,
            'vod_director': '',
            'vod_remarks': genre,
            'vod_year': year,
            'vod_area': area,
            'vod_content': synopsis,
            'type_name': genre,
            'vod_tag': genre,
            'vod_play_from': '在线播放',
            'vod_play_url': '播放$chinaxjx:%s' % slug,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        if pg < 1:
            pg = 1
        kw = urllib.parse.quote(str(key).strip())
        html = _http_get(BASE + '/vodsearch/?wd=' + kw, referer=BASE + '/')
        items = _parse_cards(html)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        if raw.startswith('http') and '.m3u8' in raw:
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        slug = raw
        if slug.startswith('chinaxjx:'):
            slug = slug.split(':', 1)[1].strip()
        if slug.startswith('vodplay/'):
            slug = slug[len('vodplay/'):]
        if slug.startswith('c2/vodplay/'):
            slug = slug[len('c2/vodplay/'):]
        slug = slug.strip('/').strip()
        if not slug:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        html = _http_get(BASE + '/vodplay/' + slug, referer=BASE + '/')
        url = _parse_player_url(html)
        if not url:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        return {'parse': 0, 'playUrl': url, 'url': url, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', b'', {}]

    def isVideoFormat(self, url):
        u = str(url or '').lower().split('?')[0]
        return u.endswith(('.m3u8', '.mp4', '.mkv', '.webm', '.flv', '.ts'))

    def manualVideoCheck(self):
        return True

    def action(self, action, params=None):
        return {'code': 0, 'msg': 'ok'}
