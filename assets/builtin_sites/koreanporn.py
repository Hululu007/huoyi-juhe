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

HOST = 'https://koreanpornmovie.com'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

CATS = [
    ('latest', '最新'),
    ('tag:46', 'Korean Sex'),
    ('tag:1361', 'Celebrity Porn Movies'),
    ('tag:1366', 'Korean Adult Movies'),
    ('tag:1370', 'Cat3Movie'),
    ('tag:1369', 'Cat 3 Movies'),
    ('tag:1363', 'Erotic Movies Online'),
    ('tag:1386', 'Soft Porn Movies'),
    ('tag:1362', 'Asian Erotic'),
    ('tag:1271', 'Korean Erotic'),
    ('tag:1392', 'Nude Boobs'),
    ('tag:1413', '18+ Movies'),
    ('tag:15', 'Korean'),
    ('tag:49', 'Asian'),
    ('tag:84', 'Korea'),
    ('tag:1364', 'Free Erotic Movies'),
]


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _http_get(url, referer=None, timeout=25):
    h = {'User-Agent': UA, 'Accept': 'text/html,application/xhtml+xml,application/json,*/*', 'Accept-Language': 'en-US,en;q=0.9', 'Accept-Encoding': 'gzip, deflate'}
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
            except Exception:
                pass
        except Exception:
            pass
        time.sleep(1)
    return ''


def _clean(t):
    if not t:
        return ''
    t = re.sub(r'<[^>]+>', ' ', t)
    return _html.unescape(re.sub(r'\s+', ' ', t)).strip()


def _decode_entities(s):
    return _html.unescape(s or '').replace('&nbsp;', ' ').strip()


def _trunc(s, n):
    s = s or ''
    return s[:n] if len(s) > n else s


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


def _parse_posts(text):
    try:
        v = json.loads(text or '[]')
    except Exception:
        return []
    if not isinstance(v, list):
        return []
    out = []
    for post in v:
        if not isinstance(post, dict):
            continue
        link = post.get('link') or ''
        if not link:
            continue
        title = ''
        t = post.get('title')
        if isinstance(t, dict):
            title = _trunc(_decode_entities(t.get('rendered') or ''), 90)
        if not title:
            continue
        cover = ''
        emb = post.get('_embedded')
        if isinstance(emb, dict):
            media = emb.get('wp:featuredmedia')
            if isinstance(media, list) and media:
                first = media[0]
                if isinstance(first, dict):
                    cover = first.get('source_url') or ''
        out.append({'vod_id': link, 'vod_name': title, 'vod_pic': cover, 'vod_remarks': ''})
    return out


def _posts_url(tid, pg):
    base = '%s/wp-json/wp/v2/posts?per_page=20&page=%d&_embed=1' % (HOST, pg)
    if tid.startswith('tag:'):
        return base + '&tags=' + tid[4:]
    return base


def _meta(html, attr, key):
    marker = '%s="%s"' % (attr, key)
    p = html.find(marker)
    if p < 0:
        return ''
    after = html[p:]
    c = after.find('content="')
    if c < 0:
        return ''
    s = c + 9
    e = after[s:].find('"')
    if e < 0:
        return ''
    return _decode_entities(after[s:s + e])


def _tag_title(html):
    p = html.find('<title>')
    if p < 0:
        return ''
    s = p + 7
    e = html[s:].find('</title>')
    t = _decode_entities(html[s:s + e] if e >= 0 else html[s:])
    for sep in (' | ', ' - '):
        i = t.rfind(sep)
        if i >= 0:
            return t[:i].strip()
    return t


def _percent_decode(s):
    try:
        return urllib.parse.unquote_plus(s)
    except Exception:
        return s


def _extract_stream(html):
    m = re.search(r'player-x\.php\?q=([A-Za-z0-9+/=_-]+)', html or '')
    if not m:
        return ''
    q = m.group(1).replace('-', '+').replace('_', '/')
    q += '=' * ((4 - len(q) % 4) % 4)
    try:
        decoded = base64.b64decode(q).decode('utf-8', 'replace')
    except Exception:
        return ''
    p = decoded.find('tag=')
    if p < 0:
        return ''
    tag = _percent_decode(decoded[p + 4:])
    m2 = re.search(r'<source[^>]+src="([^"]+\.mp4[^"]*)', tag)
    if not m2:
        return ''
    return m2.group(1)


def _detail_duration(html):
    m = re.search(r'duration" content="([0-9:]+)"', html or '')
    return m.group(1) if m else ''


class Spider(BaseSpider):
    def getName(self):
        return 'Korean Porn Movie'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _catalog(self, tid, pg):
        return _parse_posts(_http_get(_posts_url(tid, pg), referer=HOST + '/'))

    def homeContent(self, filter=''):
        cats = list(CATS)
        items = self._catalog(cats[0][0], 1) if cats else []
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in cats],
            'list': items,
        }

    def homeVideoContent(self):
        cats = list(CATS)
        items = self._catalog(cats[0][0], 1) if cats else []
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        items = self._catalog(_norm_id(tid), pg)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        page_url = nid if nid.startswith('http') else HOST + nid
        html = _http_get(page_url, referer=HOST + '/')
        if not html:
            return {'list': []}
        title = _tag_title(html)
        if not title:
            return {'list': []}
        cover = _meta(html, 'property', 'og:image')
        duration = _detail_duration(html)
        parts = []
        if duration:
            parts.append('时长：' + duration)
        stream = _extract_stream(html)
        if stream:
            play_url = '正片$%s' % stream
        else:
            play_url = '正片$%s' % page_url
        return {'list': [{
            'vod_id': page_url,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': duration,
            'vod_year': '',
            'vod_area': '',
            'vod_content': '\n'.join(parts),
            'type_name': '',
            'vod_tag': '',
            'vod_play_from': '在线播放',
            'vod_play_url': play_url,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        url = '%s/wp-json/wp/v2/posts?search=%s&per_page=20&page=1&_embed=1' % (HOST, urllib.parse.quote(str(key or '')))
        text = _http_get(url, referer=HOST + '/')
        return {'list': _parse_posts(text), 'page': 1, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        header = {'User-Agent': UA, 'Referer': HOST + '/'}
        if '.mp4' in raw:
            url = raw.split('$')[-1].strip()
            return {'parse': 0, 'playUrl': url, 'url': url, 'header': header}
        page_url = raw.split('$')[-1].strip()
        html = _http_get(page_url, referer=HOST + '/')
        url = _extract_stream(html) if html else ''
        if url:
            header['Referer'] = page_url
            return {'parse': 0, 'playUrl': url, 'url': url, 'header': header}
        return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', '']

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
