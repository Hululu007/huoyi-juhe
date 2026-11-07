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
import http.cookiejar
import json
import re
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

BASES = ['https://wap.huangguazy7.cc', 'https://gua.huangguazy8.cc']
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

CATS = [
    ('386', '黄瓜资源'),
    ('358', '番号资源'),
    ('119', '不卡资源'),
    ('286', '玉兔资源'),
    ('329', '裤子资源'),
    ('370', '森林资源'),
    ('244', '163资源'),
]

_JAR = http.cookiejar.CookieJar()
_OPENER = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(_JAR))


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _fetch_once(url, timeout=30):
    h = {'User-Agent': UA}
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


def _get(path, timeout=30):
    last = ''
    for base in BASES:
        url = base + path
        for _ in range(2):
            try:
                return _fetch_once(url, timeout)
            except urllib.error.HTTPError as e:
                try:
                    return e.read().decode('utf-8', 'ignore')
                except http.client.IncompleteRead as ie:
                    return ie.partial.decode('utf-8', 'ignore')
            except Exception as e:
                last = str(e)
                time.sleep(1)
    return ''


def _fix_url(raw):
    u = (raw or '').strip()
    if not u:
        return ''
    if u.startswith('//'):
        return 'https:' + u
    if u.startswith('/'):
        return BASES[0] + u
    return u


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
    card_re = re.compile(r'(?s)<a class="vod-card-item" href="/a/index\.php/vod/detail/id/(\d+)\.html".*?<div class="vod-card-name">(.*?)</div>.*?<span class="vod-card-remarks">([^<]*)</span>')
    cover_re = re.compile(r'data-original="([^"]+)"')
    out = []
    seen = set()
    for m in card_re.finditer(html or ''):
        vid = m.group(1).strip()
        if not vid or vid in seen:
            continue
        seen.add(vid)
        title = _unescape(m.group(2).strip())
        if not title:
            continue
        cover = ''
        cm = cover_re.search(m.group(0))
        if cm:
            cover = _fix_url(cm.group(1))
        remark = m.group(3).strip()
        out.append({'vod_id': vid, 'vod_name': title, 'vod_pic': cover, 'vod_remarks': remark})
    return out


def _parse_player_url(html):
    m = re.search(r'(?s)player_aaaa=.*?"url":"([^"]+)"', html or '')
    if not m:
        return ''
    return _unescape(m.group(1))


class Spider(BaseSpider):
    def getName(self):
        return '黄瓜资源'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=''):
        html = _get('/a/')
        cats = []
        seen = set()
        for m in re.finditer(r'(?s)<a href="/a/index\.php/vod/type/id/(\d+)\.html" class="cat-icon-item"[^>]*>.*?<span[^>]*>([^<]+)</span>', html or ''):
            cid, name = m.group(1), m.group(2).strip()
            if not name or cid in seen:
                continue
            seen.add(cid)
            cats.append((cid, name))
        if not cats:
            cats = list(CATS)
        items = []
        if cats:
            items = _parse_cards(_get('/a/index.php/vod/type/id/%s.html' % cats[0][0]))
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in cats],
            'list': items,
        }

    def homeVideoContent(self):
        html = _get('/a/index.php/vod/type/id/386.html')
        return {'list': _parse_cards(html), 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        tid = _norm_id(tid) or '386'
        if pg <= 1:
            path = '/a/index.php/vod/type/id/%s.html' % tid
        else:
            path = '/a/index.php/vod/type/id/%s/page/%d.html' % (tid, pg)
        html = _get(path)
        items = _parse_cards(html)
        has_more = bool(items) and ('/a/index.php/vod/type/id/%s/page/%d.html' % (tid, pg + 1)) in (html or '')
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': len(items) if not has_more else 0}

    def detailContent(self, ids):
        nid = _norm_id(ids).lstrip('/')
        if not nid:
            return {'list': []}
        html = _get('/a/index.php/vod/detail/id/%s.html' % nid)
        title = ''
        m = re.search(r'(?s)<h1[^>]*>(.*?)</h1>', html or '')
        if m:
            title = _unescape(m.group(1).strip())
            p = title.find('<')
            if p >= 0:
                title = title[:p].strip()
        cover = ''
        m = re.search(r'<img class="main-img" src="([^"]+)"', html or '')
        if m:
            cover = _fix_url(m.group(1))
        if not cover:
            m = re.search(r'data-original="([^"]+)"', html or '')
            if m:
                cover = _fix_url(m.group(1))
        synopsis = ''
        m = re.search(r'<meta name="description"[^>]*content="([^"]+)"', html or '')
        if m:
            synopsis = _unescape(m.group(1).strip())
        eps = []
        seen = set()
        ep_re = re.compile(r'<a[^>]*href="(/a/index\.php/vod/play/id/\d+/sid/\d+/nid/\d+\.html)"[^>]*>([^<]+)</a>')
        for m in ep_re.finditer(html or ''):
            href, name = m.group(1).strip(), m.group(2).strip()
            if name == '▶ 立即播放' or href in seen:
                continue
            seen.add(href)
            eps.append('%s$%s' % (name, _fix_url(href)))
        if not title or not eps:
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
            'vod_play_url': '#'.join(eps),
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        enc = urllib.parse.quote(str(key or ''), safe='')
        html = _get('/a/index.php/vod/search/wd/%s.html' % enc)
        items = _parse_cards(html)
        return {'list': items, 'page': _norm_pg(pg), 'pagecount': 0, 'total': len(items)}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        header = {'User-Agent': UA, 'Referer': BASES[0] + '/'}
        if raw.startswith('http'):
            url = raw
        else:
            url = _fix_url(raw)
        if '/vod/play/' not in url:
            if url.startswith('http') and url.endswith('.m3u8'):
                return {'parse': 0, 'playUrl': url, 'url': url, 'header': header}
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        p = url.find('/a/index.php')
        path = url[p:] if p >= 0 else url
        html = _get(path)
        m3u8 = _parse_player_url(html)
        if not m3u8:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
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
