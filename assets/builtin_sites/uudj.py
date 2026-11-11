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
import random
import re
import ssl
import string
import time
import urllib.error
import urllib.parse
import urllib.request

try:
    import requests
    _HAS_REQ = True
except Exception:
    _HAS_REQ = False


ENTRY = 'https://e3-pvx-t0.uudjmusic.vip/uudj/'
FALLBACK_BASE = 'https://m4n8p1.uudj02.vip'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
_BASE_CACHE = {'base': '', 'ts': 0}

CATS = [
    ('6', 'AI短剧'),
    ('7', '职场权色'),
    ('8', '都市爱情'),
    ('9', '家庭伦理'),
    ('10', '武侠江湖'),
    ('11', '古装奇谈'),
    ('12', '异能超能'),
    ('20', '系统逆袭'),
    ('13', '精品国产'),
    ('14', '探花约炮'),
    ('15', '传媒剧情'),
    ('16', '国产自拍'),
    ('21', '主播诱惑'),
    ('22', '抖阴短片'),
    ('23', '明星换脸'),
    ('24', '偷拍偷窥'),
    ('25', '中文字幕'),
    ('26', 'AV解说'),
    ('27', '强奸乱伦'),
    ('28', '日本无码'),
    ('29', '重口激情'),
    ('30', '欧美情色'),
    ('31', 'SM调教'),
    ('32', '女同性恋'),
]


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


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


def _rand_sub(n):
    chars = string.ascii_lowercase + string.digits
    return ''.join(random.choice(chars) for _ in range(n))


def _next_domain(html):
    for pat in (r'MAIN_DOMAIN\s*=\s*[\'"]([^\'"]+)[\'"]', r'PRIMARY_DOMAIN\s*=\s*[\'"]([^\'"]+)[\'"]'):
        m = re.search(pat, html or '')
        if m and m.group(1).strip():
            return m.group(1).strip()
    return ''


def _follow_chain():
    entry = _http_get(ENTRY)
    if not entry:
        return ''
    d1 = _next_domain(entry)
    if not d1:
        return ''
    hop1 = 'https://%s.%s/' % (_rand_sub(7), d1)
    hop1_html = _http_get(hop1)
    if not hop1_html:
        return ''
    d2 = _next_domain(hop1_html)
    if not d2:
        return ''
    base = 'https://%s.%s' % (_rand_sub(6), d2)
    home = _http_get(base + '/')
    if home and 'UU短剧' in home:
        return base
    return ''


def _resolve_base():
    now = time.time()
    if _BASE_CACHE['base'] and now - _BASE_CACHE['ts'] < 3600:
        return _BASE_CACHE['base']
    base = _follow_chain() or FALLBACK_BASE
    _BASE_CACHE['base'] = base
    _BASE_CACHE['ts'] = now
    return base


def _unescape(s):
    if not s:
        return ''
    return _html.unescape(s).replace('\\/', '/')


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


def _live_cats(html):
    out = []
    seen = set()
    pat = re.compile(r'<a[^>]*href="/index\.php/vod/type/id/(\d+)\.html"[^>]*>\s*<text>([^<]+)</text>', re.S)
    for m in pat.finditer(html or ''):
        cid, name = m.group(1), m.group(2).strip()
        if not name or cid in seen:
            continue
        seen.add(cid)
        out.append((cid, name))
    return out


def _cards(html):
    out = []
    seen = set()
    pat = re.compile(r'<a href="/index\.php/vod/detail/id/(\d+)\.html">.*?<img src="([^"]+)"[^>]*>.*?<span><text>([^<]+)</text></span>', re.S)
    for m in pat.finditer(html or ''):
        vid = m.group(1)
        if vid in seen:
            continue
        seen.add(vid)
        title = _unescape(m.group(3).strip())
        if not title:
            continue
        out.append({'vod_id': vid, 'vod_name': title, 'vod_pic': _unescape(m.group(2).strip()), 'vod_remarks': ''})
    return out


def _player_url(play_html):
    m = re.search(r'player_aaaa=.*?"url":"([^"]+)"', play_html or '', re.S)
    return _unescape(m.group(1)) if m else ''


class Spider(BaseSpider):
    def getName(self):
        return 'UU短剧'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cats(self):
        base = _resolve_base()
        html = _http_get(base + '/')
        live = _live_cats(html) if html else []
        return live or list(CATS)

    def homeContent(self, filter=''):
        cats = self._cats()
        items = []
        try:
            items = self.categoryContent(cats[0][0], 1).get('list') or []
        except Exception:
            items = []
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in cats],
            'list': items,
        }

    def homeVideoContent(self):
        try:
            items = self.categoryContent(self._cats()[0][0], 1).get('list') or []
        except Exception:
            items = []
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        base = _resolve_base()
        if pg <= 1:
            url = '%s/index.php/vod/type/id/%s.html' % (base, tid)
        else:
            url = '%s/index.php/vod/type/id/%s/page/%s.html' % (base, tid, pg)
        html = _http_get(url, referer=base + '/')
        items = _cards(html)
        nxt = '/index.php/vod/type/id/%s/page/%s.html' % (tid, pg + 1)
        has_more = bool(items) and nxt in (html or '')
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        vid = _norm_id(ids)
        if not vid:
            return {'list': []}
        base = _resolve_base()
        html = _http_get('%s/index.php/vod/detail/id/%s.html' % (base, vid), referer=base + '/')
        if not html:
            return {'list': []}
        title = ''
        hm = re.search(r'<h1[^>]*>(.*?)</h1>', html, re.S)
        if hm:
            title = _unescape(re.sub(r'<[^>]+>', '', hm.group(1)).strip())
        cover = ''
        cm = re.search(r'<img class="detail-cover"[^>]*src="([^"]+)"', html)
        if cm:
            cover = _unescape(cm.group(1).strip())
        synopsis = ''
        dm = re.search(r'<meta name="description"[^>]*content="([^"]+)"', html)
        if dm:
            synopsis = _unescape(dm.group(1).strip())
        eps = []
        seen = set()
        epat = re.compile(r'<a[^>]*href="(/index\.php/vod/play/id/\d+/sid/1/nid/(\d+)\.html)"[^>]*>([^<]*)</a>')
        for m in epat.finditer(html):
            nid = m.group(2)
            if nid in seen:
                continue
            seen.add(nid)
            name = _unescape(m.group(3)).strip()
            if not name:
                name = '第%s集' % nid
            eps.append('%s$%s%s' % (name, base, m.group(1)))
        if not eps:
            eps.append('第1集$%s/index.php/vod/play/id/%s/sid/1/nid/1.html' % (base, vid))
        if not title:
            return {'list': []}
        return {'list': [{
            'vod_id': vid,
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
            'vod_play_url': '#'.join(eps),
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        base = _resolve_base()
        url = '%s/index.php/vod/search.html?wd=%s' % (base, urllib.parse.quote(str(key or '').strip()))
        html = _http_get(url, referer=base + '/')
        items = _cards(html)
        return {'list': items, 'page': _norm_pg(pg), 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        header = {'User-Agent': UA}
        if not raw.startswith('http'):
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        header['Referer'] = raw
        html = _http_get(raw, referer=raw)
        m3u8 = _player_url(html)
        if not m3u8:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        return {'parse': 0, 'playUrl': m3u8, 'url': m3u8, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', b'', {}]

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
