try:
    from base.spider import BaseSpider
except Exception:
    try:
        from base import BaseSpider
    except Exception:
        class BaseSpider:
            pass


import base64
import gzip
import html as _html
import http.client
import http.cookiejar
import json
import re
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = 'https://7p-r5-n.hongxingav.xyz'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
DEFAULT_KEY = 'MacEncryptOutput2026K3y@vQxZ9pLm'

CATS = [
    ('6', '精品推荐'),
    ('7', '国产情色'),
    ('9', 'AV明星'),
    ('13', '国模私拍'),
    ('17', '国产精品'),
    ('23', '自拍偷拍'),
    ('33', '传媒系列'),
    ('35', '热门大瓜'),
    ('8', '日本无码'),
    ('10', '中文字幕'),
    ('12', '成人动漫'),
    ('15', '邻家人妻'),
    ('16', '日韩无码'),
    ('18', '日韩精品'),
    ('21', '制服诱惑'),
    ('22', '强奸乱伦'),
    ('2', '欧美情色'),
    ('11', '网红主播'),
    ('14', '长腿丝袜'),
    ('20', '欧美精品'),
    ('24', '3P合辑'),
    ('25', '巨乳系列'),
    ('26', '颜射系列'),
    ('27', '口交视频'),
    ('28', '自慰系列'),
    ('29', 'SM重味'),
    ('30', '教师学生'),
    ('31', '大秀视频'),
    ('32', '重口味'),
    ('34', '明星系列'),
]

_JAR = http.cookiejar.CookieJar()
_OPENER = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(_JAR))


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _fetch_raw(url, timeout=30):
    h = {'User-Agent': UA, 'Referer': BASE + '/'}
    for _ in range(3):
        try:
            req = urllib.request.Request(url, headers=h)
            with _OPENER.open(req, timeout=timeout, context=_ctx()) as resp:
                raw = resp.read()
                enc = (resp.headers.get('Content-Encoding') or '').lower()
                if enc == 'gzip' or raw[:2] == b'\x1f\x8b':
                    try:
                        raw = gzip.decompress(raw)
                    except Exception:
                        pass
                return raw.decode('utf-8', 'replace')
        except urllib.error.HTTPError as e:
            try:
                return e.read().decode('utf-8', 'ignore')
            except http.client.IncompleteRead as ie:
                return ie.partial.decode('utf-8', 'ignore')
        except Exception:
            time.sleep(1)
    return ''


def _b64_decode(s):
    try:
        return base64.b64decode(s)
    except Exception:
        pass
    cleaned = ''.join(c for c in s if c.isalnum() or c in '+/=')
    try:
        return base64.b64decode(cleaned)
    except Exception:
        return None


def _xor_decrypt(cipher, key):
    if not key:
        return ''
    plain = bytes(b ^ key[i % len(key)] for i, b in enumerate(cipher))
    return plain.decode('utf-8', 'replace')


def _get_text(url):
    shell = _fetch_raw(url)
    if '__PAGE_KEY' not in shell or '/static/encrypt/' not in shell:
        return shell
    key_bytes = DEFAULT_KEY.encode('utf-8')
    m = re.search(r'__PAGE_KEY="([^"]+)"', shell)
    if m:
        dec = _b64_decode(m.group(1))
        if dec:
            try:
                k = dec.decode('utf-8')
                if k:
                    key_bytes = k.encode('utf-8')
            except Exception:
                pass
    m = re.search(r'src="([^"]*?/static/encrypt/[a-z0-9]+\.js)"', shell)
    if not m:
        return ''
    js_url = m.group(1)
    if js_url.startswith('http'):
        pass
    elif js_url.startswith('//'):
        js_url = 'https:' + js_url
    elif js_url.startswith('/'):
        js_url = BASE + js_url
    else:
        js_url = BASE + '/' + js_url
    js = _fetch_raw(js_url)
    m = re.search(r"__PAGE_ENC='([^']+)'", js)
    if not m:
        return ''
    cipher = _b64_decode(m.group(1))
    if cipher is None:
        return ''
    return _xor_decrypt(cipher, key_bytes)


def _unescape(s):
    return _html.unescape(s or '').replace('\\/', '/')


