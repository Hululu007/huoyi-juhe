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

HOST = 'https://hgtv.im'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

CATS = [
    ('home', '首页'),
    ('3', '经典魔改'),
    ('10', '家庭伦理'),
    ('2', '都市爱情'),
    ('17', '特殊趣味'),
    ('11', '校园记忆'),
    ('1', '古装玄幻'),
    ('6', '现代惊悚'),
    ('13', '域外传奇'),
    ('4', '经典动漫'),
    ('5', 'AI演示'),
    ('12', '特殊口味'),
    ('9', '异能穿越'),
    ('68', '二次元区'),
]

_JAR = http.cookiejar.CookieJar()
_OPENER = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(_JAR))


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _cookies():
    return '; '.join('%s=%s' % (c.name, c.value) for c in _JAR)


def _http(url, headers=None, timeout=30):
    h = {'User-Agent': UA, 'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'}
    if headers:
        h.update(headers)
    for _ in range(3):
        try:
            req = urllib.request.Request(url, headers=h)
            with _OPENER.open(req, timeout=timeout, context=_ctx()) as resp:
                raw = resp.read()
                enc = (resp.headers.get('Content-Encoding') or '').lower()
                if enc == 'gzip' or raw[:2] == b'\x1f\x8b':
                    try:
                        raw = gzip.decompress(raw)
                    except Exception:
                        pass
                return raw.decode('utf-8', 'replace'), resp.geturl()
        except urllib.error.HTTPError as e:
            try:
                return e.read().decode('utf-8', 'ignore'), url
            except http.client.IncompleteRead as ie:
                return ie.partial.decode('utf-8', 'ignore'), url
        except Exception:
            time.sleep(1)
    return '', url


def _get(url, headers=None, timeout=30):
    return _http(url, headers=headers, timeout=timeout)[0]


def _clean(t):
    if not t:
        return ''
    t = re.sub(r'<[^>]+>', ' ', t)
    return _html.unescape(re.sub(r'\s+', ' ', t)).strip()


def _fix_url(u):
    if not u:
        return ''
    u = _html.unescape(u).replace('\\/', '/').strip()
    if u.startswith('//'):
        return 'https:' + u
    if u.startswith('http'):
        return u
    if u.startswith('/'):
        return HOST + u
    return HOST + '/' + u


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


def _jld(html, key):
    marker = '"%s":"' % key
    p = html.find(marker)
    if p < 0:
        return ''
    s = p + len(marker)
    out = []
    i = s
    while i < len(html):
        c = html[i]
        if c == '\\':
            if i + 1 < len(html):
                out.append(html[i + 1])
                i += 2
                continue
            break
        if c == '"':
            break
        out.append(c)
        i += 1
    return ''.join(out)


def _og(html, prop):
    marker = 'property="%s"' % prop
    p = html.find(marker)
    if p < 0:
        return ''
    after = html[p:]
    c = after.find('content="')
    if c < 0:
        return ''
    s = c + 9
    e = after[s:].find('"')
    return after[s:s + e] if e >= 0 else ''


def _meta_name(html, name):
    marker = 'name="%s"' % name
    p = html.find(marker)
    if p < 0:
        return ''
    after = html[p:]
    c = after.find('content="')
    if c < 0:
        return ''
    s = c + 9
    e = after[s:].find('"')
    return after[s:s + e] if e >= 0 else ''


def _strip_tags(s):
    return _clean(s)


def _attr(block, name):
    marker = '%s="' % name
    p = block.find(marker)
    if p < 0:
        return ''
    s = p + len(marker)
    e = block[s:].find('"')
    return block[s:s + e] if e >= 0 else ''


def _tag_text(block, tag):
    p = block.find('<%s' % tag)
    if p < 0:
        return ''
    after = block[p:]
    s = after.find('>')
    if s < 0:
        return ''
    s += 1
    close = '</%s>' % tag
    e = after[s:].find(close)
    if e < 0:
        e = len(after) - s
    return _strip_tags(after[s:s + e])


def _span_text(block, cls):
    marker = 'class="%s"' % cls
    p = block.find(marker)
    if p < 0:
        return ''
    after = block[p:]
    s = after.find('>')
    if s < 0:
        return ''
    s += 1
    e = after[s:].find('<')
    if e < 0:
        e = len(after) - s
    return _strip_tags(after[s:s + e])


def _count_text(block):
    p = block.find('class="count"')
    if p < 0:
        return ''
    after = block[p:]
    s = after.find('>')
    if s < 0:
        return ''
    s += 1
    rest = after[s:]
    end = rest.find('</div>')
    seg = rest[:end] if end >= 0 else rest
    b = seg.find('<b>')
    if b >= 0:
        s2 = b + 3
        e2 = seg[s2:].find('</b>')
        if e2 >= 0:
            return _strip_tags(seg[s2:s2 + e2])
    return _strip_tags(seg)


def _parse_cards(html):
    out = []
    for block in html.split('<article class="card"')[1:]:
        end = block.find('</article>')
        if end >= 0:
            block = block[:end]
        m = re.search(r'href="/drama/(\d+)\.html"', block)
        if not m:
            continue
        vid = m.group(1)
        title = _tag_text(block, 'h3')
        if not title:
            continue
        cover = _fix_url(_attr(block, 'src'))
        bits = []
        for v in (_span_text(block, 'card-score'), _span_text(block, 'heat'), _count_text(block)):
            if v:
                bits.append(v)
        out.append({'vod_id': vid, 'vod_name': title, 'vod_pic': cover, 'vod_remarks': ' · '.join(bits)})
    return out


