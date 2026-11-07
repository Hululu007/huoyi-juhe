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


HOST = 'https://topjav.tv'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

CATS = [
    ('popular', '人気'),
    ('censored', '修正'),
    ('uncensored', '無修正'),
    ('reducing_mosaic', 'モザイク破壊'),
    ('genre:solowork', '単体作品'),
    ('genre:busty', '巨乳'),
    ('genre:creampie', '中出し'),
    ('genre:cosplay', 'コスプレ'),
    ('genre:teen', 'ティーン'),
    ('genre:debut', 'デビュー'),
    ('genre:massage', 'マッサージ'),
    ('genre:blowjob', 'フェラ'),
    ('genre:anal', 'アナル'),
    ('genre:lesbian', 'レズビアン'),
    ('genre:maid', 'メイド'),
    ('genre:virgin', '処女'),
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


def _decode_stream_url(payload):
    if not payload or len(payload) <= 32:
        return None
    inner = payload[16:len(payload) - 16]
    reversed_s = inner[::-1]
    try:
        raw = base64.b64decode(reversed_s)
        url = raw.decode('utf-8', 'replace')
    except Exception:
        return None
    if url.startswith('https://topjav.tv/m3u8/'):
        return url
    return None


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
    for block in (html or '').split('<article class="movie-item">')[1:]:
        end = block.find('</article>')
        if end >= 0:
            block = block[:end]
        hp = block.find('<a href="https://topjav.tv/video/')
        if hp < 0:
            continue
        s = hp + 9
        e = block[s:].find('"')
        if e < 0:
            continue
        href = block[s:s + e]
        if href in seen:
            continue
        title = ''
        h3p = block.find('<h3')
        if h3p >= 0:
            after = block[h3p:]
            gt = after.find('>')
            if gt >= 0:
                s2 = gt + 1
                e2 = after[s2:].find('</h3>')
                if e2 >= 0:
                    title = _decode_entities(after[s2:s2 + e2].strip())
        if not title:
            mp = block.find('class="main-image"')
            if mp >= 0:
                after = block[mp:]
                ap = after.find('alt="')
                if ap >= 0:
                    s3 = ap + 5
                    e3 = after[s3:].find('"')
                    if e3 >= 0:
                        title = _decode_entities(after[s3:s3 + e3])
        if not title:
            continue
        cover = ''
        mp = block.find('class="main-image"')
        if mp >= 0:
            after = block[mp:]
            sp = after.find('src="')
            if sp >= 0:
                s4 = sp + 5
                e4 = after[s4:].find('"')
                if e4 >= 0:
                    cover = after[s4:s4 + e4]
        remark = ''
        dp = block.find('<div class="duration">')
        if dp >= 0:
            s5 = dp + 22
            e5 = block[s5:].find('</div>')
            if e5 >= 0:
                remark = block[s5:s5 + e5].strip()
        seen.add(href)
        out.append({'vod_id': href, 'vod_name': _trunc(title, 90), 'vod_pic': cover, 'vod_remarks': remark})
    return out


def _catalog_url(tid, pg):
    def _wp(base):
        if pg <= 1:
            return base
        return '%s?page=%s' % (base, pg)
    if tid == 'popular':
        return _wp(HOST + '/popular')
    if tid in ('censored', 'uncensored', 'reducing_mosaic'):
        return _wp('%s/categories/%s' % (HOST, tid))
    if tid.startswith('genre:'):
        return _wp('%s/genre/%s' % (HOST, tid[6:]))
    if tid.startswith('pornstar:'):
        return _wp('%s/pornstar/%s' % (HOST, tid[9:]))
    if tid.startswith('makers:'):
        return _wp('%s/makers/%s' % (HOST, tid[7:]))
    return _wp(HOST + '/popular')


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
    for sep in ('　ー　', ' — ', ' | ', ' - '):
        if sep in t:
            return t.rsplit(sep, 1)[0].strip()
    return t


def _info_links(html, kind):
    marker = 'href="%s/%s/' % (HOST, kind)
    out = []
    rest = html or ''
    while True:
        p = rest.find(marker)
        if p < 0:
            break
        after = rest[p:]
        gt = after.find('>')
        if gt >= 0:
            s = gt + 1
            e = after[s:].find('</a>')
            if e >= 0:
                name = _strip_tags(after[s:s + e])
                if name and name not in out:
                    out.append(name)
        rest = rest[p + 1:]
        if len(out) >= 8:
            break
    return out


def _json_ld_field(html, key):
    marker = '"%s":' % key
    p = (html or '').find(marker)
    if p < 0:
        return ''
    rest = html[p + len(marker):].lstrip()
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


class Spider(BaseSpider):
    def getName(self):
        return 'TopJAV'

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
        html = _http_get(url, referer=HOST + '/')
        items = _cards(html)
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
        desc = _json_ld_field(html, 'description')
        actresses = _info_links(html, 'pornstar')
        makers = _info_links(html, 'makers')
        genres = _info_links(html, 'genre')
        published = _json_ld_field(html, 'datePublished')
        lines = []
        if actresses:
            lines.append('女優：' + '、'.join(actresses))
        if makers:
            lines.append('メーカー：' + '、'.join(makers))
        if genres:
            lines.append('ジャンル：' + '、'.join(genres))
        if published:
            lines.append('发布：' + published[:10])
        if lines:
            if desc:
                desc += '\n'
            desc += '\n'.join(lines)
        desc = _trunc(desc, 400)
        return {'list': [{
            'vod_id': page_url,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': '、'.join(actresses),
            'vod_director': '',
            'vod_remarks': '',
            'vod_year': published[:4] if len(published) >= 4 and published[:4].isdigit() else '',
            'vod_area': '',
            'vod_content': desc,
            'type_name': '、'.join(genres[:3]),
            'vod_tag': '、'.join(genres),
            'vod_play_from': '在线播放',
            'vod_play_url': '正片$%s' % page_url,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        url = '%s/search?s=%s' % (HOST, urllib.parse.quote(str(key or '')))
        html = _http_get(url, referer=HOST + '/')
        items = _cards(html)[:60]
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
        m = re.search(r'file: f\("([^"]+)"\)', html or '')
        if not m:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        url = _decode_stream_url(m.group(1))
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
