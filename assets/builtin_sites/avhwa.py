import base64
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

BASE = 'https://avhwa.com'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

CATS = [
    ('vip', 'KVIP'),
    ('jvip', 'JVIP'),
    ('korean-porn', 'Korean Porn'),
    ('korean-bj', 'Korean BJ'),
    ('fc2ppv', 'FC2PPV'),
    ('jav', 'Uncensored'),
    ('ipcam', 'IPCAM'),
    ('toilet', 'Toilet'),
    ('voyeur-jp', 'Voyeur JP'),
    ('china', 'CHINA'),
    ('myfans', 'myfans'),
    ('asian-leak', 'Asian Leak'),
    ('upskirt', 'upskirt'),
    ('mib', 'MIB'),
]

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE


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
    for attempt in range(3):
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
        if attempt < 2:
            try:
                time.sleep(2)
            except Exception:
                pass
    return None


def _fetch(path, referer=None):
    if path.startswith('http'):
        return _http_get(path, referer=referer or (BASE + '/'))
    return _http_get(BASE + path, referer=referer or (BASE + '/'))


def _unescape(s):
    if not s:
        return ''
    return (s.replace('&nbsp;', ' ')
             .replace('&amp;', '&')
             .replace('&#039;', "'")
             .replace('&#39;', "'")
             .replace('&quot;', '"')
             .replace('&lt;', '<')
             .replace('&gt;', '>')
             .strip())


def _fix_url(raw):
    u = (raw or '').strip()
    if not u:
        return ''
    if u.startswith('http://') or u.startswith('https://'):
        return u
    if u.startswith('//'):
        return 'https:' + u
    if u.startswith('/'):
        return BASE + u
    return BASE + '/' + u


def _parse_cards(html):
    out = []
    if not html:
        return out
    seen = set()
    for block in html.split('<div class="thumb thumb_rel item')[1:]:
        end = block.find('<div class="thumb thumb_rel item')
        if end >= 0:
            block = block[:end]
        p = block.find('<a href="https://avhwa.com/video/')
        if p < 0:
            continue
        s = p + 9
        e = block[s:].find('"')
        if e < 0:
            continue
        href = block[s:s + e].strip()
        if not href or href in seen:
            continue
        seen.add(href)
        title = ''
        p2 = block.find('<div class="title">')
        if p2 >= 0:
            s2 = p2 + 19
            e2 = block[s2:].find('</div>')
            if e2 >= 0:
                title = _unescape(block[s2:s2 + e2])
        if not title:
            p2 = block.find('title="')
            if p2 >= 0:
                s2 = p2 + 7
                e2 = block[s2:].find('"')
                if e2 >= 0:
                    title = _unescape(block[s2:s2 + e2])
        if not title:
            continue
        if len(title) > 90:
            title = title[:90]
        cover = ''
        p2 = block.find('data-original="')
        if p2 >= 0:
            s2 = p2 + 15
            e2 = block[s2:].find('"')
            if e2 >= 0:
                cover = _fix_url(block[s2:s2 + e2])
        remark = ''
        p2 = block.find('<div class="time">')
        if p2 >= 0:
            s2 = p2 + 18
            e2 = block[s2:].find('</div>')
            if e2 >= 0:
                remark = block[s2:s2 + e2].strip()
        out.append({
            'vod_id': href,
            'vod_name': title,
            'vod_pic': cover,
            'vod_remarks': remark,
        })
    return out


def _meta_content(html, attr, key):
    marker = '%s="%s"' % (attr, key)
    p = html.find(marker)
    if p < 0:
        return ''
    after = html[p:]
    c = after.find('content="')
    if c < 0:
        return ''
    s = c + 9
    e = after[s:].find('"')
    if e < 0:
        return ''
    return _unescape(after[s:s + e])


