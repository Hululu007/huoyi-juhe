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


HOST = 'https://ddys.io'
IMG = 'https://img.ddys.io'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

CATS = [
    ('home', '首页'),
    ('movie', '电影'),
    ('series', '剧集'),
    ('variety', '综艺'),
    ('anime', '动漫'),
]

POSTER_RE = re.compile(r'<a href="/movie/([a-z0-9-]+)"[^>]*>\s*<img[^>]*src="([^"]+)"')
TITLE_RE = re.compile(r'<h3[^>]*>\s*<a[^>]*>([^<]+)</a>')
META_RE = re.compile(r'(\d{4})\s*·\s*(电影|剧集|综艺|动漫)')
RATING_RE = re.compile(r'badge-top-right">\s*([\d.]+)')
SOURCE_RE = re.compile(r"switchSource\(\d+,\s*'([^']+)',\s*'([^']+)'\)")
COVER_RE = re.compile(r'<img src="(https://img\.ddys\.io/[^"]+)"')
DESC_RE = re.compile(r'<meta name="description" content="([^"]*)"')
TITLE_TAG_RE = re.compile(r'<title>([^<]+)</title>')


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _strip_tags(s):
    if not s:
        return ''
    out = re.sub(r'<[^>]+>', '', s)
    return _html.unescape(out).replace('&nbsp;', ' ').strip()


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
            except http.client.IncompleteRead as ie:
                return ie.partial.decode('utf-8', 'ignore')
        except Exception:
            pass
        time.sleep(1)
    return ''


def _abs_url(path):
    if not path:
        return ''
    if path.startswith('http'):
        return path
    if path.startswith('/'):
        return HOST + path
    return HOST + '/' + path


def _cover_of_slug(slug):
    return '%s/movies/%s.webp' % (IMG, slug)


def _slug_of_url(url):
    return (url or '').rstrip('/').rsplit('/', 1)[-1]


def _parse_list(html):
    out = []
    seen = set()
    for m in POSTER_RE.finditer(html or ''):
        slug = m.group(1)
        if slug in seen:
            continue
        seen.add(slug)
        cover = m.group(2)
        window = html[m.end():m.end() + 2000]
        tm = TITLE_RE.search(window)
        title = _strip_tags(tm.group(1)) if tm else ''
        if not title:
            continue
        remark = ''
        mm = META_RE.search(window)
        if mm:
            remark = '%s · %s' % (mm.group(1), mm.group(2))
        rm = RATING_RE.search(window)
        if rm and rm.group(1) and rm.group(1) != '0.0':
            remark = (remark + ' ' + rm.group(1)).strip()
        out.append({
            'vod_id': _abs_url('/movie/' + slug),
            'vod_name': title,
            'vod_pic': cover,
            'vod_remarks': remark,
        })
    return out


def _parse_api_items(obj):
    out = []
    arr = []
    if isinstance(obj, dict):
        arr = obj.get('data') or []
    for it in arr:
        if not isinstance(it, dict):
            continue
        title = it.get('title') or ''
        url = it.get('url') or ''
        if not title or not url:
            continue
        slug = it.get('slug') or _slug_of_url(url)
        year = it.get('year')
        year = '' if year in (None, 0, '0') else str(year)
        typ = it.get('type') or ''
        rating = it.get('rating') or ''
        remark = ''
        if year:
            remark += year
        if typ:
            remark += (' · ' if remark else '') + typ
        if rating and rating != '0.0':
            remark += (' ' if remark else '') + rating
        out.append({
            'vod_id': _abs_url(url),
            'vod_name': title,
            'vod_pic': _cover_of_slug(slug),
            'vod_remarks': remark,
        })
    return out


