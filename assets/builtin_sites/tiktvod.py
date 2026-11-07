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


HOST = 'https://tiktvod01.xyz'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

CATS = [
    ('latest', '最近更新'),
    ('domestic-media', '国产传媒'),
    ('japanese-av', '日本AV'),
    ('uncensored-video', '无码视频'),
    ('chinese-subtitles', '中文字幕'),
]


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
    return _html.unescape(s.replace('&nbsp;', ' ').replace('&ndash;', '–').replace('&mdash;', '—')).strip()


def _strip_tags(s):
    out = []
    in_tag = False
    for ch in (s or ''):
        if ch == '<':
            in_tag = True
        elif ch == '>':
            in_tag = False
        elif not in_tag:
            out.append(ch)
    return _decode_entities(''.join(out))


def _trunc(s, n):
    s = s or ''
    return s[:n] if len(s) > n else s


def _json_unescape(raw):
    if not raw:
        return ''
    try:
        return json.loads('"%s"' % raw)
    except Exception:
        return raw.replace('\\/', '/')


def _json_string_field(text, key):
    marker = '"%s"' % key
    p = (text or '').find(marker)
    if p < 0:
        return ''
    after = text[p + len(marker):].lstrip()
    if not after.startswith(':'):
        return ''
    rest = after[1:].lstrip()
    if not rest.startswith('"'):
        return ''
    rest = rest[1:]
    out = []
    i = 0
    while i < len(rest):
        ch = rest[i]
        if ch == '\\':
            if i + 1 < len(rest):
                nxt = rest[i + 1]
                if nxt == 'u' and i + 5 < len(rest):
                    try:
                        out.append(chr(int(rest[i + 2:i + 6], 16)))
                    except Exception:
                        pass
                    i += 6
                    continue
                out.append(nxt)
                i += 2
                continue
            break
        if ch == '"':
            break
        out.append(ch)
        i += 1
    return ''.join(out)


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


def _jsonld_items(html):
    out = []
    seen = set()
    for block in (html or '').split('"@type": "VideoObject"')[1:]:
        name = _json_string_field(block, 'name')
        if not name:
            continue
        content = _json_string_field(block, 'contentUrl')
        p = content.find('/vodplay/')
        if p < 0:
            continue
        s = p + 9
        e = content[s:].find('"')
        slug = content[s:s + e] if e >= 0 else content[s:]
        if not slug or slug in seen:
            continue
        cover = _json_string_field(block, 'thumbnailUrl')
        genre = _json_string_field(block, 'genre')
        seen.add(slug)
        out.append({'vod_id': '%s/vodplay/%s' % (HOST, slug), 'vod_name': _trunc(name, 90), 'vod_pic': cover, 'vod_remarks': genre})
    return out


def _home_cards(html):
    out = []
    seen = set()
    for block in (html or '').split('<div class="thumbnail group"')[1:]:
        if len(block) > 40 and 'display: none' in block[:40]:
            continue
        p = block.find('/vodplay/')
        if p < 0:
            continue
        s = p + 9
        e = len(block)
        for i in range(s, len(block)):
            ch = block[i]
            if not (ch.isalnum() or ch in '-_'):
                e = i
                break
        slug = block[s:e]
        if not slug or slug in seen:
            continue
        cover = ''
        cp = block.find('data-src="http')
        if cp >= 0:
            cs = cp + 10
            ce = block[cs:].find('"')
            if ce >= 0:
                cover = block[cs:cs + ce]
        else:
            sp = block.find('src="http')
            if sp >= 0:
                ss = sp + 5
                se = block[ss:].find('"')
                if se >= 0:
                    cover = block[ss:ss + se]
        title = ''
        tp = block.find('class="text-secondary')
        if tp >= 0:
            after = block[tp:]
            gt = after.find('>')
            if gt >= 0:
                s2 = gt + 1
                e2 = after[s2:].find('</a>')
                if e2 >= 0:
                    title = _decode_entities(after[s2:s2 + e2].strip())
        if not title:
            continue
        badges = []
        rest = block
        while True:
            bp = rest.find('<span class="absolute bottom-1')
            if bp < 0:
                break
            after = rest[bp:]
            gt = after.find('>')
            if gt >= 0:
                s3 = gt + 1
                e3 = after[s3:].find('</span>')
                if e3 >= 0:
                    t = after[s3:s3 + e3].strip()
                    if t and t not in badges:
                        badges.append(t)
            rest = rest[bp + 1:]
        seen.add(slug)
        out.append({'vod_id': '%s/vodplay/%s' % (HOST, slug), 'vod_name': _trunc(title, 90), 'vod_pic': cover, 'vod_remarks': '·'.join(badges)})
    return out


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
    if ' | ' in t:
        return t.rsplit(' | ', 1)[0].strip()
    return t


def _extract_player_url(html):
    pat = re.compile(r'"url":"((?:\\.|[^"\\])*)"')
    for m in pat.finditer(html or ''):
        raw = m.group(1)
        if 'm3u8' in raw:
            url = _json_unescape(raw)
            if url.startswith('http'):
                return url
    return ''


class Spider(BaseSpider):
    def getName(self):
        return 'TikTok成人版'

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
        if tid == 'latest' and pg > 1:
            return {'list': [], 'page': pg, 'pagecount': 0, 'total': 0}
        if tid == 'latest':
            url = HOST + '/'
        elif pg <= 1:
            url = '%s/vodtype/%s/' % (HOST, tid)
        else:
            url = '%s/vodtype/%s-%s/' % (HOST, tid, pg)
        html = _http_get(url, referer=HOST + '/')
        if tid == 'latest':
            items = _home_cards(html)
        else:
            items = _jsonld_items(html)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        page_url = _norm_id(ids)
        if '$' in page_url:
            page_url = page_url.split('$')[-1]
        if not page_url:
            return {'list': []}
        html = _http_get(page_url, referer=HOST + '/')
        title = _tag_title(html)
        if not title:
            return {'list': []}
        cover = _meta_content(html, 'property', 'og:image')
        vod_name = _json_string_field(html, 'vod_name')
        vod_actor = _json_string_field(html, 'vod_actor')
        vod_class = _json_string_field(html, 'vod_class')
        if vod_name:
            title = vod_name
        lines = []
        if vod_class:
            lines.append('分类：' + vod_class)
        if vod_actor:
            lines.append('演员：' + vod_actor)
        desc = _trunc('\n'.join(lines), 400)
        return {'list': [{
            'vod_id': page_url,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': vod_actor,
            'vod_director': '',
            'vod_remarks': '',
            'vod_year': '',
            'vod_area': '',
            'vod_content': desc,
            'type_name': vod_class,
            'vod_tag': vod_class,
            'vod_play_from': '在线播放',
            'vod_play_url': '正片$%s' % page_url,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        url = '%s/vodsearch/?wd=%s' % (HOST, urllib.parse.quote(str(key or '')))
        html = _http_get(url, referer=HOST + '/')
        items = _jsonld_items(html)[:60]
        return {'list': items, 'page': _norm_pg(pg), 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        header = {'User-Agent': UA, 'Referer': HOST + '/'}
        if raw.startswith('http') and '.m3u8' in raw:
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        page_url = raw.split('$')[-1]
        html = _http_get(page_url, referer=HOST + '/')
        url = _extract_player_url(html)
        if not url:
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
