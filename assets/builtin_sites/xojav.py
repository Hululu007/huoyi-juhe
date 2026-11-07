import gzip
import html as _html
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

BASE = 'https://xojav.tv'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

CATS = [
    ('chinese-subtitle', '中文字幕'),
    ('uncensored', '無碼解放'),
    ('taiwan-av', '台灣AV'),
    ('jav', '日本AV'),
    ('uniform', '制服誘惑'),
    ('roleplay', '角色劇情'),
    ('pantyhose', '絲襪'),
    ('sex-only', '直接開啪'),
    ('bdsm', '主奴調教'),
    ('groupsex', '多P群交'),
    ('intrusion', '進犯'),
    ('pov', '男友視角'),
    ('hixxen-cam', '流出'),
    ('lesbian', '女同歡愉'),
]

try:
    import requests
    _HAS_REQ = True
except Exception:
    _HAS_REQ = False

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

LINK_RE = re.compile(r'href="https://xojav\.tv/videos/([^"]+)"')
IMG_RE = re.compile(r'data-src="([^"]+)"')
ALT_RE = re.compile(r'alt="([^"]+)"')
DUR_RE = re.compile(r'card-video__duration">([^<]+)<')
CAT_RE = re.compile(r'href="https://xojav\.tv/categories/([a-z0-9-]+)"[^>]*>(.*?)</a>', re.S)
TAG_RE = re.compile(r'<[^>]+>')
COUNT_RE = re.compile(r'^\s*\d+\s*部影片\s*')
TOTAL_RE = re.compile(r'(\d+)\s*部影片')
TITLE_RE = re.compile(r'(?s)<title[^>]*>(.*?)</title>')
OGIMG_RE = re.compile(r'<meta property="og:image"[^>]*content="([^"]+)"')
DESC_RE = re.compile(r'<meta name="description"[^>]*content="([^"]+)"')
TAGLINK_RE = re.compile(r'href="https://xojav\.tv/categories/[a-z0-9-]+"[^>]*>([^<]+)<')
STREAM_RE = re.compile(r"var stream = '([^']+\.m3u8[^']*)'")


def _http_get(url, referer=None, timeout=25):
    hdr = {
        'User-Agent': UA,
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Referer': referer or (BASE + '/'),
        'Accept-Encoding': 'gzip, deflate',
    }
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
    return ''


def _unescape(s):
    if not s:
        return ''
    return _html.unescape(s).strip()


def _parse_cards(html):
    positions = []
    for m in LINK_RE.finditer(html or ''):
        positions.append((m.start(), m.group(1)))
    out = []
    seen = set()
    for i, (start, code) in enumerate(positions):
        vid = '/videos/' + code
        if vid in seen:
            continue
        if i + 1 < len(positions):
            stop = positions[i + 1][0]
        else:
            stop = min(start + 8000, len(html))
        if stop <= start:
            continue
        chunk = html[start:stop]
        ma = ALT_RE.search(chunk)
        title = _unescape(ma.group(1)) if ma else ''
        if not title:
            continue
        seen.add(vid)
        mi = IMG_RE.search(chunk)
        cover = mi.group(1) if mi else ''
        if not cover or 'video-placeholder' in cover:
            cover = 'https://cdn.18jav.tv/storage/%s/320_180.jpg' % code
        md = DUR_RE.search(chunk)
        remark = md.group(1).strip() if md else ''
        out.append({
            'vod_id': vid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_remarks': remark,
        })
    return out


def _parse_categories(html):
    out = []
    seen = set()
    for m in CAT_RE.finditer(html or ''):
        cid = m.group(1)
        name = TAG_RE.sub(' ', m.group(2))
        name = COUNT_RE.sub('', name)
        name = ' '.join(name.split())
        if not name or cid in seen:
            continue
        seen.add(cid)
        out.append({'type_id': cid, 'type_name': name})
    return out


def _encode_path(s):
    out = []
    for b in str(s).encode('utf-8'):
        if (65 <= b <= 90) or (97 <= b <= 122) or (48 <= b <= 57) or b in (45, 95, 46, 126):
            out.append(chr(b))
        else:
            out.append('%%%02X' % b)
    return ''.join(out)


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
        return 'XOJAV'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=''):
        html = _http_get(BASE + '/categories', referer=BASE + '/')
        cats = _parse_categories(html)
        if not cats:
            cats = [{'type_id': tid, 'type_name': name} for tid, name in CATS]
        items = self._catalog(cats[0]['type_id'], 1)
        return {'class': cats, 'filters': {}, 'list': items}

    def homeVideoContent(self):
        items = self._catalog('jav', 1)
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def _catalog(self, tid, pg):
        slug = tid if tid else 'jav'
        if pg <= 1:
            url = '%s/categories/%s/' % (BASE, slug)
        else:
            params = {
                'mode': 'async',
                'function': 'get_block',
                'block_id': 'list_videos_common_videos_list',
                'sort_by': 'release_at',
                'from': str(pg),
            }
            url = '%s/categories/%s/?%s' % (BASE, slug, urllib.parse.urlencode(params))
        html = _http_get(url, referer=BASE + '/')
        return _parse_cards(html)

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        items = self._catalog(_norm_id(tid), pg)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        raw = _norm_id(ids)
        if raw.startswith('http'):
            url = raw
        elif raw.startswith('/'):
            url = BASE + raw
        else:
            url = BASE + '/' + raw
        html = _http_get(url, referer=BASE + '/')
        if not html:
            return {'list': []}
        mt = TITLE_RE.search(html)
        title = _unescape(mt.group(1)) if mt else ''
        if ' | ' in title:
            title = title[:title.find(' | ')].strip()
        mi = OGIMG_RE.search(html)
        cover = mi.group(1) if mi else ''
        md = DESC_RE.search(html)
        synopsis = _unescape(md.group(1)) if md else ''
        tags = []
        for m in TAGLINK_RE.finditer(html):
            t = m.group(1).strip()
            if t and t not in tags:
                tags.append(t)
        ms = STREAM_RE.search(html)
        stream = ms.group(1) if ms else ''
        if not title or not stream:
            return {'list': []}
        parts = []
        if synopsis:
            parts.append(synopsis)
        if tags:
            parts.append('标签：' + '、'.join(tags))
        return {'list': [{
            'vod_id': raw,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': '',
            'vod_year': '',
            'vod_area': '',
            'vod_content': '\n'.join(parts),
            'type_name': ' / '.join(tags[:3]),
            'vod_tag': '、'.join(tags),
            'vod_play_from': '在线播放',
            'vod_play_url': '播放$' + stream,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        url = '%s/search/%s/' % (BASE, _encode_path(str(key or '').strip()))
        html = _http_get(url, referer=BASE + '/')
        items = _parse_cards(html)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        if raw.startswith('http'):
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}

    def localProxy(self, param):
        return [404, 'text/plain', b'', {}]

    def isVideoFormat(self, url):
        u = (url or '').lower()
        return u.endswith('.m3u8') or u.endswith('.mp4') or '.m3u8?' in u or '.mp4?' in u

    def manualVideoCheck(self):
        return False

    def action(self, action, params=None):
        return None
