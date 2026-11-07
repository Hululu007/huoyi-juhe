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
import http.client
import http.cookiejar
import json
import re
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

HOST = 'https://javdino.com'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

CATS = [
    ('big-tits', 'Big-Tits'), ('creampie', 'Creampie'), ('mature-woman', 'Mature Woman'),
    ('female-teacher', 'Female Teacher'), ('ntr', 'NTR'), ('mother-daughter', 'Mother-Daughter'),
    ('milf', 'MILF'), ('cheating-wife', 'Cheating Wife'), ('schoolgirl', 'Schoolgirl'),
    ('black-man', 'Black Man'), ('massage', 'Massage'), ('deep-throat', 'Deep-throat'),
    ('anal-sex', 'Anal Sex'), ('female-boss', 'Female Boss'), ('married-woman', 'Married Woman'),
    ('bondage', 'Bondage'), ('lesbian', 'Lesbian'), ('widow', 'Widow'),
    ('auntie', 'Auntie'), ('chubby', 'Chubby'), ('female-detective', 'Female Detective'),
    ('private-tutor', 'Private Tutor'), ('threesome-foursome', 'Threesome-Foursome'),
]

_JAR = http.cookiejar.CookieJar()
_OPENER = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(_JAR))


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _get(url, referer=None, timeout=30):
    h = {'User-Agent': UA, 'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'}
    if referer:
        h['Referer'] = referer
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
                return raw.decode('utf-8', 'replace')
        except urllib.error.HTTPError as e:
            try:
                return e.read().decode('utf-8', 'ignore')
            except http.client.IncompleteRead as ie:
                return ie.partial.decode('utf-8', 'ignore')
        except Exception:
            time.sleep(1)
    return ''


def _post_form(url, referer, body, timeout=30):
    h = {'User-Agent': UA, 'Accept': '*/*', 'Content-Type': 'application/x-www-form-urlencoded'}
    if referer:
        h['Referer'] = referer
    for _ in range(3):
        try:
            req = urllib.request.Request(url, data=body.encode('utf-8'), headers=h, method='POST')
            with _OPENER.open(req, timeout=timeout, context=_ctx()) as resp:
                raw = resp.read()
                enc = (resp.headers.get('Content-Encoding') or '').lower()
                if enc == 'gzip' or raw[:2] == b'\x1f\x8b':
                    try:
                        raw = gzip.decompress(raw)
                    except Exception:
                        pass
                return raw.decode('utf-8', 'replace')
        except urllib.error.HTTPError as e:
            try:
                return e.read().decode('utf-8', 'ignore')
            except http.client.IncompleteRead as ie:
                return ie.partial.decode('utf-8', 'ignore')
        except Exception:
            time.sleep(1)
    return ''


def _decode_entities(s):
    return _html.unescape(s or '').replace('&nbsp;', ' ').strip()


def _truncate(s, n):
    s = s or ''
    if len(s) > n:
        return s[:n]
    return s


def _parse_cards(html):
    out = []
    seen = set()
    for block in (html or '').split('<div class="v-items ')[1:]:
        end = block.find('<div class="v-items ')
        if end >= 0:
            block = block[:end]
        p = block.find('<a href="/video/')
        if p < 0:
            continue
        s = p + 9
        e = block[s:].find('"')
        if e < 0:
            continue
        href = block[s:s + e]
        vid = HOST + href
        if vid in seen:
            continue
        title = ''
        p = block.find('alt="')
        if p >= 0:
            s = p + 5
            e = block[s:].find('"')
            if e >= 0:
                title = _decode_entities(block[s:s + e])
        if not title:
            continue
        cover = ''
        p = block.find('<img src="')
        if p >= 0:
            s = p + 10
            e = block[s:].find('"')
            if e >= 0:
                cover = block[s:s + e]
        remark = ''
        m = re.search(r'(\d{1,3}:\d{2}(?::\d{2})?)', block)
        if m:
            remark = m.group(1)
        seen.add(vid)
        out.append({'vod_id': vid, 'vod_name': _truncate(title, 90), 'vod_pic': cover, 'vod_remarks': remark})
    return out


def _meta_content(html, attr, key):
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
    return _decode_entities(after[s:s + e]) if e >= 0 else ''


def _page_links(html, kind):
    marker = 'href="/%s/' % kind
    out = []
    rest = html or ''
    while True:
        p = rest.find(marker)
        if p < 0:
            break
        after = rest[p:]
        gt = after.find('>')
        if gt < 0:
            break
        s = gt + 1
        e = after[s:].find('</a>')
        if e < 0:
            break
        name = _decode_entities(after[s:s + e].strip())
        if name and not name.startswith('+') and not name.startswith('View All') and name not in out:
            out.append(name)
        rest = rest[p + 1:]
        if len(out) >= 8:
            break
    return out


def _decode_b64url(s):
    norm = s.replace('-', '+').replace('_', '/')
    while len(norm) % 4 != 0:
        norm += '='
    try:
        return base64.b64decode(norm).decode('utf-8', 'replace')
    except Exception:
        return None


def _extract_embeds(html):
    out = []
    rest = html or ''
    while True:
        p = rest.find("data-embed='")
        if p < 0:
            break
        s = p + 12
        e = rest[s:].find("'")
        if e < 0:
            break
        url = _decode_b64url(rest[s:s + e])
        if url and url.startswith('http') and url not in out:
            out.append(url)
        rest = rest[p + 1:]
    return out


