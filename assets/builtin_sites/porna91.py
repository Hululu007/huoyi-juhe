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


HOST = 'https://91porna.com'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

CATS = [
    ('play', '正在播放'),
    ('now_month_hot', '热门排行榜'),
    ('original', '国产原创'),
    ('theme:1', '多P群交'),
    ('theme:12', '无码解放'),
    ('theme:5', '中文字幕'),
    ('theme:6', '制服诱惑'),
    ('theme:107', '黑人专区'),
    ('theme:7', 'SM调教'),
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


def _strip_tags(s):
    out = re.sub(r'<[^>]+>', '', s or '')
    return _decode_entities(out)


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
        return '91porna'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cards(self, html):
        out = []
        seen = set()
        for block in (html or '').split('<div class="video-item">')[1:]:
            end = block.find('<div class="video-item">')
            if end >= 0:
                block = block[:end]
            hp = block.find('video_key=')
            if hp < 0:
                continue
            after_key = block[hp + 10:]
            key_end = len(after_key)
            for i, c in enumerate(after_key):
                if c in '"\'& ':
                    key_end = i
                    break
            key = after_key[:key_end]
            if not key:
                continue
            if block[:hp].find('avdetail') >= 0:
                href = '%s/comic/index/avdetail?video_key=%s' % (HOST, key)
            else:
                href = '%s/comic/index/detail?video_key=%s' % (HOST, key)
            if href in seen:
                continue
            title = ''
            p = block.find('<img ')
            if p >= 0:
                title = _attr(block[p:], 'alt')
            if not title:
                p = block.find('<h2')
                if p >= 0:
                    after = block[p:]
                    gt = after.find('>')
                    if gt >= 0:
                        s = gt + 1
                        e = after[s:].find('</h2>')
                        if e >= 0:
                            title = _strip_tags(after[s:s + e])
            if not title:
                continue
            cover = ''
            if p >= 0:
                img = block[p:]
                ds = _attr(img, 'data-src')
                src = _attr(img, 'src')
                if ds and 'poster_loading' not in ds:
                    cover = ds
                elif src and 'poster_loading' not in src:
                    cover = src
            remark = ''
            p = block.find('opacity-50')
            if p >= 0:
                after = block[p:]
                gt = after.find('>')
                if gt >= 0:
                    s = gt + 1
                    e = after[s:].find('</div>')
                    if e >= 0:
                        remark = after[s:s + e].strip()
            seen.add(href)
            out.append({
                'vod_id': href,
                'vod_name': _truncate(title, 90),
                'vod_pic': cover,
                'vod_remarks': remark,
            })
        return out

    def _catalog_url(self, category_id, page):
        def with_page(base):
            if page <= 1:
                return base
            return '%s&page=%s' % (base, page)
        if category_id in ('play', 'now_month_hot', 'original'):
            return with_page('%s/comic/index/video?category=%s' % (HOST, category_id))
        if category_id.startswith('theme:'):
            return with_page('%s/comic/av/relvideo?model=%s&type=theme&order=week' % (HOST, category_id[6:]))
        return with_page('%s/comic/index/video?category=play' % HOST)

    def homeContent(self, filter=''):
        items = self._cards(_http_get(self._catalog_url('play', 1), HOST + '/'))
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in CATS],
            'list': items,
        }

    def homeVideoContent(self):
        items = self._cards(_http_get(self._catalog_url('play', 1), HOST + '/'))
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
        if ' - 91视频' in title:
            title = title.rsplit(' - 91视频', 1)[0].strip()
        for suf in (' 日本AV', ' A片'):
            if title.endswith(suf):
                title = title[:-len(suf)].strip()
        if not title:
            return {'list': []}
        cover = ''
        m = re.search(r'property="og:image"[^>]*content="([^"]+)"', html)
        if not m:
            m = re.search(r'content="([^"]+)"[^>]*property="og:image"', html)
        if m:
            cover = _decode_entities(m.group(1))
        desc = ''
        m = re.search(r'"description":"((?:[^"\\]|\\.)*)"', html)
        if m:
            desc = m.group(1).encode('utf-8').decode('unicode_escape', 'ignore') if '\\u' in m.group(1) else m.group(1)
        dur = ''
        m = re.search(r'property="video:duration"[^>]*content="([^"]+)"', html)
        if not m:
            m = re.search(r'content="([^"]+)"[^>]*property="video:duration"', html)
        if m:
            try:
                total = int(m.group(1))
                if total > 0:
                    h = total // 3600
                    mi = (total % 3600) // 60
                    s = total % 60
                    dur = '%s:%02d:%02d' % (h, mi, s) if h > 0 else '%s:%02d' % (mi, s)
            except Exception:
                pass
        tags = []
        rest = html
        while True:
            p = rest.find('property="video:tag"')
            if p < 0:
                break
            after = rest[p:]
            c = after.find('content="')
            if c >= 0:
                s = c + 9
                e = after[s:].find('"')
                if e >= 0:
                    t = _decode_entities(after[s:s + e])
                    if t and t not in tags:
                        tags.append(t)
            rest = rest[p + 1:]
            if len(tags) >= 10:
                break
        lines = []
        if dur:
            lines.append('时长：' + dur)
        if tags:
            lines.append('标签：' + '、'.join(tags))
        if lines:
            if desc:
                desc += '\n'
            desc += '\n'.join(lines)
        desc = _truncate(desc, 400)
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
            'vod_tag': '、'.join(tags),
            'vod_play_from': '在线播放',
            'vod_play_url': '正片$%s' % nid,
            'stills': [cover] if cover else [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        url = '%s/comic/index/search?keyword=%s' % (HOST, urllib.parse.quote(key or ''))
        items = self._cards(_http_get(url, HOST + '/'))[:60]
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        header = {'User-Agent': UA, 'Referer': HOST + '/'}
        if raw.startswith('http') and '.m3u8' in raw:
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        page_url = raw.split('$')[-1]
        detail_html = _http_get(page_url, HOST + '/')
        if not detail_html:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        vid = ''
        m = re.search(r'data-video="(\d+)"', detail_html)
        if m:
            vid = m.group(1)
        if not vid:
            m = re.search(r'/comic/index/embed\?id=(\d+)', detail_html)
            if m:
                vid = m.group(1)
        if not vid:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        cdn_auth = ''
        cdn_app = ''
        p = detail_html.find('id="cdn-config"')
        if p >= 0:
            tag = detail_html[p:]
            e = tag.find('>')
            if e >= 0:
                tag = tag[:e]
            cdn_auth = _attr(tag, 'data-video_cdn_auth_value')
            cdn_app = _attr(tag, 'data-cdn_app')
        embed_url = '%s/comic/index/embed?id=%s' % (HOST, vid)
        embed_html = _http_get(embed_url, page_url)
        packed = _extract_packed(embed_html or '')
        if not packed:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        unpacked = _dean_unpack(packed)
        if not unpacked:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        m = re.search(r'embed_play\.js\?img=([^"&]+)&u="\+encodeURIComponent\("([0-9a-f]+)"\)', unpacked)
        if not m:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        img = m.group(1)
        u = m.group(2)
        t = int(time.time()) // 2100
        play_js = '%s/index/embed_play.js?img=%s&u=%s&h=&t=%s' % (HOST, img, u, t)
        play_body = _http_get(play_js, embed_url)
        play_unpacked = _dean_unpack(play_body or '')
        if not play_unpacked:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        m = re.search(r'https://[^\s"\\]+\.m3u8[^\s"\\]*', play_unpacked)
        if not m:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        url = m.group(0)
        header['Referer'] = embed_url
        if cdn_auth:
            header['x-cdn-auth'] = cdn_auth
        if cdn_app:
            header['x-cdn-app'] = cdn_app
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
