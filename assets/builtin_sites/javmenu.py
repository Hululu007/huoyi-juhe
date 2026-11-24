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


BASE = "https://javmenu.com"
KEY = "javmenu"
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
CATS = [
    ("censored/online", "有碼"),
    ("uncensored", "無碼"),
    ("western", "歐美"),
    ("fc2", "FC2"),
    ("uncensored/filter", "無碼"),
    ("western/filter", "歐美"),
    ("fc2/filter", "FC2"),
    ("rank/censored/day", "日榜"),
    ("rank/censored/week", "週榜"),
    ("rank/censored/month", "月榜"),
    ("rank/censored/actress", "女優榜"),
    ("uncensored/actor", "無碼"),
    ("western/actor", "歐美"),
    ("series/censored", "有碼"),
    ("series/uncensored", "無碼"),
    ("series/western", "歐美"),
    ("games", "遊戲"),
    ("zh_TW", "繁體中文"),
    ("zh", "简体中文"),
    ("en", "English"),
    ("ja", "日本語"),
    ("ko", "한국어"),
    ("es", "español"),
    ("fr", "français"),
    ("ru", "русский"),
    ("uncensored/online", "無碼"),
    ("censored", "有碼"),
    ("censored/filter", "有碼"),
    ("censored/actor", "有碼"),
    ("code/LUXU", "LUXU"),
    ("code/ARA", "ARA"),
    ("code/SIRO", "SIRO"),
    ("western/online", "歐美"),
    ("fc2/online", "FC2"),
    ("hanime/online", "成人動畫"),
    ("chinese/online", "國產"),
    ("hanime", "成人動畫"),
    ("de", "Deutsch"),
    ("chinese", "國產"),
]
CAT_URL = "https://javmenu.com/{cateId}"
SEARCH_URL = "https://javmenu.com/search?wd={wd}"
DETAIL_HREF_RE = re.compile(r"/[A-Za-z0-9_]+(?:-[A-Za-z0-9_]+)+/?(?:[?#].*)?$")
PLAY_HREF_RE = re.compile("")
MEDIA_RE = re.compile("(?:https?:)?//[^\\s\"'<>]+\\.(?:m3u8|mp4)(?:\\?[^\\s\"'<>]*)?")
ANCHOR_RE = re.compile("<a[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>", re.S)
IMG_RE = re.compile("<img[^>]*?(?:src|data-src|data-original)=\"([^\"]+)\"", re.I)
IMG_DATA_RE = re.compile("(?:data-src|data-original)\\s*=\\s*\"([^\"]+)\"", re.I)
IMG_SRC_RE = re.compile("(?<![\\w-])src\\s*=\\s*\"([^\"]+)\"", re.I)
H1_RE = re.compile("<h1[^>]*>(.*?)</h1>", re.S)
TITLE_TAG_RE = re.compile("<title[^>]*>(.*?)</title>", re.S)
DESC_RE = re.compile("<meta[^>]*name=[\"']description[\"'][^>]*content=[\"']([^\"']*)[\"']", re.I)
OG_DESC_RE = re.compile("<meta[^>]*property=[\"']og:description[\"'][^>]*content=[\"']([^\"']*)[\"']", re.I)
OG_IMAGE_RE = re.compile("<meta[^>]*property=[\"']og:image[\"'][^>]*content=[\"']([^\"']*)[\"']", re.I)
TAG_STRIP_RE = re.compile("<[^>]+>")
def _ctx():
    return ssl._create_unverified_context()


def _unescape(text):
    text = _html.unescape(text or '')
    return re.sub(r'\s+', ' ', text).strip()


def _http_get(url, referer='', timeout=15):
    headers = {
        'User-Agent': UA,
        'Accept': 'text/html,application/json,*/*',
        'Accept-Language': 'zh-CN,zh;q=0.9',
        'Referer': referer or BASE + '/',
    }
    for attempt in range(3):
        if _HAS_REQ:
            try:
                resp = requests.get(url, headers=headers, timeout=timeout, verify=False)
                if resp.status_code in (200, 206):
                    resp.encoding = resp.apparent_encoding or 'utf-8'
                    return resp.text
            except Exception:
                pass
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=timeout, context=_ctx()) as resp:
                raw = resp.read()
                if raw[:2] == b'\x1f\x8b':
                    raw = gzip.decompress(raw)
                enc = resp.headers.get_content_charset() or 'utf-8'
                return raw.decode(enc, errors='replace')
        except urllib.error.HTTPError as e:
            try:
                raw = e.read()
                if raw[:2] == b'\x1f\x8b':
                    raw = gzip.decompress(raw)
                return raw.decode('utf-8', errors='replace')
            except Exception:
                return ''
        except (http.client.IncompleteRead, Exception):
            if attempt < 2:
                time.sleep(0.5)
    return ''


