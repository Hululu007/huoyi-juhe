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
import json
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


BASE = 'https://heitaodj.com'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
COOKIE = 'heitao_age_confirmed=1'

CATS = [
    ('1', '现代都市'),
    ('2', '古装传奇'),
    ('3', '仙侠玄幻'),
    ('4', '科幻脑洞'),
    ('5', '灵异悬疑'),
    ('6', '其他短剧'),
]

CARD_RE = re.compile(r'<li class="m-item">.*?<a class="thumb" href="/index\.php/vod/detail/id/(\d+)\.html" title="([^"]*)".*?<img[^>]*src="([^"]+)".*?<p class="des">([^<]*)</p>', re.S)
NAV_RE = re.compile(r'<a class="item" href="/index\.php/vod/type/id/(\d+)\.html"[^>]*>([^<]+)</a>')
TITLE_RE = re.compile(r'<title[^>]*>(.*?)</title>', re.S)
DESC_RE = re.compile(r'<meta name="description"[^>]*content="([^"]+)"')
INTRO_RE = re.compile(r'<p class="intro-desc[^"]*">.*?<label[^>]*>.*?</label>(.*?)</p>', re.S)
OGIMG_RE = re.compile(r'<meta property="og:image" content="([^"]+)"')
EP_RE = re.compile(r'<li><a href="/index\.php/vod/play/id/(\d+)/sid/1/nid/(\d+)\.html">([^<]*)</a></li>')
IFRAME_RE = re.compile(r'<iframe[^>]*src="([^"]+)"')
PLAYER_RE = re.compile(r'player_aaaa\s*=\s*(\{.*?\})\s*</script>', re.S)


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
    h = {'User-Agent': UA, 'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8', 'Accept-Language': 'zh-CN,zh;q=0.9', 'Accept-Encoding': 'gzip, deflate', 'Cookie': COOKIE}
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


def _fix_url(raw):
    u = (raw or '').strip()
    if not u:
        return ''
    if u.startswith('//'):
        return 'https:' + u
    if u.startswith('/'):
        return BASE + u
    return u


def _parse_cards(html):
    out = []
    seen = set()
    for m in CARD_RE.finditer(html or ''):
        vid = m.group(1).strip()
        if not vid or vid in seen:
            continue
        title = _unescape(m.group(2))
        if not title:
            continue
        seen.add(vid)
        out.append({
            'vod_id': vid,
            'vod_name': title,
            'vod_pic': _fix_url(m.group(3)),
            'vod_remarks': _unescape(m.group(4)),
        })
    return out


def _parse_categories(html):
    out = []
    seen = set()
    for m in NAV_RE.finditer(html or ''):
        cid = m.group(1)
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
        return '黑桃短剧'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cats(self):
        cats = _parse_categories(_http_get(BASE + '/', referer=BASE + '/'))
        return cats or list(CATS)

    def _catalog(self, tid, pg):
        if pg <= 1:
            url = '%s/index.php/vod/type/id/%s.html' % (BASE, tid)
        else:
            url = '%s/index.php/vod/type/id/%s/page/%s.html' % (BASE, tid, pg)
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
        if not nid:
            return {'list': []}
        detail_url = '%s/index.php/vod/detail/id/%s.html' % (BASE, nid)
        html = _http_get(detail_url, referer=BASE + '/')
        if not html:
            return {'list': []}
        tm = TITLE_RE.search(html)
        raw_title = _unescape(tm.group(1)) if tm else ''
        parts = [p.strip() for p in raw_title.split(' - ') if p.strip()]
        title = parts[0] if parts else ''
        if not title:
            return {'list': []}
        type_name = parts[1] if len(parts) > 1 else ''
        im = INTRO_RE.search(html)
        if im:
            synopsis = _unescape(re.sub(r'<[^>]+>', '', im.group(1)))
        else:
            dm = DESC_RE.search(html)
            synopsis = _unescape(dm.group(1)) if dm else ''
        pm = OGIMG_RE.search(html)
        pic = _fix_url(pm.group(1)) if pm else ''
        eps = []
        seen = set()
        for m in EP_RE.finditer(html):
            vid, n, label = m.group(1), m.group(2), m.group(3).strip()
            if vid != nid or n in seen:
                continue
            seen.add(n)
            href = '/index.php/vod/play/id/%s/sid/1/nid/%s.html' % (vid, n)
            eps.append('%s$heitao:%s' % (label or ('第%s集' % n), _fix_url(href)))
        if not eps:
            href = '/index.php/vod/play/id/%s/sid/1/nid/1.html' % nid
            eps = ['第1集$heitao:%s' % _fix_url(href)]
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': pic,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': '',
            'vod_year': '',
            'vod_area': '',
            'vod_content': synopsis,
            'type_name': type_name,
            'vod_tag': '',
            'vod_play_from': '在线播放',
            'vod_play_url': '#'.join(eps),
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        url = '%s/index.php/vod/search.html?wd=%s' % (BASE, urllib.parse.quote(key or ''))
        items = _parse_cards(_http_get(url, referer=BASE + '/'))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        if raw.startswith('heitao:'):
            raw = raw[len('heitao:'):]
        url = _fix_url(raw)
        header = {'User-Agent': UA, 'Referer': BASE + '/', 'Cookie': COOKIE}
        m3u8 = ''
        play_html = _http_get(url, referer=BASE + '/')
        if play_html:
            im = IFRAME_RE.search(play_html)
            if im:
                player_url = _fix_url(im.group(1))
                player_html = _http_get(player_url, referer=url)
                if player_html:
                    pm = PLAYER_RE.search(player_html)
                    if pm:
                        try:
                            data = json.loads(pm.group(1))
                            m3u8 = _unescape(data.get('url') or '')
                        except Exception:
                            pass
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