def _parse_source_payload(payload, kind):
    out = []
    if kind != 'm3u8' or '.m3u8' not in payload:
        return out
    clean = payload.replace('\\t', '')
    if '$' not in clean:
        url = clean.strip()
        if '.m3u8' in url:
            out.append(('正片', url))
        return out
    for part in clean.split('#'):
        if '$' not in part:
            continue
        title, url = part.split('$', 1)
        title = title.strip()
        url = url.strip()
        if title and '.m3u8' in url:
            out.append((title, url))
    return out


def _parse_sources(html):
    sources = []
    for m in SOURCE_RE.finditer(html or ''):
        eps = _parse_source_payload(m.group(1), m.group(2))
        if eps:
            sources.append(eps)
    return sources


def _m3u8_live(url, referer):
    try:
        req = urllib.request.Request(url, headers={'User-Agent': UA, 'Accept': '*/*', 'Referer': referer})
        with urllib.request.urlopen(req, timeout=15, context=_ctx()) as resp:
            if resp.status != 200:
                return False
            return '#EXTM3U' in resp.read(8192).decode('utf-8', 'replace')
    except Exception:
        return False


def _pick_source(sources, referer):
    if not sources:
        return []
    for eps in sources:
        if eps and _m3u8_live(eps[0][1], referer):
            return eps
    return sources[0]


def _clean_detail_title(raw):
    t = (raw or '').strip()
    p = t.find('免费在线观看')
    if p >= 0:
        t = t[:p].strip()
    p = t.find(' - 低端影视')
    if p >= 0:
        t = t[:p].strip()
    return t


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
        return '低端影视'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cats(self):
        return list(CATS)

    def _catalog(self, tid, pg):
        if tid == 'home':
            txt = _http_get(HOST + '/api/hot-movies', referer=HOST + '/')
            try:
                obj = json.loads(txt or '{}')
            except Exception:
                obj = {}
            return _parse_api_items(obj)
        if pg <= 1:
            url = '%s/%s' % (HOST, tid)
        else:
            url = '%s/%s/page/%s' % (HOST, tid, pg)
        html = _http_get(url, referer=HOST + '/')
        return _parse_list(html)

    def homeContent(self, filter=''):
        cats = self._cats()
        items = self._catalog('home', 1)
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in cats],
            'list': items,
        }

    def homeVideoContent(self):
        items = self._catalog('home', 1)
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        items = self._catalog(tid, pg)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        html = _http_get(nid, referer=HOST + '/')
        if not html:
            return {'list': []}
        tm = TITLE_TAG_RE.search(html)
        title = _clean_detail_title(tm.group(1)) if tm else ''
        if not title:
            return {'list': []}
        slug = _slug_of_url(nid)
        cm = COVER_RE.search(html)
        cover = cm.group(1) if cm else _cover_of_slug(slug)
        dm = DESC_RE.search(html)
        synopsis = _strip_tags(dm.group(1))[:400] if dm else ''
        sources = _parse_sources(html)
        if not sources:
            return {'list': []}
        eps = _pick_source(sources, nid)
        play_url = '#'.join('%s$ddys:%s' % (t, u) for t, u in eps)
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
            'vod_play_url': play_url,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        url = '%s/api/search-suggest?q=%s' % (HOST, urllib.parse.quote(key or ''))
        txt = _http_get(url, referer=HOST + '/')
        try:
            obj = json.loads(txt or '{}')
        except Exception:
            obj = {}
        items = _parse_api_items(obj)[:60]
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        if raw.startswith('ddys:'):
            raw = raw[5:]
        header = {'User-Agent': UA, 'Referer': HOST + '/'}
        url = ''
        if '.m3u8' in raw:
            url = raw.rsplit('$', 1)[-1] if '$' in raw else raw
        elif raw.startswith('http'):
            html = _http_get(raw, referer=HOST + '/')
            if html:
                tm = TITLE_TAG_RE.search(html)
                sources = _parse_sources(html)
                if sources:
                    eps = _pick_source(sources, raw)
                    if eps:
                        url = eps[0][1]
        return {'parse': 0, 'playUrl': url, 'url': url, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', '']

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
