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


BASE = 'https://hgaidjzun.lol'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

CATS = [
    '国产视频',
    '每日最新',
    '国产自拍',
    '国产偷拍',
    '国产传媒',
    '日本无码',
    '日本有码',
    '中文字幕',
    '人妻熟女',
    'AV解说',
    '主播大秀',
    '网曝黑料',
]

CARD_RE = re.compile(r'<a href="/info/id/(\d+)"[^>]*>\s*<img src="([^"]+)"[^>]*>\s*<p class="video-title">(.*?)</p>', re.S)
CAT_RE = re.compile(r'href="/hunt/([^"/]+)\.html"[^>]*>([^<]+)</a>')
PLAY_RE = re.compile(r"playUrl\s*=\s*'([^']+)'")
TITLE_TAG_RE = re.compile(r'<title>(.*?)</title>')
COVER_RE = re.compile(r'<img[^>]*src="(https?://[^"]+/upload/vod/[^"]+)"')
DESC_RE = re.compile(r'<meta name="description"[^>]*content="([^"]+)"')


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _unescape(s):
    if not s:
        return ''
    return _html.unescape(s).replace('&nbsp;', ' ').strip()


def _http_get(url, referer=None, timeout=60):
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
        time.sleep(2)
    return ''


def _parse_cards(html):
    out = []
    seen = set()
    for m in CARD_RE.finditer(html or ''):
        vid = m.group(1).strip()
        if not vid or vid in seen:
            continue
        title = _unescape(m.group(3))
        if not title:
            continue
        seen.add(vid)
        out.append({
            'vod_id': vid,
            'vod_name': title,
            'vod_pic': m.group(2).strip(),
            'vod_remarks': '',
        })
    return out


def _parse_categories(html):
    out = []
    seen = set()
    for m in CAT_RE.finditer(html or ''):
        cid = m.group(1).strip()
        name = m.group(2).strip()
        if not name or cid in seen:
            continue
        seen.add(cid)
        out.append((cid, name))
    return out


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
        return '黄果AI短剧'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cats(self):
        cats = _parse_categories(_http_get(BASE, referer=BASE + '/'))
        if cats:
            return cats
        return [(name, name) for name in CATS]

    def _catalog(self, tid, pg):
        if pg <= 1:
            url = '%s/hunt/%s.html' % (BASE, tid)
        else:
            url = '%s/hunt/%s/h/%s.html' % (BASE, tid, pg)
        return _parse_cards(_http_get(url, referer=BASE + '/'))

    def homeContent(self, filter=''):
        cats = self._cats()
        items = []
        if cats:
            items = self._catalog(cats[0][0], 1)
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in cats],
            'list': items,
        }

    def homeVideoContent(self):
        cats = self._cats()
        items = []
        if cats:
            items = self._catalog(cats[0][0], 1)
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        items = self._catalog(tid, pg)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        nid = _norm_id(ids).strip().lstrip('/')
        if nid.startswith('info/id/'):
            nid = nid[len('info/id/'):]
        if nid.endswith('.html'):
            nid = nid[:-5]
        nid = nid.rstrip('/')
        if not nid:
            return {'list': []}
        html = _http_get('%s/info/id/%s' % (BASE, nid), referer=BASE + '/')
        if not html:
            return {'list': []}
        tm = TITLE_TAG_RE.search(html)
        title = _unescape(tm.group(1)) if tm else ''
        if '-黄果AI短剧' in title:
            title = title[:title.find('-黄果AI短剧')]
        if not title:
            return {'list': []}
        cm = COVER_RE.search(html)
        cover = cm.group(1) if cm else ''
        dm = DESC_RE.search(html)
        synopsis = _unescape(dm.group(1)) if dm else ''
        play_html = _http_get('%s/play/id/%s' % (BASE, nid), referer=BASE + '/')
        m3u8 = ''
        if play_html:
            m = PLAY_RE.search(play_html)
            if m:
                m3u8 = m.group(1).strip()
        if not m3u8:
            return {'list': []}
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
            'vod_play_url': '播放$hgaidj:%s' % m3u8,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        url = '%s/hunt/%s' % (BASE, urllib.parse.quote(key or ''))
        items = _parse_cards(_http_get(url, referer=BASE + '/'))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        if '$' in raw:
            raw = raw.split('$', 1)[1].strip()
        if raw.startswith('hgaidj:'):
            raw = raw[len('hgaidj:'):]
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        m3u8 = raw if raw.startswith('http') else ''
        return {'parse': 0, 'playUrl': m3u8, 'url': m3u8, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', '']

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
