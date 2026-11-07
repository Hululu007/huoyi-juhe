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

HOST = 'https://kissjav.li'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

CATS = [
    ('latest', '最新'),
    ('popular', '最多观看'),
    ('hot', '今日热门'),
    ('playlists', '播放列表'),
    ('cat:vip', 'KVIP'),
    ('cat:jvip', 'JVIP'),
    ('cat:korean-porn', 'Korean Porn'),
    ('cat:korean-bj', 'Korean BJ'),
    ('cat:fc2ppv', 'FC2PPV'),
    ('cat:jav', 'JAV'),
    ('cat:myfans', 'MyFans'),
    ('cat:ipcam', 'IPCAM'),
    ('cat:toilet', 'Toilet'),
    ('cat:voyeur-jp', 'Voyeur JP'),
    ('cat:asian-leak', 'Asian Leak'),
    ('cat:china', 'China'),
    ('cat:mib', 'MIB'),
    ('cat:upskirt', 'Upskirt'),
]


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _http_get(url, referer=None, timeout=25):
    h = {'User-Agent': UA, 'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8', 'Accept-Language': 'en-US,en;q=0.9', 'Accept-Encoding': 'gzip, deflate'}
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


def _cards(html):
    out = []
    seen = set()
    for block in (html or '').split('href="https://kissjav.li/video/')[1:]:
        end = block.find('href="https://kissjav.li/video/')
        block = block[:end] if end >= 0 else block
        q = block.find('"')
        if q < 0:
            continue
        path = block[:q]
        vid = path.split('/')[0] if path else ''
        if not vid or not vid.isdigit():
            continue
        vid_url = '%s/video/%s' % (HOST, path)
        if vid_url in seen:
            continue
        title = ''
        p = block.find('title="')
        if p >= 0:
            s = p + 7
            e = block[s:].find('"')
            if e >= 0:
                title = _decode_entities(block[s:s + e])
        cover = ''
        p = block.find('data-original="')
        if p >= 0:
            s = p + 15
            e = block[s:].find('"')
            if e >= 0:
                src = block[s:s + e]
                if src.startswith('//'):
                    cover = 'https:' + src
                elif src.startswith('http'):
                    cover = src
                else:
                    cover = HOST + src
        if not title:
            p = block.find('alt="')
            if p >= 0:
                s = p + 5
                e = block[s:].find('"')
                if e >= 0:
                    title = _decode_entities(block[s:s + e])
        if not title:
            continue
        remark = ''
        p = block.find('<div class="time">')
        if p >= 0:
            s = p + 18
            e = block[s:].find('</div>')
            if e >= 0:
                remark = block[s:s + e].strip()
        seen.add(vid_url)
        out.append({'vod_id': vid_url, 'vod_name': _trunc(title, 90), 'vod_pic': cover, 'vod_remarks': remark})
    return out


def _catalog_url(tid, pg):
    def paged(base):
        if pg <= 1:
            return base
        return '%s%d/' % (base, pg)
    if tid == 'latest':
        return paged(HOST + '/latest-updates/')
    if tid == 'popular':
        if pg <= 1:
            return HOST + '/most-popular/?sort_by=video_viewed'
        return '%s/most-popular/%d/?sort_by=video_viewed' % (HOST, pg)
    if tid == 'hot':
        if pg <= 1:
            return HOST + '/most-popular/?sort_by=video_viewed_today'
        return '%s/most-popular/%d/?sort_by=video_viewed_today' % (HOST, pg)
    if tid == 'playlists':
        return paged(HOST + '/playlists/')
    if tid.startswith('cat:'):
        return paged(HOST + '/categories/' + tid[4:] + '/')
    return paged(HOST + '/latest-updates/')


def _flashvar(html, name):
    marker = "%s: '" % name
    p = html.find(marker)
    if p < 0:
        return ''
    s = p + len(marker)
    e = html[s:].find("'")
    if e < 0:
        return ''
    return html[s:s + e]


def _tag_title(html):
    p = html.find('<title>')
    if p < 0:
        return ''
    s = p + 7
    e = html[s:].find('</title>')
    t = _decode_entities(html[s:s + e] if e >= 0 else html[s:])
    for sep in (' - KissJAV', ' | KissJAV'):
        i = t.rfind(sep)
        if i >= 0:
            return t[:i].strip()
    return t


def _decode_video_url(b64):
    s = (b64 or '').strip()
    while len(s) % 4 != 0:
        s += '='
    try:
        url = base64.b64decode(s).decode('utf-8')
    except Exception:
        return ''
    if url.startswith('http') and '.mp4' in url:
        return url
    return ''


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


class Spider(BaseSpider):
    def getName(self):
        return 'KissJAV'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _catalog(self, tid, pg):
        return _cards(_http_get(_catalog_url(tid, pg), referer=HOST + '/'))

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
        title = _flashvar(html, 'video_title')
        if not title:
            title = _tag_title(html)
        if not title:
            return {'list': []}
        cover = _meta(html, 'property', 'og:image')
        cats = _flashvar(html, 'video_categories')
        parts = []
        if cats:
            parts.append('分类：' + cats)
        play_title = _trunc(title, 60)
        return {'list': [{
            'vod_id': page_url,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': '',
            'vod_year': '',
            'vod_area': '',
            'vod_content': '\n'.join(parts),
            'type_name': cats,
            'vod_tag': cats,
            'vod_play_from': '在线播放',
            'vod_play_url': '%s$%s' % (play_title, page_url),
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        url = '%s/search/?q=%s' % (HOST, urllib.parse.quote(str(key or '')))
        html = _http_get(url, referer=HOST + '/')
        return {'list': _cards(html)[:60], 'page': _norm_pg(pg), 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        header = {'User-Agent': UA, 'Referer': HOST + '/'}
        if raw.startswith('http') and '.mp4' in raw:
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        page_url = raw.split('$')[-1].strip()
        html = _http_get(page_url, referer=HOST + '/')
        url = _decode_video_url(_flashvar(html, 'video_url')) if html else ''
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