def _norm_id(ids):
    if isinstance(ids, list):
        return str(ids[0]) if ids else ''
    return str(ids or '').strip()


def _norm_pg(pg):
    try:
        return max(1, int(pg))
    except Exception:
        return 1

def _parse_cards(html, base):
    anchors = list(ANCHOR_RE.finditer(html or ''))
    covers = {}
    for m in anchors:
        href = m.group(1).strip()
        if not DETAIL_HREF_RE.search(href):
            continue
        url = urllib.parse.urljoin(base + '/', href)
        inner = m.group(2)
        dm = IMG_DATA_RE.search(inner)
        if dm:
            covers[url] = urllib.parse.urljoin(base + '/', dm.group(1).strip())
            continue
        if url not in covers:
            sm = IMG_SRC_RE.search(inner)
            if sm:
                covers[url] = urllib.parse.urljoin(
                    base + '/', sm.group(1).strip())
    out = []
    seen = set()
    for m in anchors:
        href = m.group(1).strip()
        if not DETAIL_HREF_RE.search(href):
            continue
        url = urllib.parse.urljoin(base + '/', href)
        if url in seen:
            continue
        title = _unescape(re.sub(TAG_STRIP_RE, ' ', m.group(2)))
        if not title:
            continue
        seen.add(url)
        out.append({'vod_id': url, 'vod_name': title,
                    'vod_pic': covers.get(url, ''), 'vod_remarks': ''})
    return out


def _parse_play_links(html, base):
    out = []
    seen = set()
    for m in ANCHOR_RE.finditer(html or ''):
        href = m.group(1).strip()
        if not PLAY_HREF_RE.search(href):
            continue
        url = urllib.parse.urljoin(base + '/', href)
        if url in seen:
            continue
        seen.add(url)
        name = _unescape(re.sub(TAG_STRIP_RE, ' ', m.group(2)))
        out.append((name, url))
    return out


def _detail_fields(html):
    title = ''
    hm = H1_RE.search(html or '')
    if hm:
        title = _unescape(re.sub(TAG_STRIP_RE, ' ', hm.group(1)))
    if not title:
        tm = TITLE_TAG_RE.search(html or '')
        if tm:
            title = _unescape(re.sub(TAG_STRIP_RE, ' ', tm.group(1)))
    cover = ''
    om = OG_IMAGE_RE.search(html or '')
    if om:
        cover = om.group(1).strip()
    if not cover:
        im = IMG_RE.search(html or '')
        if im:
            cover = im.group(1).strip()
    if cover.startswith('//'):
        cover = 'https:' + cover
    synopsis = ''
    dm = DESC_RE.search(html or '')
    if dm:
        synopsis = _unescape(dm.group(1))
    if not synopsis:
        om2 = OG_DESC_RE.search(html or '')
        if om2:
            synopsis = _unescape(om2.group(1))
    return title, cover, synopsis


class Spider(BaseSpider):
    def getName(self):
        return "JAV目錄大全"

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _catalog(self, tid, pg):
        url = CAT_URL.replace('{cateId}', str(tid)).replace('{catePg}', str(pg))
        return _parse_cards(_http_get(url, referer=BASE + '/'), BASE)

    def homeContent(self, filter=''):
        items = []
        if CATS:
            items = self._catalog(CATS[0][0], 1)
        return {'class': [{'type_id': tid, 'type_name': name} for tid, name in CATS], 'list': items}

    def homeVideoContent(self):
        items = []
        if CATS:
            items = self._catalog(CATS[0][0], 1)
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        items = self._catalog(tid, pg)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        url = _norm_id(ids)
        if not url:
            return {'list': []}
        if not url.startswith('http'):
            url = urllib.parse.urljoin(BASE + '/', url)
        html = _http_get(url, referer=BASE + '/')
        if not html:
            return {'list': []}
        title, cover, synopsis = _detail_fields(html)
        if not title:
            return {'list': []}
        play_url = '正片$' + KEY + ':' + url
        return {'list': [{'vod_id': url, 'vod_name': title, 'vod_pic': cover, 'vod_actor': '', 'vod_director': '', 'vod_remarks': '', 'vod_year': '', 'vod_area': '', 'vod_content': synopsis, 'type_name': '', 'vod_tag': '', 'vod_play_from': '在线播放', 'vod_play_url': play_url, 'stills': []}]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        url = SEARCH_URL.replace('{wd}', urllib.parse.quote(key or ''))
        items = _parse_cards(_http_get(url, referer=BASE + '/'), BASE)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        prefix = KEY + ':'
        if raw.startswith(prefix):
            raw = raw[len(prefix):]
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        stream = ''
        if raw.startswith('http'):
            html = _http_get(raw, referer=BASE + '/')
            m = MEDIA_RE.search(html or '')
            if m:
                stream = m.group(0)
                if stream.startswith('//'):
                    stream = 'https:' + stream
                header['Referer'] = stream
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
