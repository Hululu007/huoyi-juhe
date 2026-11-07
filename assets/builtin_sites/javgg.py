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

HOST = 'https://javgg.net'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

CATS = [
    ('new-post', '最新发布'),
    ('trending', '热门趋势'),
    ('tag:uncensored-leak', '无码泄露'),
    ('tag:reduce-mosaic', '减码'),
    ('tag:censored', '有码'),
    ('tag:english-subtitle', '英文字幕'),
    ('tag:chinese-subtitle', '中文字幕'),
    ('genre', '类型'),
    ('star', '女优'),
    ('genre:creampie', 'Creampie'),
    ('genre:featured-actress', 'Featured Actress'),
    ('genre:exclusive-distribution', 'Exclusive Distribution'),
    ('genre:big-tits', 'Big Tits'),
    ('genre:hi-def', 'Hi-Def'),
    ('genre:married-woman', 'Married Woman'),
    ('genre:beautiful-girl', 'Beautiful Girl'),
    ('genre:solowork', 'Solowork'),
    ('genre:mature-woman', 'Mature Woman'),
    ('genre:4k', '4K'),
    ('star:yui-hatano', 'Yui Hatano'),
    ('star:yayoi-mizuki', 'Yayoi Mizuki'),
    ('star:morisawa-kana', 'Morisawa Kana'),
    ('star:matsumoto-ichika', 'Matsumoto Ichika'),
    ('star:hamasaki-mao', 'Hamasaki Mao'),
    ('star:shinoda-yuu', 'Shinoda Yuu'),
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


def _decode_entities(s):
    return _html.unescape(s or '').replace('&nbsp;', ' ').replace('&ndash;', '–').replace('&mdash;', '—').strip()


def _strip_tags(s):
    if not s:
        return ''
    t = re.sub(r'<[^>]+>', ' ', s)
    return _decode_entities(t)


def _truncate(s, n):
    s = s or ''
    if len(s) > n:
        return s[:n]
    return s


def _to_base(n, radix):
    digits = '0123456789abcdefghijklmnopqrstuvwxyz'
    if n == 0:
        return '0'
    out = []
    while n > 0:
        out.append(digits[n % radix])
        n //= radix
    out.reverse()
    return ''.join(out)


def _unpack_packer(packed):
    m = re.search(r"\}\('(.*)',(\d+),(\d+),'(.*)'\.split\('\|'\)\)", packed or '')
    if not m:
        return packed
    payload = m.group(1)
    try:
        radix = int(m.group(2))
        count = int(m.group(3))
    except Exception:
        return packed
    words = m.group(4).split('|')
    p = payload
    for c in range(count - 1, -1, -1):
        if c >= len(words) or not words[c]:
            continue
        word = _to_base(c, radix)
        p = re.sub(r'\b%s\b' % re.escape(word), words[c], p)
    return p


def _pick_hls(text):
    txt = None
    for m in re.finditer(r'"hls[234]"\s*:\s*"(https?://[^"]+\.(?:m3u8|txt)[^"]*)"', text or ''):
        u = m.group(1)
        if '.m3u8' in u:
            return u
        if txt is None:
            txt = u
    return txt


def _extract_hls(embed_html):
    u = _pick_hls(embed_html)
    if u:
        return u
    for m in re.finditer(r'https?://[^\s"\'<>]+(?:\.m3u8|master\.txt)[^\s"\'<>]*', embed_html or ''):
        if 'player_secure.php' not in m.group(0):
            return m.group(0)
    unpacked = _unpack_packer(embed_html)
    if unpacked != embed_html:
        u = _pick_hls(unpacked)
        if u:
            return u
        m = re.search(r'https?://[^\s"\'<>]+(?:\.m3u8|master\.txt)[^\s"\'<>]*', unpacked)
        if m:
            return m.group(0)
    return ''


def _parse_cards(html):
    out = []
    seen = set()
    for block in (html or '').split('<article')[1:]:
        end = block.find('</article>')
        if end >= 0:
            block = block[:end]
        if 'item movies' not in block and 'item ' not in block:
            continue
        p = block.find('<a href="https://javgg.net/jav/')
        if p < 0:
            continue
        s = p + 9
        e = block[s:].find('"')
        if e < 0:
            continue
        href = block[s:s + e]
        if href in seen:
            continue
        code = ''
        p = block.find('<h3><a href=')
        if p >= 0:
            after = block[p:]
            s = after.find('>')
            if s >= 0:
                s += 1
                e = after[s:].find('</a>')
                if e >= 0:
                    code = _strip_tags(after[s:s + e])
        if not code:
            p = block.find('alt="')
            if p >= 0:
                s = p + 5
                e = block[s:].find('"')
                if e >= 0:
                    code = _decode_entities(block[s:s + e])
        if not code:
            continue
        sub = ''
        p = block.find('titlecontent">')
        if p >= 0:
            s = p + 14
            e = block[s:].find('</div>')
            if e >= 0:
                sub = _strip_tags(block[s:s + e])
        title = code if not sub else code + ' ' + sub
        cover = ''
        p = block.find('data-src="')
        if p >= 0:
            s = p + 10
            e = block[s:].find('"')
            if e >= 0:
                cover = block[s:s + e]
        if not cover:
            p = block.find('<img src="')
            if p >= 0:
                s = p + 10
                e = block[s:].find('"')
                if e >= 0:
                    cover = block[s:s + e]
        seen.add(href)
        out.append({'vod_id': href, 'vod_name': _truncate(title, 90), 'vod_pic': cover, 'vod_remarks': ''})
    return out


def _parse_tax_index(html, kind):
    out = []
    marker = 'https://javgg.net/%s/' % kind
    rest = html or ''
    while True:
        p = rest.find(marker)
        if p < 0:
            break
        after = rest[p:]
        slug_end = after[len(marker):].find('/')
        if slug_end < 0:
            break
        slug = after[len(marker):len(marker) + slug_end]
        if not slug or '"' in slug or '<' in slug:
            rest = rest[p + len(marker):]
            continue
        gt = after.find('>')
        if gt < 0:
            break
        gt += 1
        e = after[gt:].find('</a>')
        if e < 0:
            break
        label = _strip_tags(after[gt:gt + e])
        count = ''
        name = label
        i = label.rfind(' (')
        if i >= 0 and label.endswith(')'):
            name = label[:i].strip()
            count = label[i + 2:len(label) - 1].strip()
        if name:
            out.append({'vod_id': '%s:%s' % (kind, slug), 'vod_name': name, 'vod_pic': '', 'vod_remarks': count})
        rest = after[gt:]
    return out


def _parse_search(html):
    out = []
    seen = set()
    for block in (html or '').split('result-item')[1:]:
        p = block.find('<a href="https://javgg.net/jav/')
        if p < 0:
            continue
        s = p + 9
        e = block[s:].find('"')
        if e < 0:
            continue
        href = block[s:s + e]
        if href in seen:
            continue
        title = ''
        p = block.find('<div class="title"><a href=')
        if p >= 0:
            after = block[p:]
            s = after.find('>')
            if s >= 0:
                s += 1
                e = after[s:].find('</a>')
                if e >= 0:
                    title = _strip_tags(after[s:s + e])
        if not title:
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
        p = block.find('<span class="year">')
        if p >= 0:
            s = p + 19
            e = block[s:].find('<')
            if e >= 0:
                remark = block[s:s + e].strip()
        seen.add(href)
        out.append({'vod_id': href, 'vod_name': _truncate(title, 90), 'vod_pic': cover, 'vod_remarks': remark})
    return out


def _list_url(tid, pg):
    def paged(base):
        if pg <= 1:
            return base
        return base.rstrip('/') + '/page/%d/' % pg
    if tid == 'new-post':
        return paged(HOST + '/new-post/')
    if tid == 'trending':
        return paged(HOST + '/trending/')
    if tid == 'genre':
        return HOST + '/genre/'
    if tid == 'star':
        return HOST + '/star/'
    if tid.startswith('tag:'):
        return paged(HOST + '/tag/%s/' % tid[4:])
    if tid.startswith('genre:'):
        return paged(HOST + '/genre/%s/' % tid[6:])
    if tid.startswith('star:'):
        return paged(HOST + '/star/%s/' % tid[5:])
    return paged(HOST + '/new-post/')


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


def _tag_title(html):
    p = html.find('<title>')
    if p < 0:
        return ''
    s = p + 7
    e = html[s:].find('</title>')
    if e < 0:
        e = len(html) - s
    t = _decode_entities(html[s:s + e])
    if ' | ' in t:
        head, _ = t.rsplit(' | ', 1)
        return head.strip()
    return t


def _embed_candidates(html):
    out = []
    m = re.search(r'itemprop="embedURL"[^>]*content="([^"]+)"', html or '')
    if m and m.group(1).startswith('http'):
        out.append(m.group(1))
    for m in re.finditer(r"""<iframe[^>]+src=['"]([^'"]+)['"]""", html or ''):
        u = m.group(1)
        if not u.startswith('http'):
            continue
        low = u.lower()
        if 'creative.' in low or 'googletagmanager' in low or 'facebook.com' in low or 'twitter.com' in low or 'x.com/intent' in low or 'reddit.com' in low or 't.me/share' in low or 'bsky.app' in low:
            continue
        if u not in out:
            out.append(u)
    return out


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
        return 'JavGG'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=''):
        html = _get(HOST + '/new-post/', referer=HOST + '/')
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in CATS],
            'list': _parse_cards(html),
        }

    def homeVideoContent(self):
        html = _get(HOST + '/new-post/', referer=HOST + '/')
        return {'list': _parse_cards(html), 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        tid = _norm_id(tid) or 'new-post'
        html = _get(_list_url(tid, pg), referer=HOST + '/')
        if tid == 'genre':
            items = _parse_tax_index(html, 'genre')
        elif tid == 'star':
            items = _parse_tax_index(html, 'star')
        else:
            items = _parse_cards(html)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': len(items)}

    def detailContent(self, ids):
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        if nid.startswith('genre:') or nid.startswith('star:'):
            kind, slug = nid.split(':', 1)
            html = _get(HOST + '/%s/%s/' % (kind, slug), referer=HOST + '/')
            cards = _parse_cards(html)
            eps = ['%s$%s' % (c['vod_name'], c['vod_id']) for c in cards]
            title = slug
            return {'list': [{
                'vod_id': nid, 'vod_name': title, 'vod_pic': '', 'vod_actor': '',
                'vod_director': '', 'vod_remarks': '', 'vod_year': '', 'vod_area': '',
                'vod_content': title, 'type_name': kind, 'vod_tag': kind,
                'vod_play_from': '在线播放', 'vod_play_url': '#'.join(eps), 'stills': [],
            }]}
        html = _get(nid, referer=HOST + '/')
        title = _tag_title(html)
        if not title:
            return {'list': []}
        cover = _meta_content(html, 'itemprop', 'thumbnailUrl')
        if not cover:
            cover = _meta_content(html, 'property', 'og:image')
        desc = _meta_content(html, 'itemprop', 'description')
        if not desc:
            desc = _meta_content(html, 'name', 'description')
        play_title = _truncate(title, 60)
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': '',
            'vod_year': '',
            'vod_area': '',
            'vod_content': _truncate(desc, 400),
            'type_name': '',
            'vod_tag': '',
            'vod_play_from': '在线播放',
            'vod_play_url': '正片$%s$%s' % (play_title, nid),
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        url = HOST + '/?s=%s' % urllib.parse.quote(str(key or ''))
        html = _get(url, referer=HOST + '/')
        items = _parse_search(html)[:60]
        return {'list': items, 'page': _norm_pg(pg), 'pagecount': 0, 'total': len(items)}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        header = {'User-Agent': UA, 'Referer': HOST + '/'}
        if raw.startswith('http') and '.m3u8' in raw:
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        page_url = raw.split('$')[-1] if '$' in raw else raw
        html = _get(page_url, referer=HOST + '/')
        candidates = _embed_candidates(html)
        for embed in candidates:
            embed_html = _get(embed, referer=page_url)
            if not embed_html:
                continue
            url = _extract_hls(embed_html)
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
