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


HOST = 'https://sexkbj.com'
EMBED_HOST = 'https://sexkbj.top'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

CATS = [
    ('latest', '最新'),
    ('most-viewed', '最多观看'),
    ('korean-bj', 'KOREAN BJ'),
    ('premium', 'PREMIUM'),
    ('afreecatv', 'AFREECATV'),
    ('korean-amateur', 'KOREAN AMATEUR'),
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
    return (s or '').replace('&nbsp;', ' ').replace('&amp;', '&').replace('&#039;', "'").replace('&#39;', "'").replace('&quot;', '"').replace('&lt;', '<').replace('&gt;', '>').replace('&ndash;', '–').replace('&mdash;', '—').strip()


def _truncate(s, n):
    if len(s) > n:
        return s[:n]
    return s


def _encode_base(n, base):
    def digit(v):
        if v <= 35:
            return '0123456789abcdefghijklmnopqrstuvwxyz'[v]
        return chr(v + 29)
    if n < base:
        return digit(n)
    out = ''
    while n >= base:
        out = digit(n % base) + out
        n //= base
    return digit(n) + out


def _js_unescape(s):
    out = ''
    i = 0
    mapping = {'n': '\n', 'r': '\r', 't': '\t', 'b': '\b', 'f': '\f', 'v': '\v', '0': '\0'}
    while i < len(s):
        c = s[i]
        if c != '\\':
            out += c
            i += 1
            continue
        if i + 1 >= len(s):
            out += '\\'
            break
        nxt = s[i + 1]
        out += mapping.get(nxt, nxt)
        i += 2
    return out


def _dean_unpack(packed):
    m = re.search(r"(?s)\}\('(.*)',(\d+),(\d+),'(.*)'\.split\('\|'\)", packed or '')
    if not m:
        return None
    payload = _js_unescape(m.group(1))
    try:
        base = int(m.group(2))
        count = int(m.group(3))
    except Exception:
        return None
    keys = m.group(4).split('|')
    d = {}
    for i in range(count):
        key = _encode_base(i, base)
        val = keys[i] if i < len(keys) else ''
        d[key] = val if val else key
    return re.sub(r'\w+', lambda mm: d.get(mm.group(0), mm.group(0)), payload)


def _extract_packed(html):
    start = html.find('eval(function(p,a,c,k,e,d)')
    if start < 0:
        return None
    after = html[start:]
    end = after.find('</script>')
    if end >= 0:
        after = after[:end]
    return after


def _attr(tag, name):
    marker = name + '="'
    p = tag.find(marker)
    if p < 0:
        return ''
    s = p + len(marker)
    e = tag[s:].find('"')
    if e < 0:
        return ''
    return _decode_entities(tag[s:s + e])


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
        return 'SexKbj'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cards(self, html):
        out = []
        seen = set()
        for block in (html or '').split('<article data-video-uid=')[1:]:
            end = block.find('<article data-video-uid=')
            if end >= 0:
                block = block[:end]
            hp = block.find('<a href="')
            if hp < 0:
                continue
            s = hp + 9
            e = block[s:].find('"')
            if e < 0:
                continue
            href = block[s:s + e]
            if not href.startswith('https://sexkbj.com/20'):
                continue
            if href in seen:
                continue
            title = ''
            p = block.find('title="')
            if p >= 0:
                s = p + 7
                e = block[s:].find('"')
                if e >= 0:
                    title = _decode_entities(block[s:s + e])
            cover = ''
            p = block.find('<img ')
            if p >= 0:
                img = block[p:]
                ds = _attr(img, 'data-src')
                src = _attr(img, 'src')
                if ds:
                    cover = ds
                elif src:
                    cover = src
                if not title:
                    title = _attr(img, 'alt')
            if not title:
                continue
            remark = ''
            p = block.find('class="duration"')
            if p >= 0:
                after = block[p:]
                gt = after.find('>')
                if gt >= 0:
                    s = gt + 1
                    e = after[s:].find('</span>')
                    if e >= 0:
                        remark = _decode_entities(after[s:s + e].strip())
                        gt2 = remark.rfind('>')
                        if gt2 >= 0:
                            remark = remark[gt2 + 1:].strip()
            seen.add(href)
            out.append({
                'vod_id': href,
                'vod_name': _truncate(title, 90),
                'vod_pic': cover,
                'vod_remarks': remark,
            })
        return out

    def _catalog_url(self, category_id, page):
        if category_id == 'latest':
            if page <= 1:
                return HOST + '/?filter=latest'
            return '%s/page/%s/?filter=latest' % (HOST, page)
        if category_id == 'most-viewed':
            if page <= 1:
                return HOST + '/?filter=most-viewed'
            return '%s/page/%s/?filter=most-viewed' % (HOST, page)
        base = '%s/category/%s/' % (HOST, category_id)
        if page <= 1:
            return base
        return '%spage/%s/' % (base, page)

    def homeContent(self, filter=''):
        items = self._cards(_http_get(self._catalog_url('latest', 1), HOST + '/'))
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in CATS],
            'list': items,
        }

    def homeVideoContent(self):
        items = self._cards(_http_get(self._catalog_url('latest', 1), HOST + '/'))
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        items = self._cards(_http_get(self._catalog_url(tid, pg), HOST + '/'))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        html = _http_get(nid, HOST + '/')
        if not html:
            return {'list': []}
        title = ''
        p = html.find('<title>')
        if p >= 0:
            s = p + 7
            e = html[s:].find('</title>')
            if e >= 0:
                title = _decode_entities(html[s:s + e])
        for sep in (' - SexKBJ', ' | SexKBJ'):
            if sep in title:
                title = title.rsplit(sep, 1)[0].strip()
        if not title:
            return {'list': []}
        cover = ''
        m = re.search(r'property="og:image"[^>]*content="([^"]+)"', html)
        if not m:
            m = re.search(r'content="([^"]+)"[^>]*property="og:image"', html)
        if m:
            cover = _decode_entities(m.group(1))
        dur = ''
        m = re.search(r'itemprop="duration"[^>]*content="([^"]+)"', html)
        if not m:
            m = re.search(r'content="([^"]+)"[^>]*itemprop="duration"', html)
        if m:
            raw = m.group(1)
            h = 0
            mi = 0
            s = 0
            num = ''
            for c in raw:
                if c.isdigit() or c == '.':
                    num += c
                else:
                    try:
                        v = float(num)
                    except Exception:
                        v = 0
                    if c == 'H':
                        h = int(v)
                    elif c == 'M':
                        mi = int(v)
                    elif c == 'S':
                        s = int(v)
                    num = ''
            total = h * 3600 + mi * 60 + s
            if total > 0:
                dur = '%s:%02d:%02d' % (h, mi, s) if h > 0 else '%s:%02d' % (mi, s)
        desc = '时长：' + dur if dur else ''
        play_title = _truncate(title, 60)
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': dur,
            'vod_year': '',
            'vod_area': '',
            'vod_content': desc,
            'type_name': '',
            'vod_tag': '',
            'vod_play_from': '在线播放',
            'vod_play_url': '正片$%s' % nid,
            'stills': [cover] if cover else [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        url = '%s/?s=%s' % (HOST, urllib.parse.quote(key or ''))
        items = self._cards(_http_get(url, HOST + '/'))[:60]
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        header = {'User-Agent': UA, 'Referer': HOST + '/'}
        if raw.startswith('http') and '.m3u8' in raw:
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        page_url = raw.split('$')[-1]
        html = _http_get(page_url, HOST + '/')
        if not html:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        m = re.search(r'https://sexkbj\.top/embed/([A-Za-z0-9]+)', html)
        if not m:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        embed_url = '%s/embed/%s' % (EMBED_HOST, m.group(1))
        embed_html = _http_get(embed_url, page_url)
        packed = _extract_packed(embed_html or '')
        if not packed:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        unpacked = _dean_unpack(packed)
        if not unpacked:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        url = ''
        m = re.search(r'"hls2":"([^"]+)"', unpacked)
        if m:
            url = m.group(1)
        if not url:
            m = re.search(r'"hls4":"([^"]+)"', unpacked)
            if m:
                p = m.group(1)
                url = p if p.startswith('http') else EMBED_HOST + p
        if not url:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        header['Referer'] = embed_url
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
