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


HOST = 'https://taiav.com'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

CATS = [
    ('uncensored', '无码'),
    ('censored', '有码'),
    ('domestic', '国产AV'),
    ('influencer', '网红主播'),
    ('hots', '热门视频'),
    ('random', '随机'),
]

ID_RE = re.compile(r'/cn/movie/([0-9a-f]{24})')


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


def _decode_entities(s):
    if not s:
        return ''
    return _html.unescape(s.replace('&nbsp;', ' ')).strip()


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
    blocks = (html or '').split('class="movie-card"')[1:]
    for block in blocks:
        end = block.find('class="movie-card"')
        if end >= 0:
            block = block[:end]
        m = ID_RE.search(block)
        if not m:
            continue
        vid = m.group(1)
        page_url = '%s/cn/movie/%s' % (HOST, vid)
        if page_url in seen:
            continue
        cover = ''
        title = ''
        p = block.find('poster2.webp')
        if p >= 0:
            head = block[:p]
            a = head.rfind('<img ')
            if a >= 0:
                img = block[a:]
                sm = re.search(r'src="([^"]+)"', img)
                if sm:
                    cover = sm.group(1)
                am = re.search(r'alt="([^"]+)"', img)
                if am:
                    title = _decode_entities(am.group(1))
        if not title:
            continue
        seen.add(page_url)
        out.append({'vod_id': page_url, 'vod_name': _trunc(title, 90), 'vod_pic': cover, 'vod_remarks': ''})
    return out


def _catalog_url(tid, pg):
    def _wp(base):
        if pg <= 1:
            return base
        return '%s?page=%s' % (base, pg)
    if tid == 'uncensored':
        return _wp(HOST + '/cn/category/' + urllib.parse.quote('无码'))
    if tid == 'censored':
        return _wp(HOST + '/cn/category/' + urllib.parse.quote('有码'))
    if tid == 'domestic':
        return _wp(HOST + '/cn/category/' + urllib.parse.quote('国产AV'))
    if tid == 'influencer':
        return _wp(HOST + '/cn/category/' + urllib.parse.quote('网红主播'))
    if tid == 'hots':
        return _wp(HOST + '/hots')
    if tid == 'random':
        return HOST + '/random'
    return _wp(HOST + '/cn/category/' + urllib.parse.quote('无码'))


def _meta_content(html, attr, key):
    marker = '%s="%s"' % (attr, key)
    p = (html or '').find(marker)
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
    p = (html or '').find('<title>')
    if p < 0:
        return ''
    s = p + 7
    e = html[s:].find('</title>')
    if e < 0:
        e = len(html) - s
    t = _decode_entities(html[s:s + e])
    for sep in (' 在线观看,免费高清 - Taiav.com', ' - Taiav.com'):
        if sep in t:
            return t.rsplit(sep, 1)[0].strip()
    return t


class Spider(BaseSpider):
    def getName(self):
        return 'TaiAV'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=''):
        cats = list(CATS)
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
            items = self.categoryContent(CATS[0][0], 1).get('list') or []
        except Exception:
            items = []
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        url = _catalog_url(tid, pg)
        html = _http_get(url, referer=HOST + '/cn/')
        items = _cards(html)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        page_url = _norm_id(ids)
        if '$' in page_url:
            page_url = page_url.split('$')[-1]
        if not page_url:
            return {'list': []}
        html = _http_get(page_url, referer=HOST + '/cn/')
        title = _tag_title(html)
        if not title:
            return {'list': []}
        cover = _meta_content(html, 'property', 'og:image')
        desc = _trunc(_meta_content(html, 'name', 'description'), 400)
        return {'list': [{
            'vod_id': page_url,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': '',
            'vod_year': '',
            'vod_area': '',
            'vod_content': desc,
            'type_name': '',
            'vod_tag': '',
            'vod_play_from': '在线播放',
            'vod_play_url': '正片$%s' % page_url,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        url = '%s/cn/search?q=%s' % (HOST, urllib.parse.quote(str(key or '')))
        html = _http_get(url, referer=HOST + '/cn/')
        items = _cards(html)[:60]
        return {'list': items, 'page': _norm_pg(pg), 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        header = {'User-Agent': UA, 'Referer': HOST + '/cn/'}
        if raw.startswith('http') and '.m3u8' in raw:
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        page_url = raw.split('$')[-1]
        m = ID_RE.search(page_url)
        if not m:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        api = '%s/api/getmovie?type=1280&id=%s' % (HOST, m.group(1))
        body = _http_get(api, referer=page_url)
        try:
            obj = json.loads(body or '{}')
        except Exception:
            obj = {}
        path = obj.get('m3u8') or ''
        if not path:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        if path.startswith('http'):
            url = path
        elif path.startswith('/'):
            url = HOST + path
        else:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        header['Referer'] = page_url
        return {'parse': 0, 'playUrl': url, 'url': url, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', b'', {}]

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
