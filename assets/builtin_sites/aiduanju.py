import gzip
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

BASES = ['https://ai.aiduanjuwang8.cc', 'https://wap.aiduanjuwang6.cc']
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

FALLBACK_CATS = [
    ('119', '推荐'),
    ('370', '黄瓜资源'),
    ('329', '仓房资源'),
    ('286', '玉兔资源'),
    ('358', '番茄资源'),
    ('244', '155资源'),
]

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

CACHE = {}
CATS_TTL = 3600
_CUR_BASE = [BASES[0]]


def _now():
    return time.time()


def _http_get(url, referer=None, timeout=25):
    hdr = {
        'User-Agent': UA,
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9',
        'Accept-Encoding': 'gzip, deflate',
        'Connection': 'keep-alive',
    }
    if referer:
        hdr['Referer'] = referer
    for attempt in range(2):
        text = None
        if _requests is not None:
            try:
                resp = _requests.get(url, headers=hdr, timeout=timeout)
                if resp.status_code == 200:
                    text = resp.content.decode('utf-8', 'replace')
            except Exception:
                text = None
        if text is None:
            try:
                req = urllib.request.Request(url, headers=hdr)
                with urllib.request.urlopen(req, timeout=timeout, context=CTX) as resp:
                    if resp.status == 200:
                        data = resp.read()
                        enc = (resp.headers.get('Content-Encoding') or '').lower()
                        if enc == 'gzip' or data[:2] == b'\x1f\x8b':
                            try:
                                data = gzip.decompress(data)
                            except Exception:
                                pass
                        text = data.decode('utf-8', 'replace')
            except Exception:
                text = None
        if text is not None:
            return text
        if attempt < 1:
            try:
                time.sleep(1)
            except Exception:
                pass
    return None


def _fetch(path, referer=None):
    bases = [_CUR_BASE[0]] + [b for b in BASES if b != _CUR_BASE[0]]
    for base in bases:
        text = _http_get(base + path, referer=referer or (base + '/rukou/'))
        if text is not None:
            _CUR_BASE[0] = base
            return text
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
        return _CUR_BASE[0] + u
    return u


def _parse_cards(html):
    out = []
    if not html:
        return out
    pat = re.compile(
        r'<div class="vod">.*?<img[^>]+data-original="([^"]+)"[^>]*>'
        r'.*?<div class="vod-txt"[^>]*>\s*'
        r'<a href="/rukou/index\.php/vod/detail/id/(\d+)\.html"[^>]*>([^<]+)</a>',
        re.S)
    seen = set()
    for m in pat.finditer(html):
        vid = m.group(2).strip()
        if not vid or vid in seen:
            continue
        seen.add(vid)
        title = _unescape(m.group(3).strip())
        if not title:
            continue
        out.append({
            'vod_id': vid,
            'vod_name': title,
            'vod_pic': _fix_url(m.group(1)),
            'vod_remarks': '',
        })
    return out


def _fetch_categories():
    v = CACHE.get('cats')
    if v and _now() - v[0] < v[2]:
        return v[1]
    cats = []
    html = _fetch('/rukou/')
    if html:
        pat = re.compile(
            r'<dt><a href="/rukou/index\.php/vod/type/id/(\d+)\.html"><b>([^<]+)</b></a></dt>')
        seen = set()
        for m in pat.finditer(html):
            cid = m.group(1).strip()
            name = _unescape(m.group(2).strip())
            if not name or cid in seen:
                continue
            seen.add(cid)
            cats.append((cid, name))
    ttl = CATS_TTL
    if not cats:
        cats = list(FALLBACK_CATS)
        ttl = 300
    if len(CACHE) > 20:
        CACHE.clear()
    CACHE['cats'] = (_now(), cats, ttl)
    return cats


def _parse_cover(html, title):
    for m in re.finditer(r'<img src="([^"]+)" title="([^"]*)"', html):
        if m.group(2).strip() == title:
            return _fix_url(m.group(1))
    m = re.search(r'<img[^>]+src="(https?://[^"]+/upload/vod/[^"]+)"', html)
    if m:
        return _fix_url(m.group(1))
    return ''


