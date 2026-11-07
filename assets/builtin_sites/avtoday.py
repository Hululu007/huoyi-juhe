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

BASE = 'https://avtoday.io'
UA = 'Mozilla/5.0 (Linux; Android 14; HarmonyOS; HUAWEI) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36'

CATS = [
    ('中文字幕', '%E4%B8%AD%E6%96%87%E5%AD%97%E5%B9%95'),
    ('無碼', '%E7%84%A1%E7%A2%BC'),
    ('絲襪', '%E7%B5%B2%E8%A5%AA'),
    ('FC2', 'FC2'),
    ('多人', '%E5%A4%9A%E4%BA%BA'),
    ('長腿', '%E9%95%B7%E8%85%BF'),
    ('巨乳', '%E5%B7%A8%E4%B9%B3'),
    ('自慰', '%E8%87%AA%E6%85%B0'),
    ('素人', '%E7%B4%A0%E4%BA%BA'),
    ('足交', '%E8%B6%B3%E4%BA%A4'),
    ('潮吹', '%E6%BD%AE%E5%90%B9'),
    ('痴女', '%E7%97%B4%E5%A5%B3'),
    ('熟女', '%E7%86%9F%E5%A5%B3'),
    ('制服', '%E5%88%B6%E6%9C%8D'),
    ('人妻', '%E4%BA%BA%E5%A6%BB'),
    ('泡泡浴', '%E6%B3%A1%E6%B3%A1%E6%B5%B4'),
]
ENC = dict(CATS)

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

TIMEOUT = 30


def _now():
    return time.time()


def _http_get(url, referer=None, timeout=TIMEOUT):
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


_CARD_RE = re.compile(r'data-spcode="([^"]+)"(.*?)video-title truncate">\s*<a[^>]*>(.*?)</a>', re.S)
_COVER_RE = re.compile(r"background:\s*url\('([^']+)'\)")
_DUR_RE = re.compile(r'video-duration">\s*([^<]+?)\s*<')

_TITLE_RE = re.compile(r'<meta property="og:title"[^>]*content="([^"]+)"')
_COVER_META_RE = re.compile(r'<meta property="og:image"[^>]*content="([^"]+)"')
_DESC_RE = re.compile(r'<meta name="description"[^>]*content="([^"]+)"')
_TITLE_TAG_RE = re.compile(r'<title[^>]*>(.*?)</title>', re.S)


def _parse_cards(html):
    out = []
    if not html:
        return out
    seen = set()
    for m in _CARD_RE.finditer(html):
        code = m.group(1).strip()
        if not code or code in seen:
            continue
        middle = m.group(2)
        title = _unescape(m.group(3))
        if not title:
            continue
        seen.add(code)
        cover = ''
        cm = _COVER_RE.search(middle)
        if cm:
            cover = _fix_url(cm.group(1))
        remark = ''
        dm = _DUR_RE.search(middle)
        if dm:
            remark = dm.group(1).strip()
        out.append({
            'vod_id': '/cht/video/%s.html' % code,
            'vod_name': title,
            'vod_pic': cover,
            'vod_remarks': remark,
        })
    return out


def _meta_content(html, pattern):
    if not html:
        return ''
    m = pattern.search(html)
    if not m:
        return ''
    return _unescape(m.group(1))


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
        return 'AV Today'

    def getDependence(self):
        return []

    def init(self, extend=None):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=False):
        cats = [{'type_id': name, 'type_name': name} for name, _ in CATS]
        return {'class': cats, 'filters': {}}

    def homeVideoContent(self):
        html = _fetch('/cht/index.html')
        items = _parse_cards(html)
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        tid = _norm_id(tid).strip()
        pg = _norm_pg(pg)
        if pg < 1:
            pg = 1
        enc = ENC.get(tid)
        if not enc:
            enc = ENC.get('巨乳')
        if pg <= 1:
            path = '/cht/catalog/%s.html' % enc
        else:
            path = '/cht/catalog/%s.html?page=%d' % (enc, pg)
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
        title = _meta_content(html, _TITLE_RE)
        if not title:
            title = _meta_content(html, _TITLE_TAG_RE)
            if ' | AVToday' in title:
                title = title.split(' | AVToday', 1)[0].strip()
        if not title:
            return _empty_detail(page_url)
        cover = _fix_url(_meta_content(html, _COVER_META_RE))
        desc = _meta_content(html, _DESC_RE)
        code = page_url.rsplit('/', 1)[-1]
        if code.endswith('.html'):
            code = code[:-5]
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
            'vod_play_url': '播放$/player?s=%s' % code,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        if pg < 1:
            pg = 1
        kw = urllib.parse.quote_plus(str(key).strip())
        html = _fetch('/search?s=' + kw)
        items = _parse_cards(html)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        if not raw:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        if raw.startswith('http'):
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        page_url = raw if raw.startswith('/') else '/' + raw
        html = _fetch(page_url, referer=BASE + '/')
        url = ''
        if html:
            m = re.search(r"var m3u8_url\s*=\s*'([^']*)'", html)
            if m and m.group(1).strip():
                url = m.group(1).strip()
            if not url:
                m = re.search(r"var video_link\s*=\s*'([^']*)'", html)
                if m and m.group(1).strip():
                    url = m.group(1).strip()
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