def _extract_video_url(html):
    if not html:
        return ''
    marker = "video_url: '"
    p = html.find(marker)
    if p < 0:
        return ''
    s = p + len(marker)
    e = html[s:].find("'")
    if e < 0:
        return ''
    b64 = html[s:s + e].strip()
    if not b64:
        return ''
    try:
        pad = (-len(b64)) % 4
        raw = base64.b64decode(b64 + ('=' * pad))
        url = raw.decode('utf-8', 'replace').strip()
    except Exception:
        return ''
    if '/get_file/' in url and '.mp4' in url:
        return url
    return ''


def _resolve_redirect(url, referer):
    hdr = {'User-Agent': UA, 'Referer': referer}
    if _requests is not None:
        try:
            resp = _requests.head(url, headers=hdr, timeout=25, allow_redirects=False)
            loc = resp.headers.get('Location') or resp.headers.get('location')
            if loc:
                return urllib.parse.urljoin(url, loc.strip())
        except Exception:
            pass
        try:
            resp = _requests.get(url, headers=hdr, timeout=25, allow_redirects=False)
            loc = resp.headers.get('Location') or resp.headers.get('location')
            if loc:
                return urllib.parse.urljoin(url, loc.strip())
        except Exception:
            pass
        return url
    try:
        req = urllib.request.Request(url, headers=hdr, method='HEAD')
        opener = urllib.request.build_opener(NoRedirectHandler())
        with opener.open(req, timeout=25, context=CTX) as resp:
            loc = resp.headers.get('Location')
            if loc:
                return urllib.parse.urljoin(url, loc.strip())
    except Exception:
        pass
    try:
        req = urllib.request.Request(url, headers=hdr, method='GET')
        opener = urllib.request.build_opener(NoRedirectHandler())
        with opener.open(req, timeout=25, context=CTX) as resp:
            loc = resp.headers.get('Location')
            if loc:
                return urllib.parse.urljoin(url, loc.strip())
    except Exception:
        pass
    return url


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
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
        return 'AVHWA'

    def getDependence(self):
        return []

    def init(self, extend=None):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=False):
        cats = [{'type_id': cid, 'type_name': name} for cid, name in CATS]
        return {'class': cats, 'filters': {}}

    def homeVideoContent(self):
        html = _fetch('/categories/jav/')
        items = _parse_cards(html)
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        tid = _norm_id(tid).strip()
        pg = _norm_pg(pg)
        if pg < 1:
            pg = 1
        if not tid or tid == 'all':
            tid = 'jav'
        if pg <= 1:
            path = '/categories/%s/' % tid
        else:
            path = '/categories/%s/%d/' % (tid, pg)
        html = _fetch(path)
        items = _parse_cards(html)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        page_url = _norm_id(ids).strip()
        if not page_url:
            return _empty_detail(page_url)
        html = _fetch(page_url)
        if not html:
            return _empty_detail(page_url)
        title = _meta_content(html, 'property', 'og:title')
        if not title:
            return _empty_detail(page_url)
        cover = _fix_url(_meta_content(html, 'property', 'og:image'))
        desc = _meta_content(html, 'name', 'description')
        if desc == 'Default site description.':
            desc = ''
        if len(desc) > 400:
            desc = desc[:400]
        return {'list': [{
            'vod_id': page_url,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': '',
            'vod_year': '',
            'vod_area': '',
            'vod_content': desc,
            'type_name': '',
            'vod_tag': '',
            'vod_play_from': '在线播放',
            'vod_play_url': '正片$avhwa:%s' % page_url,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        if pg < 1:
            pg = 1
        kw = urllib.parse.quote_plus(str(key).strip())
        html = _fetch('/search/%s/' % kw)
        items = _parse_cards(html)[:60]
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        if raw.startswith('avhwa:'):
            raw = raw.split(':', 1)[1].strip()
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        if not raw:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        if raw.startswith('http') and '.mp4' in raw:
            url = _resolve_redirect(raw, BASE + '/')
            return {'parse': 0, 'playUrl': url, 'url': url, 'header': header}
        page_url = raw if raw.startswith('http') else BASE + raw
        html = _fetch(page_url, referer=BASE + '/')
        url = _extract_video_url(html)
        if not url:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        url = _resolve_redirect(url, BASE + '/')
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