def _parse_player_url(html):
    if not html:
        return ''
    m = re.search(r'(?s)player_aaaa=.*?"url":"([^"]+)"', html)
    if not m:
        return ''
    return _unescape(m.group(1).strip())


def _follow_episodes(nid, start_eps, cap=30):
    eps = list(start_eps)
    seen = set(eps)
    if not eps:
        return eps
    cur = eps[-1]
    while len(eps) < cap:
        html = _fetch('/rukou/index.php/vod/play/id/%s/sid/1/nid/%s.html' % (nid, cur))
        if not html:
            break
        m = re.search(r'"link_next":"([^"]*)"', html)
        nxt = _unescape(m.group(1)) if m else ''
        nm = re.search(r'/nid/(\d+)\.html', nxt)
        if not nm:
            break
        nxt_nid = nm.group(1)
        if nxt_nid in seen:
            break
        seen.add(nxt_nid)
        eps.append(nxt_nid)
        cur = nxt_nid
    return eps


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
        return 'AI短剧网'

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
        html = _fetch('/rukou/')
        items = _parse_cards(html)
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        tid = _norm_id(tid)
        pg = _norm_pg(pg)
        if pg < 1:
            pg = 1
        if pg <= 1:
            path = '/rukou/index.php/vod/type/id/%s.html' % tid
        else:
            path = '/rukou/index.php/vod/type/id/%s/page/%d.html' % (tid, pg)
        html = _fetch(path)
        items = _parse_cards(html)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        raw = _norm_id(ids)
        nid = ''.join([ch for ch in raw if ch.isdigit()])
        if not nid:
            return _empty_detail(raw)
        html = _fetch('/rukou/index.php/vod/detail/id/%s.html' % nid)
        if not html:
            return _empty_detail(nid)
        tm = re.search(r'(?s)<div class="title"><h3>([^<]+)</h3></div>', html)
        title = _unescape(tm.group(1).strip()) if tm else ''
        if not title:
            return _empty_detail(nid)
        cover = _parse_cover(html, title)
        dm = re.search(r'<meta name="description"[^>]*content="([^"]+)"', html)
        synopsis = _unescape(dm.group(1).strip()) if dm else ''
        eps = sorted(set(re.findall(
            r'/rukou/index\.php/vod/play/id/\d+/sid/1/nid/(\d+)\.html', html)),
            key=lambda x: int(x))
        if not eps:
            eps = ['1']
        eps = _follow_episodes(nid, eps)
        plays = ['第%s集$aiduanju:%s-1-%s' % (ep, nid, ep) for ep in eps]
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
            'vod_play_url': '#'.join(plays),
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        if pg < 1:
            pg = 1
        kw = urllib.parse.quote_plus(str(key).strip())
        html = _fetch('/rukou/index.php/vod/search/wd/%s.html' % kw)
        items = _parse_cards(html)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        if raw.startswith('aiduanju:'):
            raw = raw.split(':', 1)[1].strip()
        if raw.startswith('http'):
            header = {'User-Agent': UA}
            if raw.endswith('.m3u8') or raw.endswith('.mp4'):
                return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        parts = raw.split('-')
        if len(parts) != 3:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        vid, sid, ep = parts[0], parts[1], parts[2]
        if not vid.isdigit() or not ep.isdigit():
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        play_page = '/rukou/index.php/vod/play/id/%s/sid/%s/nid/%s.html' % (vid, sid, ep)
        html = _fetch(play_page)
        m3u8 = _parse_player_url(html)
        header = {'User-Agent': UA}
        if not m3u8:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        return {'parse': 0, 'playUrl': m3u8, 'url': m3u8, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', b'', {}]

    def isVideoFormat(self, url):
        u = str(url or '').lower().split('?')[0]
        return u.endswith(('.m3u8', '.mp4', '.mkv', '.webm', '.flv', '.ts'))

    def manualVideoCheck(self):
        return True

    def action(self, action, params=None):
        return {'code': 0, 'msg': 'ok'}
