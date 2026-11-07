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


HOST = 'https://roshy.tv'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

CATS = [
    ('english-sub-11', 'English Sub'),
    ('decensored-6', 'Decensored'),
    ('big-tits-2', 'Big Tits'),
    ('creampie', 'Creampie'),
    ('cuckold', 'Cuckold'),
    ('married-woman-3', 'Married Woman'),
    ('mature-woman-2', 'Mature Woman'),
    ('solowork', 'Solowork'),
]


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _http_get(url, referer, timeout=25):
    h = {'User-Agent': UA, 'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8', 'Referer': referer}
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
    return (s or '').replace('&nbsp;', ' ').replace('&amp;', '&').replace('&#039;', "'").replace('&#39;', "'").replace('&quot;', '"').replace('&lt;', '<').replace('&gt;', '>').strip()


def _truncate(s, n):
    if len(s) > n:
        return s[:n]
    return s


def _js_unescape(s):
    out = ''
    i = 0
    mapping = {'\\': '\\', "'": "'", '"': '"', '/': '/', 'n': '\n', 'r': '\r', 't': '\t', 'b': '\b', 'f': '\f', 'v': '\v', '0': '\0'}
    while i < len(s):
        c = s[i]
        if c != '\\':
            out += c
            i += 1
            continue
        if i + 1 >= len(s):
            break
        nxt = s[i + 1]
        if nxt == 'x':
            try:
                out += chr(int(s[i + 2:i + 4], 16))
            except Exception:
                pass
            i += 4
            continue
        if nxt == 'u':
            try:
                out += chr(int(s[i + 2:i + 6], 16))
            except Exception:
                pass
            i += 6
            continue
        out += mapping.get(nxt, nxt)
        i += 2
    return out


def _to_base62(n):
    digits = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
    if n == 0:
        return '0'
    out = ''
    while n > 0:
        out = digits[n % 62] + out
        n //= 62
    return out


def _unpack_packer(html):
    m = re.search(r"eval\(function\(p,a,c,k,e,d\)[^}]*\}\('((?:[^'\\]|\\.)*)',(\d+),(\d+),'((?:[^'\\]|\\.)*)'\.split\('\|'\)", html or '')
    if not m:
        return None
    payload = _js_unescape(m.group(1))
    try:
        radix = int(m.group(2))
        count = int(m.group(3))
    except Exception:
        return None
    if radix != 62 or count == 0:
        return None
    d = _js_unescape(m.group(4)).split('|')
    if len(d) < count:
        return None
    out = payload
    for c in range(count - 1, -1, -1):
        word = d[c]
        if not word:
            continue
        key = _to_base62(c)
        out = re.sub(r'\b%s\b' % re.escape(key), lambda mm: word, out)
    return out


