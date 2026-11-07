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

HOST = 'https://javtsunami.com'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

CATS = [
    ('latest', '最新'),
    ('jav-censored', 'JAV Censored'),
    ('jav-uncensored', 'JAV Uncensored'),
    ('chinese', 'Chinese AV'),
    ('new-release', 'New Release'),
    ('trending', 'Trending JAV'),
    ('featured', 'Featured'),
    ('hot-jav', 'Hot JAV'),
    ('upcoming', 'Upcoming'),
    ('jav-sub', 'JAV Sub'),
    ('fc2', 'FC2 PPV'),
    ('amateur', 'JAV Amateur'),
    ('av-debut', 'AV Debut'),
    ('cosplay', 'Cosplay'),
    ('family', 'Family Porn'),
    ('premium', 'Premium'),
    ('stepmom', 'Japanese Stepmom'),
    ('game-show', 'Japanese Game Show'),
    ('tag:jav-eng-sub', 'Sub Eng'),
    ('tag:jav-sub-indo', 'Sub Indo'),
    ('tag:av-ซับไทย', 'AV ซับไทย'),
    ('tag:jav-english-subtitle', 'JAV English Subtitle'),
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


def _http_post_json(url, obj, referer=None, timeout=25):
    h = {'User-Agent': UA, 'Accept': 'application/json', 'Content-Type': 'application/json'}
    if referer:
        h['Referer'] = referer
    data = json.dumps(obj).encode('utf-8')
    for _ in range(3):
        if _HAS_REQ:
            try:
                r = requests.post(url, data=data, headers=h, timeout=timeout)
                if r.status_code == 200 and r.text:
                    return r.text
            except Exception:
                pass
        try:
            req = urllib.request.Request(url, data=data, headers=h, method='POST')
            with urllib.request.urlopen(req, timeout=timeout, context=_ctx()) as resp:
                return resp.read().decode('utf-8', 'replace')
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
    for block in (html or '').split('<article class="video-card')[1:]:
        end = block.find('<article class="video-card')
        block = block[:end] if end >= 0 else block
        p = block.find('href="https://javtsunami.com/')
        if p < 0:
            continue
        s = p + 6
        e = block[s:].find('"')
        if e < 0:
            continue
        href = block[s:s + e]
        if not href.endswith('v.html'):
            continue
        if href in seen:
            continue
        title = ''
        cover = ''
        p = block.find('<img ')
        if p >= 0:
            img = block[p:]
            a = img.find('alt="')
            if a >= 0:
                s = a + 5
                e = img[s:].find('"')
                if e >= 0:
                    title = _decode_entities(img[s:s + e])
            a = img.find('src="')
            if a >= 0:
                s = a + 5
                e = img[s:].find('"')
                if e >= 0:
                    cover = img[s:s + e]
        if not title:
            p = block.find('card-title')
            if p >= 0:
                after = block[p:]
                gt = after.find('>')
                if gt >= 0:
                    s = gt + 1
                    e = after[s:].find('</')
                    if e >= 0:
                        title = _decode_entities(after[s:s + e].strip())
        if not title:
            continue
        remark = ''
        p = block.find('class="duration"')
        if p >= 0:
            rest = block[p:]
            while True:
                sp = rest.find('<span>')
                if sp < 0:
                    break
                s = sp + 6
                e = rest[s:].find('</span>')
                if e >= 0:
                    t = rest[s:s + e].strip()
                    if t and ':' in t and all(c.isdigit() or c == ':' for c in t):
                        remark = t
                rest = rest[sp + 1:]
        seen.add(href)
        out.append({'vod_id': href, 'vod_name': _trunc(title, 90), 'vod_pic': cover, 'vod_remarks': remark})
    return out


def _catalog_url(tid, pg):
    def paged(base):
        if pg <= 1:
            return base
        return '%spage/%d/' % (base, pg)
    if tid == 'latest':
        return paged(HOST + '/latest/')
    if tid.startswith('tag:'):
        return paged(HOST + '/tag/' + tid[4:] + '/')
    return paged(HOST + '/category/' + tid + '/')


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
    for sep in (' JAV Video', ' - JAV Tsunami', ' | JAV Tsunami'):
        i = t.rfind(sep)
        if i >= 0:
            return t[:i].strip()
    return t


def _actors(html):
    out = []
    rest = html
    while len(out) < 8:
        p = rest.find('href="https://javtsunami.com/actor/')
        if p < 0:
            break
        after = rest[p:]
        gt = after.find('>')
        if gt >= 0:
            s = gt + 1
            e = after[s:].find('</a>')
            if e >= 0:
                name = _decode_entities(after[s:s + e].strip())
                if name and name not in out:
                    out.append(name)
        rest = rest[p + 1:]
    return out


def _server_tokens(html):
    return re.findall(r'data-server-token="([^"]+)" data-server-label="(\w+)"', html or '')


def _embed_parts(url):
    if not url.startswith('https://'):
        return None
    rest = url[8:]
    if '/' not in rest:
        return None
    host, path = rest.split('/', 1)
    if not path.startswith('e/'):
        return None
    code = path[2:].split('?')[0].split('#')[0]
    if not code:
        return None
    return host, code


class Spider(BaseSpider):
    def getName(self):
        return 'JAV Tsunami'

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
        title = _tag_title(html)
        if not title:
            return {'list': []}
        cover = _meta(html, 'property', 'og:image')
        desc = _meta(html, 'property', 'og:description')
        cast = _actors(html)
        if cast:
            if desc:
                desc += '\n'
            desc += '女優：' + '、'.join(cast)
        desc = _trunc(desc, 400)
        play_title = _trunc(title, 60)
        return {'list': [{
            'vod_id': page_url,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': ' / '.join(cast),
            'vod_director': '',
            'vod_remarks': '',
            'vod_year': '',
            'vod_area': '',
            'vod_content': desc,
            'type_name': '',
            'vod_tag': '、'.join(cast),
            'vod_play_from': '在线播放',
            'vod_play_url': '%s$%s' % (play_title, page_url),
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        url = '%s/?s=%s' % (HOST, urllib.parse.quote(str(key or '')))
        html = _http_get(url, referer=HOST + '/')
        return {'list': _cards(html)[:60], 'page': _norm_pg(pg), 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        header = {'User-Agent': UA, 'Referer': HOST + '/'}
        if raw.startswith('http') and '.m3u8' in raw:
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        page_url = raw.split('$')[-1].strip()
        html = _http_get(page_url, referer=HOST + '/')
        if not html:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        tokens = _server_tokens(html)
        if not tokens:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        ordered = []
        for want in ('VD', 'HG', 'DS'):
            for tok, label in tokens:
                if label == want:
                    ordered.append((tok, label))
        for tok, label in tokens:
            if label not in [l for _, l in ordered]:
                ordered.append((tok, label))
        for tok, label in ordered:
            body = _http_post_json(HOST + '/wp-json/jw-dom-tabs/v1/resolve', {'token': tok}, referer=page_url)
            try:
                embed = json.loads(body or '{}').get('url') or ''
            except Exception:
                embed = ''
            if not embed:
                continue
            parts = _embed_parts(embed)
            if not parts:
                continue
            host, code = parts
            if host != 'iosbgaigo.com':
                continue
            stream_body = _http_post_json('https://%s/api/stream' % host, {'filecode': code, 'device': 'web', 'codecs': []}, referer=embed)
            try:
                url = json.loads(stream_body or '{}').get('streaming_url') or ''
            except Exception:
                url = ''
            if url:
                header['Referer'] = embed
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