def _catalog_url(tid, pg):
    if tid in ('home', ''):
        base = HOST + '/index.html'
        return base if pg <= 1 else HOST + '/page/%d.html' % pg
    base = HOST + '/category/%s.html' % tid
    return base if pg <= 1 else HOST + '/category/%s-p%d.html' % (tid, pg)


class Spider(BaseSpider):
    def getName(self):
        return '黄果短剧HGTV'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=''):
        html = _get(_catalog_url('home', 1), headers={'Referer': HOST + '/'})
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in CATS],
            'list': _parse_cards(html),
        }

    def homeVideoContent(self):
        html = _get(_catalog_url('home', 1), headers={'Referer': HOST + '/'})
        return {'list': _parse_cards(html), 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        tid = _norm_id(tid) or 'home'
        html = _get(_catalog_url(tid, pg), headers={'Referer': HOST + '/'})
        items = _parse_cards(html)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': len(items)}

    def detailContent(self, ids):
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        html = _get(HOST + '/drama/%s.html' % nid, headers={'Referer': HOST + '/'})
        title = _jld(html, 'name') or _og(html, 'og:title')
        p = title.find(' - 黄果TV')
        if p >= 0:
            title = title[:p]
        if not title:
            return {'list': []}
        cover = _fix_url(_jld(html, 'image') or _og(html, 'og:image'))
        desc = _jld(html, 'description') or _meta_name(html, 'description') or _og(html, 'og:description')
        genre = _jld(html, 'genre')
        eps = []
        seen = set()
        for m in re.finditer(r'href="/watch/(\d+)_(\d+)\.html"', html):
            if m.group(1) == nid:
                n = int(m.group(2))
                if n not in seen:
                    seen.add(n)
                    eps.append(n)
        if not eps:
            for m in re.finditer(r'"episodeNumber":(\d+)', html):
                n = int(m.group(1))
                if n not in seen:
                    seen.add(n)
                    eps.append(n)
        if not eps:
            m = re.search(r'"numberOfEpisodes":(\d+)', html)
            if m:
                total = int(m.group(1))
                if total > 0:
                    eps = list(range(1, total + 1))
        if not eps:
            eps = [1]
        eps.sort()
        play_url = '#'.join('第%d集$hgtvim:%s:%d' % (n, nid, n) for n in eps)
        remark = ('%s · 共 %d 集' % (genre, len(eps))) if genre else ('共 %d 集' % len(eps))
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': remark,
            'vod_year': '',
            'vod_area': '',
            'vod_content': desc,
            'type_name': genre,
            'vod_tag': genre,
            'vod_play_from': '在线播放',
            'vod_play_url': play_url,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        enc = urllib.parse.quote(str(key or ''), safe='')
        html = _get(HOST + '/search/%s.html' % enc, headers={'Referer': HOST + '/'})
        p = html.find('<div class="cards t4-list">')
        if p >= 0:
            rest = html[p:]
            end = rest.find('<section')
            if end >= 0:
                html = rest[:end]
        items = _parse_cards(html)
        return {'list': items, 'page': _norm_pg(pg), 'pagecount': 0, 'total': len(items)}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        header = {'User-Agent': UA, 'Referer': HOST + '/'}
        if '.m3u8' in raw or '.mp4' in raw:
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        parts = raw.replace('hgtvim:', '').split(':')
        sid = parts[0] if parts else ''
        try:
            ep = int(parts[1]) if len(parts) > 1 else 1
        except Exception:
            ep = 1
        if not sid:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        watch_url = HOST + '/watch/%s_%d.html' % (sid, ep)
        html = _get(watch_url, headers={'Referer': HOST + '/'})
        play_path = '/play/%s_%d.html' % (sid, ep)
        m = re.search(r'data-src="([^"]+)"', html or '')
        if m and m.group(1):
            play_path = m.group(1)
        play_url = _fix_url(play_path)
        ck = _cookies()
        h = {'User-Agent': UA, 'Accept': 'application/vnd.apple.mpegurl, */*', 'Referer': watch_url}
        if ck:
            h['Cookie'] = ck
        try:
            req = urllib.request.Request(play_url, headers=h)
            with _OPENER.open(req, timeout=30, context=_ctx()) as resp:
                final = resp.geturl()
                body = resp.read().decode('utf-8', 'replace')
            if '.m3u8' in final or '.mp4' in final:
                return {'parse': 0, 'playUrl': final, 'url': final, 'header': {'User-Agent': UA, 'Referer': watch_url}}
            if body.lstrip().startswith('#EXTM3U'):
                hh = {'User-Agent': UA, 'Referer': watch_url}
                ck2 = _cookies()
                if ck2:
                    hh['Cookie'] = ck2
                return {'parse': 0, 'playUrl': play_url, 'url': play_url, 'header': hh}
            m2 = re.search(r'https?://[^\s"\'<>]+\.m3u8', body)
            if m2:
                return {'parse': 0, 'playUrl': m2.group(0), 'url': m2.group(0), 'header': {'User-Agent': UA, 'Referer': watch_url}}
        except Exception:
            pass
        hh = {'User-Agent': UA, 'Referer': watch_url}
        ck3 = _cookies()
        if ck3:
            hh['Cookie'] = ck3
        return {'parse': 0, 'playUrl': play_url, 'url': play_url, 'header': hh}

    def localProxy(self, param):
        return [404, 'text/plain', '']

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