def _extract_links(unpacked):
    for key in ('hls2', 'hls4', 'hls3'):
        marker = '"%s":"' % key
        p = unpacked.find(marker)
        if p >= 0:
            s = p + len(marker)
            e = unpacked[s:].find('"')
            if e >= 0:
                url = unpacked[s:s + e]
                if '.m3u8' in url or 'master' in url:
                    return url
    return ''


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
        return 'Roshy'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cards(self, html):
        out = []
        seen = set()
        for block in (html or '').split('<article id="post-')[1:]:
            end = block.find('</article>')
            if end >= 0:
                block = block[:end]
            p = block.find('href="https://roshy.tv/video/')
            if p < 0:
                continue
            s = p + 6
            e = block[s:].find('"')
            if e < 0:
                continue
            href = block[s:s + e]
            if href in seen:
                continue
            p = block.find('title="')
            if p < 0:
                continue
            s = p + 7
            e = block[s:].find('"')
            if e < 0:
                continue
            title = _decode_entities(block[s:s + e])
            if not title:
                continue
            cover = ''
            rest = block
            while True:
                p = rest.find('https://roshy.tv/wp-content/uploads/')
                if p < 0:
                    break
                after = rest[p:]
                end2 = len(after)
                for i, c in enumerate(after):
                    if c in '"\' <':
                        end2 = i
                        break
                url = after[:end2]
                if '.jpg' in url or '.webp' in url or '.png' in url:
                    cover = url
                    break
                rest = rest[p + 1:]
            labels = []
            rest2 = block
            while True:
                p = rest2.find('beeteam368-duration')
                if p < 0:
                    break
                after = rest2[p:]
                gt = after.find('>')
                if gt >= 0:
                    s = gt + 1
                    e = after[s:].find('<')
                    if e >= 0:
                        label = after[s:s + e].strip()
                        if label and label not in labels:
                            labels.append(label)
                rest2 = rest2[p + 1:]
                if len(labels) >= 3:
                    break
            seen.add(href)
            out.append({
                'vod_id': href,
                'vod_name': _truncate(title, 90),
                'vod_pic': cover,
                'vod_remarks': ' · '.join(labels),
            })
        return out

    def _catalog_url(self, category_id, page):
        slug = category_id or 'english-sub-11'
        if page <= 1:
            return '%s/category/%s/' % (HOST, slug)
        return '%s/category/%s/page/%s/' % (HOST, slug, page)

    def homeContent(self, filter=''):
        items = self._cards(_http_get(self._catalog_url('english-sub-11', 1), HOST + '/'))
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in CATS],
            'list': items,
        }

    def homeVideoContent(self):
        items = self._cards(_http_get(self._catalog_url('english-sub-11', 1), HOST + '/'))
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        items = self._cards(_http_get(self._catalog_url(tid, pg), HOST + '/'))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        if nid.startswith('http'):
            page_url = nid
        else:
            page_url = HOST + nid.lstrip('/')
        html = _http_get(page_url, HOST + '/')
        if not html:
            return {'list': []}
        title = ''
        m = re.search(r'property="og:title"[^>]*content="([^"]+)"', html)
        if not m:
            m = re.search(r'content="([^"]+)"[^>]*property="og:title"', html)
        if m:
            title = _decode_entities(m.group(1))
        if ' - ROSHY.TV' in title:
            title = title.split(' - ROSHY.TV')[0].strip()
        if not title:
            return {'list': []}
        cover = ''
        m = re.search(r'property="og:image"[^>]*content="([^"]+)"', html)
        if not m:
            m = re.search(r'content="([^"]+)"[^>]*property="og:image"', html)
        if m:
            cover = _decode_entities(m.group(1))
        desc = ''
        m = re.search(r'name="description"[^>]*content="([^"]+)"', html)
        if not m:
            m = re.search(r'content="([^"]+)"[^>]*name="description"', html)
        if m:
            desc = _decode_entities(m.group(1))
        actors = []
        rest = html
        while True:
            p = rest.find('href="https://roshy.tv/stars/')
            if p < 0:
                break
            after = rest[p:]
            gt = after.find('>')
            if gt >= 0:
                s = gt + 1
                e = after[s:].find('</a>')
                if e >= 0:
                    name = _decode_entities(after[s:s + e].strip())
                    if name and name not in actors:
                        actors.append(name)
            rest = rest[p + 1:]
            if len(actors) >= 8:
                break
        if actors:
            if desc:
                desc += '\n'
            desc += '女优：' + '、'.join(actors)
        desc = _truncate(desc, 400)
        play_title = _truncate(title, 60)
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': '、'.join(actors),
            'vod_director': '',
            'vod_remarks': '',
            'vod_year': '',
            'vod_area': '',
            'vod_content': desc,
            'type_name': '',
            'vod_tag': '',
            'vod_play_from': '在线播放',
            'vod_play_url': '正片$%s' % page_url,
            'stills': [cover] if cover else [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        url = '%s/?s=%s' % (HOST, urllib.parse.quote((key or '').strip()))
        items = self._cards(_http_get(url, HOST + '/'))[:60]
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        header = {'User-Agent': UA, 'Referer': HOST + '/'}
        if '.m3u8' in raw:
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        page_url = raw.split('$')[-1]
        html = _http_get(page_url, HOST + '/')
        embed = ''
        marker = 'video_url":"<iframe src="'
        p = (html or '').find(marker)
        if p >= 0:
            s = p + len(marker)
            e = html[s:].find('"')
            if e >= 0:
                embed = html[s:s + e]
        if not embed:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        embed_html = _http_get(embed, page_url)
        unpacked = _unpack_packer(embed_html or '')
        if not unpacked:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        url = _extract_links(unpacked)
        if not url:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        header['Referer'] = embed
        return {'parse': 0, 'playUrl': url, 'url': url, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', '']

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