def _strip_tags(s):
    if not s:
        return ''
    t = re.sub(r'<[^>]+>', ' ', s)
    return _html.unescape(re.sub(r'\s+', ' ', t)).strip()


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


def _parse_cards(html):
    card_re = re.compile(r'(?s)<a href="/index\.php/vod/detail/id/(\d+)\.html"[^>]*><img[^>]*src="([^"]+)"')
    title_re = re.compile(r'<h3>([^<]+)</h3>')
    out = []
    seen = set()
    for m in card_re.finditer(html or ''):
        vid = m.group(1)
        if vid in seen:
            continue
        seen.add(vid)
        cover = m.group(2).strip()
        tail = html[m.end():m.end() + 3000]
        tm = title_re.search(tail)
        title = _unescape(tm.group(1).strip()) if tm else ''
        if not title:
            continue
        out.append({'vod_id': vid, 'vod_name': title, 'vod_pic': cover, 'vod_remarks': ''})
    return out


def _parse_player_url(html):
    m = re.search(r'(?s)player_aaaa=.*?"url":"([^"]+)"', html or '')
    if not m:
        return ''
    return _unescape(m.group(1))


class Spider(BaseSpider):
    def getName(self):
        return '红杏'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=''):
        html = _get_text(BASE)
        cats = []
        seen = set()
        for m in re.finditer(r'href="/index\.php/vod/type/id/(\d+)\.html"[^>]*>([^<]{1,16})<', html or ''):
            cid, name = m.group(1), _unescape(m.group(2).strip())
            if not name or name == '更多' or cid in seen:
                continue
            seen.add(cid)
            cats.append((cid, name))
        if not cats:
            cats = list(CATS)
        items = []
        if cats:
            html2 = _get_text(BASE + '/index.php/vod/type/id/%s.html' % cats[0][0])
            items = _parse_cards(html2)
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in cats],
            'list': items,
        }

    def homeVideoContent(self):
        html = _get_text(BASE + '/index.php/vod/type/id/6.html')
        return {'list': _parse_cards(html), 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        tid = _norm_id(tid) or '6'
        if pg <= 1:
            url = BASE + '/index.php/vod/type/id/%s.html' % tid
        else:
            url = BASE + '/index.php/vod/type/id/%s/page/%d.html' % (tid, pg)
        html = _get_text(url)
        items = _parse_cards(html)
        has_more = bool(items) and ('/index.php/vod/type/id/%s/page/%d.html' % (tid, pg + 1)) in (html or '')
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': len(items) if not has_more else 0}

    def detailContent(self, ids):
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        vid = nid.replace('/index.php/vod/detail/id/', '').rstrip('/').replace('.html', '')
        html = _get_text(BASE + '/index.php/vod/detail/id/%s.html' % vid)
        title = ''
        m = re.search(r'(?s)<h1[^>]*>(.*?)</h1>', html or '')
        if m:
            title = _unescape(m.group(1).strip())
        cover = ''
        m = re.search(r'<img[^>]*src="([^"]*?/upload/vod/[^"]+)"', html or '')
        if m:
            cover = m.group(1)
        synopsis = ''
        m = re.search(r'<meta name="description" content="([^"]*)"', html or '')
        if m:
            synopsis = _unescape(m.group(1).strip())
        if not title:
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
            'vod_play_url': '播放$%s-1-1' % vid,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        url = BASE + '/index.php/vod/search.html?wd=%s' % urllib.parse.quote(str(key or ''))
        html = _get_text(url)
        items = _parse_cards(html)
        return {'list': items, 'page': _norm_pg(pg), 'pagecount': 0, 'total': len(items)}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        if raw.startswith('http'):
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        parts = raw.split('-')
        if len(parts) != 3:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        url = BASE + '/index.php/vod/play/id/%s/sid/%s/nid/%s.html' % (parts[0], parts[1], parts[2])
        html = _get_text(url)
        stream = _parse_player_url(html)
        if not stream:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        return {'parse': 0, 'playUrl': stream, 'url': stream, 'header': {'User-Agent': UA, 'Referer': BASE + '/'}}

    def localProxy(self, param):
        return [404, 'text/plain', '']

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