def _first_m3u8(html):
    p = (html or '').find('.m3u8')
    if p < 0:
        return ''
    start = html[:p].rfind('https://')
    if start < 0:
        start = 0
    rest = html[start:]
    end = len(rest)
    for c in ('"', "'", '<', ' ', '\n'):
        i = rest.find(c)
        if i >= 0 and i < end:
            end = i
    url = rest[:end]
    return url if '.m3u8' in url else ''


def _js_unescape(s):
    out = []
    i = 0
    while i < len(s):
        c = s[i]
        if c != '\\':
            out.append(c)
            i += 1
            continue
        if i + 1 >= len(s):
            break
        n = s[i + 1]
        if n == '\\':
            out.append('\\')
            i += 2
        elif n == "'":
            out.append("'")
            i += 2
        elif n == '"':
            out.append('"')
            i += 2
        elif n == '/':
            out.append('/')
            i += 2
        elif n == 'n':
            out.append('\n')
            i += 2
        elif n == 'r':
            out.append('\r')
            i += 2
        elif n == 't':
            out.append('\t')
            i += 2
        elif n == 'b':
            out.append('\b')
            i += 2
        elif n == 'f':
            out.append('\f')
            i += 2
        elif n == 'v':
            out.append('\v')
            i += 2
        elif n == '0':
            out.append('\0')
            i += 2
        elif n == 'x':
            try:
                out.append(chr(int(s[i + 2:i + 4], 16)))
            except Exception:
                pass
            i += 4
        elif n == 'u':
            try:
                out.append(chr(int(s[i + 2:i + 6], 16)))
            except Exception:
                pass
            i += 6
        else:
            out.append(n)
            i += 2
    return ''.join(out)


def _to_base62(n):
    digits = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
    if n == 0:
        return '0'
    out = []
    while n > 0:
        out.append(digits[n % 62])
        n //= 62
    out.reverse()
    return ''.join(out)


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
    dict_raw = _js_unescape(m.group(4))
    words = dict_raw.split('|')
    if radix != 62 or count == 0 or len(words) < count:
        return None
    out = payload
    for c in range(count - 1, -1, -1):
        word = words[c]
        if not word:
            continue
        key = _to_base62(c)
        out = re.sub(r'\b%s\b' % re.escape(key), word, out)
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
        return 'JavDino'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=''):
        html = _get(HOST + '/genre/big-tits/', referer=HOST + '/')
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in CATS],
            'list': _parse_cards(html),
        }

    def homeVideoContent(self):
        html = _get(HOST + '/genre/big-tits/', referer=HOST + '/')
        return {'list': _parse_cards(html), 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        slug = _norm_id(tid) or 'big-tits'
        genre_url = HOST + '/genre/%s/' % slug
        if pg <= 1:
            html = _get(genre_url, referer=HOST + '/')
            items = _parse_cards(html)
            return {'list': items, 'page': pg, 'pagecount': 0, 'total': len(items)}
        body = 'keyword=%s%%2F&page=%d&sortBy=latest' % (urllib.parse.quote(slug, safe=''), pg)
        html = _post_form(HOST + '/ajax/genre_ajax.php', genre_url, body)
        items = _parse_cards(html)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': len(items)}

    def detailContent(self, ids):
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        page_url = nid if nid.startswith('http') else HOST + nid.lstrip('/')
        html = _get(page_url, referer=HOST + '/')
        title = _meta_content(html, 'property', 'og:title')
        if title.startswith('Watch '):
            title = title[len('Watch '):]
        p = title.find(' At Javdino')
        if p >= 0:
            title = title[:p].strip()
        if not title:
            return {'list': []}
        cover = _meta_content(html, 'property', 'og:image')
        desc = _meta_content(html, 'name', 'description')
        actresses = _page_links(html, 'actress')
        genres = _page_links(html, 'genre')
        lines = []
        if actresses:
            lines.append('女优：' + '、'.join(actresses))
        if genres:
            lines.append('类型：' + '、'.join(genres))
        if lines:
            if desc:
                desc += '\n'
            desc += '\n'.join(lines)
        play_title = _truncate(title, 60)
        return {'list': [{
            'vod_id': page_url,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': '、'.join(actresses),
            'vod_director': '',
            'vod_remarks': '',
            'vod_year': '',
            'vod_area': '',
            'vod_content': _truncate(desc, 400),
            'type_name': '、'.join(genres),
            'vod_tag': '、'.join(genres),
            'vod_play_from': '在线播放',
            'vod_play_url': '正片$%s$%s' % (play_title, page_url),
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        url = HOST + '/search/%s' % urllib.parse.quote((key or '').strip(), safe='')
        html = _get(url, referer=HOST + '/')
        items = _parse_cards(html)[:60]
        return {'list': items, 'page': _norm_pg(pg), 'pagecount': 0, 'total': len(items)}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        header = {'User-Agent': UA, 'Referer': HOST + '/'}
        if '.m3u8' in raw:
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        page_url = raw.split('$')[-1] if '$' in raw else raw
        html = _get(page_url, referer=HOST + '/')
        embeds = _extract_embeds(html)
        if not embeds:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        for embed in embeds:
            if 'hohoj.tv' in embed:
                embed_html = _get(embed, referer=page_url)
                url = _first_m3u8(embed_html)
                if url:
                    return {'parse': 0, 'playUrl': url, 'url': url, 'header': {'User-Agent': UA, 'Referer': embed}}
        for embed in embeds:
            if 'morencius.com' in embed or 'sadie-shop.site' in embed:
                embed_html = _get(embed, referer=page_url)
                unpacked = _unpack_packer(embed_html)
                if unpacked:
                    url = _extract_links(unpacked)
                    if url:
                        return {'parse': 0, 'playUrl': url, 'url': url, 'header': {'User-Agent': UA, 'Referer': embed}}
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
