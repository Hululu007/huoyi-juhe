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

HOST = 'https://japan-whores.com'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

CATS = [
    ('latest-updates', '最新'),
    ('most-popular', '最热'),
    ('top-rated', '好评'),
    ('c:anal-penetration', 'Anal'),
    ('c:blowjob', 'Blowjob'),
    ('c:group-sex', 'Group Sex'),
    ('c:creampie-eating', 'Creampie'),
    ('c:hot-mature', 'Hot Mature'),
    ('c:kimono', 'Kimono'),
    ('c:school-girl', 'School Uniform 18+'),
    ('c:shemale', 'Shemale'),
    ('c:blonde', 'Blonde'),
    ('c:cum-swallow', 'Cum Swallow'),
    ('c:boob-fuck', 'Boob Fuck'),
    ('c:dildo-riding', 'Dildo Riding'),
    ('c:defloration', 'Defloration'),
    ('c:transparent-lingerie', 'Transparent Lingerie'),
    ('c:red-pantie', 'Red Pantie'),
    ('c:foot-sucking', 'Foot Sucking'),
    ('c:puffy-nipples', 'Puffy Nipples'),
    ('c:micro', 'Micro'),
    ('c:reporter', 'Reporter'),
    ('c:forest', 'Forest'),
    ('c:naked', 'Naked'),
    ('c:mmmf', 'MMMF'),
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


def _truncate(s, n):
    s = s or ''
    if len(s) > n:
        return s[:n]
    return s


def _parse_cards(html):
    out = []
    seen = set()
    for block in (html or '').split('<div class="item thumb">')[1:]:
        end = block.find('<div class="item thumb">')
        if end >= 0:
            block = block[:end]
        p = block.find('<a href="https://japan-whores.com/videos/')
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
        p = block.find('title="')
        if p >= 0:
            s = p + 7
            e = block[s:].find('"')
            if e >= 0:
                title = _decode_entities(block[s:s + e])
        if not title:
            continue
        cover = ''
        p = block.find('data-original="')
        if p >= 0:
            s = p + 15
            e = block[s:].find('"')
            if e >= 0:
                cover = block[s:s + e]
        remark = ''
        p = block.find('<span class="time">')
        if p >= 0:
            s = p + 19
            e = block[s:].find('</span>')
            if e >= 0:
                remark = block[s:s + e].strip()
        seen.add(href)
        out.append({'vod_id': href, 'vod_name': _truncate(title, 90), 'vod_pic': cover, 'vod_remarks': remark})
    return out


def _catalog_url(tid, pg):
    if tid.startswith('c:'):
        return HOST + '/c/%s/' % tid[2:]
    if pg <= 1:
        return HOST + '/%s/' % tid
    return HOST + '/%s/%d/' % (tid, pg)


def _iso_duration(s):
    m = re.match(r'PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?', s or '')
    if not m:
        return ''
    h = int(m.group(1) or 0)
    mi = int(m.group(2) or 0)
    sec = int(m.group(3) or 0)
    if h > 0:
        return '%d:%02d:%02d' % (h, mi, sec)
    return '%d:%02d' % (mi, sec)


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


def _flashvar(html, key):
    marker = "%s: '" % key
    p = html.find(marker)
    if p < 0:
        return ''
    s = p + len(marker)
    e = html[s:].find("'")
    return html[s:s + e] if e >= 0 else ''


def _tag_title(html):
    p = html.find('<title>')
    if p < 0:
        return ''
    s = p + 7
    e = html[s:].find('</title>')
    if e < 0:
        e = len(html) - s
    t = _decode_entities(html[s:s + e])
    for sep in (' ▪ ', ' - ', ' | '):
        if sep in t:
            head, _ = t.rsplit(sep, 1)
            return head.strip()
    return t


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
        return 'Japan Whores'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=''):
        html = _get(HOST + '/latest-updates/', referer=HOST + '/')
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in CATS],
            'list': _parse_cards(html),
        }

    def homeVideoContent(self):
        html = _get(HOST + '/latest-updates/', referer=HOST + '/')
        return {'list': _parse_cards(html), 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        tid = _norm_id(tid) or 'latest-updates'
        if tid.startswith('c:') and pg > 1:
            return {'list': [], 'page': pg, 'pagecount': 0, 'total': 0}
        html = _get(_catalog_url(tid, pg), referer=HOST + '/')
        items = _parse_cards(html)
        has_more = bool(items) and not tid.startswith('c:')
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': len(items) if not has_more else 0}

    def detailContent(self, ids):
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        html = _get(nid, referer=HOST + '/')
        title = _tag_title(html)
        if not title:
            return {'list': []}
        cover = _meta_content(html, 'property', 'og:image')
        desc = _meta_content(html, 'name', 'description')
        duration = _iso_duration(_flashvar(html, 'duration'))
        cats = _flashvar(html, 'video_categories')
        lines = []
        if cats:
            lines.append('分类：' + cats)
        if duration:
            lines.append('时长：' + duration)
        synopsis = desc
        if lines:
            if synopsis:
                synopsis += '\n'
            synopsis += '\n'.join(lines)
        synopsis = _truncate(synopsis, 400)
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': duration,
            'vod_year': '',
            'vod_area': '',
            'vod_content': synopsis,
            'type_name': cats,
            'vod_tag': cats,
            'vod_play_from': '在线播放',
            'vod_play_url': '正片$%s' % nid,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        url = HOST + '/search/videos/?q=%s' % urllib.parse.quote(str(key or ''))
        html = _get(url, referer=HOST + '/')
        items = _parse_cards(html)[:60]
        return {'list': items, 'page': _norm_pg(pg), 'pagecount': 0, 'total': len(items)}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        header = {'User-Agent': UA, 'Referer': HOST + '/'}
        if '.mp4' in raw:
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        page_url = raw.split('$')[-1] if '$' in raw else raw
        html = _get(page_url, referer=HOST + '/')
        url = _flashvar(html, 'video_url')
        if not url:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        return {'parse': 0, 'playUrl': url, 'url': url, 'header': {'User-Agent': UA, 'Referer': page_url}}

    def localProxy(self, param):
        return [404, 'text/plain', '']

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
