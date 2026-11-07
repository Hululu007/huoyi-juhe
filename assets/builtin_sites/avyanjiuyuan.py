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

BASE = 'https://avyan2026.lol'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

CATS = [
    ('52', '亚洲情色'),
    ('53', '国产主播'),
    ('54', '国产自拍'),
    ('55', '无码专区'),
    ('56', '欧美性爱'),
    ('57', '熟女人妻'),
    ('58', '强奸乱伦'),
    ('59', '巨乳美乳'),
    ('60', '中文字幕'),
    ('61', '制服诱惑'),
    ('62', '女同性恋'),
    ('63', '卡通动画'),
    ('64', '视频伦理'),
    ('65', '少女萝莉'),
    ('66', '重口色情'),
]

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
                time.sleep(1)
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
             .replace('\\/', '/')
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


_ANCHOR_RE = re.compile(r'<a[^>]*href="/index\.php/vod/play/id/(\d+)/sid/1/nid/1\.html"[^>]*>')
_TITLE_RE = re.compile(r'title="([^"]+)"')
_COVER_RE = re.compile(r'data-original="([^"]+)"')
_PLAYER_RE = re.compile(r'var player_aaaa=(\{.*?\})\s*</script>', re.S)
_DESC_RE = re.compile(r'<meta name="description"[^>]*content="([^"]+)"')


def _parse_cards(html):
    out = []
    if not html:
        return out
    seen = set()
    for m in _ANCHOR_RE.finditer(html):
        vid = m.group(1).strip()
        if not vid or vid in seen:
            continue
        tag = m.group(0)
        tm = _TITLE_RE.search(tag)
        cm = _COVER_RE.search(tag)
        title = _unescape(tm.group(1)) if tm else ''
        cover = _fix_url(cm.group(1)) if cm else ''
        if not title or not cover:
            continue
        seen.add(vid)
        out.append({
            'vod_id': vid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_remarks': '',
        })
    return out


def _parse_player(html):
    if not html:
        return None
    m = _PLAYER_RE.search(html)
    if not m:
        return None
    try:
        return json.loads(m.group(1))
    except Exception:
        return None


def _text_of(obj, keys):
    if not isinstance(obj, dict):
        return ''
    for k in keys:
        v = obj.get(k)
        if isinstance(v, str) and v:
            return v
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
        return 'AV研究院'

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
        html = _fetch('/')
        items = _parse_cards(html)
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        tid = _norm_id(tid).strip()
        pg = _norm_pg(pg)
        if pg < 1:
            pg = 1
        if not tid or tid == 'all':
            tid = '52'
        if pg <= 1:
            path = '/index.php/vod/type/id/%s.html' % tid
        else:
            path = '/index.php/vod/type/id/%s/page/%d.html' % (tid, pg)
        html = _fetch(path)
        items = _parse_cards(html)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        nid = _norm_id(ids).strip()
        nid = ''.join([ch for ch in nid if ch.isdigit()])
        if not nid:
            return _empty_detail(nid)
        page_url = '/index.php/vod/play/id/%s/sid/1/nid/1.html' % nid
        html = _fetch(page_url)
        if not html:
            return _empty_detail(nid)
        player = _parse_player(html)
        if not player:
            return _empty_detail(nid)
        vod_data = player.get('vod_data') if isinstance(player.get('vod_data'), dict) else {}
        title = _text_of(vod_data, ['vod_name'])
        m3u8 = _text_of(player, ['url'])
        if not title or not m3u8:
            return _empty_detail(nid)
        genre = _text_of(vod_data, ['vod_class'])
        desc = ''
        dm = _DESC_RE.search(html)
        if dm:
            desc = _unescape(dm.group(1))
        cover = ''
        kw = title.split()[0] if title.split() else ''
        if not kw:
            kw = title[:12]
        if len(kw) > 20:
            kw = kw[:20]
        if kw:
            try:
                sh = _fetch('/index.php/vod/search.html?wd=' + urllib.parse.quote_plus(kw))
                if sh:
                    for item in _parse_cards(sh):
                        if item['vod_id'] == nid:
                            cover = item['vod_pic']
                            break
            except Exception:
                cover = ''
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': _text_of(vod_data, ['vod_actor']),
            'vod_director': _text_of(vod_data, ['vod_director']),
            'vod_remarks': genre,
            'vod_year': '',
            'vod_area': '',
            'vod_content': desc,
            'type_name': genre,
            'vod_tag': '',
            'vod_play_from': '在线播放',
            'vod_play_url': '播放$%s' % m3u8,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        if pg < 1:
            pg = 1
        kw = urllib.parse.quote_plus(str(key).strip())
        html = _fetch('/index.php/vod/search.html?wd=' + kw)
        items = _parse_cards(html)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        if not raw:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        if raw.startswith('http') and '.m3u8' in raw:
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}

    def localProxy(self, param):
        return [404, 'text/plain', b'', {}]

    def isVideoFormat(self, url):
        u = str(url or '').lower().split('?')[0]
        return u.endswith(('.m3u8', '.mp4', '.mkv', '.webm', '.flv', '.ts'))

    def manualVideoCheck(self):
        return True

    def action(self, action, params=None):
        return {'code': 0, 'msg': 'ok'}
