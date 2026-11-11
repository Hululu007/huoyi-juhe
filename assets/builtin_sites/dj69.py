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


ENTRY = 'https://agx6p-z9.69djudaq.vip/69d/'
FALLBACK_BASE = 'https://q7w2kx.69dj05.vip'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

CATS = [
    ('6', 'AI短剧'),
    ('7', '家庭短剧'),
    ('8', '武侠短剧'),
    ('9', '宫廷短剧'),
    ('10', '都市短剧'),
    ('11', '仙侠短剧'),
    ('12', '异能短剧'),
    ('20', '校园短剧'),
    ('13', '国产黑料'),
    ('14', '传媒精选'),
    ('15', '抖阴视频'),
    ('16', '国产主播'),
    ('21', '网红头条'),
    ('22', '伦理三级'),
    ('23', '国产乱伦'),
    ('24', '明星换脸'),
    ('25', '中文字幕'),
    ('26', '日本无码'),
    ('27', '强奸乱伦'),
    ('28', '制服诱惑'),
    ('29', '萝莉少女'),
    ('30', 'AV解说'),
    ('31', '欧美无码'),
    ('32', '人妖系列'),
]

CAT_RE = re.compile(r'<a[^>]*href="/vodtype/(\d+)\.html"[^>]*>(.*?)</a>', re.S)
CARD_RE = re.compile(r'<a href="/voddetail/(\d+)\.html">.*?<img src="([^"]+)"[^>]*>.*?<span><text>([^<]+)</text></span>', re.S)
H1_RE = re.compile(r'<h1[^>]*>(.*?)</h1>', re.S)
TAG_RE = re.compile(r'<[^>]+>')
COVER_RE = re.compile(r'<img class="detail-cover"[^>]*src="([^"]+)"')
DESC_RE = re.compile(r'<meta name="description"[^>]*content="([^"]+)"')
EP_RE = re.compile(r'<a[^>]*href="(/vodplay/\d+-1-(\d+)\.html)"[^>]*>([^<]*)</a>')
PLAYER_RE = re.compile(r'player_aaaa=.*?"url":"([^"]+)"', re.S)
DOMAIN_RE = re.compile(r"(?:MAIN_DOMAIN|PRIMARY_DOMAIN)\s*=\s*['\"]([^'\"]+)['\"]")
_BASE_CACHE = {'base': '', 'ts': 0}


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _unescape(s):
    if not s:
        return ''
    return _html.unescape(s).replace('\\/', '/').strip()


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
    m = DOMAIN_RE.search(html or '')
    return m.group(1).strip() if m else ''


def _resolve_base():
    now = time.time()
    if _BASE_CACHE['base'] and now - _BASE_CACHE['ts'] < 3600:
        return _BASE_CACHE['base']
    base = FALLBACK_BASE
    try:
        entry = _http_get(ENTRY)
        d1 = _next_domain(entry)
        if d1:
            hop1 = 'https://%s.%s/' % (_rand_sub(7), d1)
            hop1_html = _http_get(hop1)
            d2 = _next_domain(hop1_html)
            if d2:
                cand = 'https://%s.%s' % (_rand_sub(6), d2)
                home = _http_get(cand + '/')
                if '69短剧' in (home or ''):
                    base = cand
    except Exception:
        pass
    _BASE_CACHE['base'] = base
    _BASE_CACHE['ts'] = now
    return base


def _parse_categories(html):
    out = []
    seen = set()
    for m in CAT_RE.finditer(html or ''):
        cid = m.group(1)
        name = TAG_RE.sub('', m.group(2)).strip()
        if not name or '更多' in name or cid in seen:
            continue
        seen.add(cid)
        out.append((cid, name))
    return out


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
            'vod_pic': _unescape(m.group(2)),
            'vod_remarks': '',
        })
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
        return '69短剧'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cats(self):
        cats = _parse_categories(_http_get(_resolve_base() + '/'))
        return cats or list(CATS)

    def _catalog(self, tid, pg):
        base = _resolve_base()
        if pg <= 1:
            url = '%s/vodtype/%s.html' % (base, tid)
        else:
            url = '%s/vodtype/%s-%s.html' % (base, tid, pg)
        return _parse_cards(_http_get(url, referer=base + '/'))

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
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        base = _resolve_base()
        html = _http_get('%s/voddetail/%s.html' % (base, nid), referer=base + '/')
        if not html:
            return {'list': []}
        hm = H1_RE.search(html)
        title = _unescape(TAG_RE.sub('', hm.group(1))) if hm else ''
        if not title:
            return {'list': []}
        cm = COVER_RE.search(html)
        cover = _unescape(cm.group(1)) if cm else ''
        dm = DESC_RE.search(html)
        synopsis = _unescape(dm.group(1)) if dm else ''
        eps = []
        seen = set()
        for m in EP_RE.finditer(html):
            n = m.group(2)
            if n in seen:
                continue
            seen.add(n)
            name = _unescape(m.group(3)).strip() or '第%s集' % n
            eps.append('%s$dj69:%s%s' % (name, base, m.group(1)))
        if not eps:
            eps = ['第1集$dj69:%s/vodplay/%s-1-1.html' % (base, nid)]
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
            'vod_play_url': '#'.join(eps),
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        base = _resolve_base()
        q = urllib.parse.quote(key or '')
        url = '%s/vodsearch/%s-------------.html' % (base, q)
        items = _parse_cards(_http_get(url, referer=base + '/'))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        if raw.startswith('dj69:'):
            raw = raw[5:]
        header = {'User-Agent': UA, 'Referer': _resolve_base() + '/'}
        m3u8 = ''
        if raw.startswith('http'):
            html = _http_get(raw, referer=_resolve_base() + '/')
            if html:
                m = PLAYER_RE.search(html)
                if m:
                    m3u8 = _unescape(m.group(1))
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
