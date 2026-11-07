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


HOST = 'https://herexxx.com'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

CATS = [
    ('latest-updates', '最新'),
    ('most-popular:video_viewed', '最热'),
    ('most-popular:video_viewed_today', 'HOT'),
    ('cat:vip', 'KVIP'),
    ('cat:jvip', 'JVIP'),
    ('cat:korean-porn', 'Korean Porn'),
    ('cat:korean-bj', 'Korean BJ'),
    ('cat:fc2ppv', 'FC2PPV'),
    ('cat:jav', 'Uncensored'),
    ('cat:ipcam', 'IPCAM'),
    ('cat:toilet', 'Toilet'),
    ('cat:voyeur-jp', 'Voyeur JP'),
    ('cat:china', 'China'),
    ('cat:myfans', 'MyFans'),
    ('cat:asian-leak', 'Asian Leak'),
    ('cat:upskirt', 'Upskirt'),
    ('cat:mib', 'MIB'),
]

DUR_RE = re.compile(r'PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?')


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _decode_entities(s):
    if not s:
        return ''
    out = s.replace('&nbsp;', ' ').replace('&amp;', '&').replace('&#039;', "'").replace('&#39;', "'").replace('&quot;', '"').replace('&lt;', '<').replace('&gt;', '>').replace('&ndash;', '–').replace('&mdash;', '—')
    return _html.unescape(out).strip()


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


def _parse_cards(html):
    out = []
    seen = []
    for block in (html or '').split('<div class="item thumb">')[1:]:
        end = block.find('<div class="item thumb">')
        block = block[:end] if end >= 0 else block
        p = block.find('<a href="https://herexxx.com/video/')
        if p < 0:
            continue
        s = p + 9
        e = block.find('"', s)
        if e < 0:
            continue
        href = block[s:e]
        if href in seen:
            continue
        p = block.find('title="')
        if p < 0:
            continue
        s = p + 7
        e = block.find('"', s)
        title = _decode_entities(block[s:e]) if e >= 0 else ''
        if not title:
            continue
        p = block.find('data-original="')
        cover = ''
        if p >= 0:
            s = p + 15
            e = block.find('"', s)
            if e >= 0:
                cover = block[s:e]
        p = block.find('<span class="time">')
        remark = ''
        if p >= 0:
            s = p + 19
            e = block.find('</span>', s)
            if e >= 0:
                remark = block[s:e].strip()
        seen.append(href)
        out.append({
            'vod_id': href,
            'vod_name': title[:90],
            'vod_pic': cover,
            'vod_remarks': remark,
        })
    return out


def _catalog_url(tid, pg):
    page_part = '' if pg <= 1 else '%s/' % pg
    if tid.startswith('cat:'):
        return '%s/categories/%s/%s' % (HOST, tid[4:], page_part)
    if tid.startswith('most-popular:'):
        return '%s/most-popular/%s?sort_by=%s' % (HOST, page_part, tid[len('most-popular:'):])
    return '%s/%s/%s' % (HOST, tid, page_part)


def _iso_duration(s):
    m = DUR_RE.search(s or '')
    if not m:
        return ''
    h = int(m.group(1) or 0)
    mi = int(m.group(2) or 0)
    sec = int(m.group(3) or 0)
    if h > 0:
        return '%s:%02d:%02d' % (h, mi, sec)
    return '%s:%02d' % (mi, sec)


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
    e = after.find('"', s)
    if e < 0:
        return ''
    return _decode_entities(after[s:e])


def _flashvar(html, key):
    marker = "%s: '" % key
    p = html.find(marker)
    if p < 0:
        return ''
    s = p + len(marker)
    e = html.find("'", s)
    if e < 0:
        return ''
    return html[s:e]


def _tag_title(html):
    p = html.find('<title>')
    if p < 0:
        return ''
    s = p + 7
    e = html.find('</title>', s)
    t = _decode_entities(html[s:e] if e >= 0 else html[s:])
    for sep in (' | ', ' - '):
        if sep in t:
            return t.rsplit(sep, 1)[0].strip()
    return t


def _decode_video_url(b64):
    b64 = (b64 or '').strip()
    if not b64:
        return ''
    pad = '=' * ((4 - len(b64) % 4) % 4)
    try:
        return base64.b64decode(b64 + pad).decode('utf-8', 'replace').strip()
    except Exception:
        return ''


def _abs_url(u):
    if u.startswith('//'):
        return 'https:' + u
    return u


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
        return 'HereXXX'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cats(self):
        return list(CATS)

    def homeContent(self, filter=''):
        cats = self._cats()
        items = _parse_cards(_http_get(_catalog_url('latest-updates', 1), referer=HOST + '/'))
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in cats],
            'list': items,
        }

    def homeVideoContent(self):
        items = _parse_cards(_http_get(_catalog_url('latest-updates', 1), referer=HOST + '/'))
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        items = _parse_cards(_http_get(_catalog_url(tid, pg), referer=HOST + '/'))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        html = _http_get(nid, referer=HOST + '/')
        if not html:
            return {'list': []}
        title = _tag_title(html)
        if not title:
            return {'list': []}
        cover = _abs_url(_meta_content(html, 'property', 'og:image'))
        duration = _iso_duration(_flashvar(html, 'duration'))
        cats = _flashvar(html, 'video_categories')
        lines = []
        if cats:
            lines.append('分类：' + cats)
        if duration:
            lines.append('时长：' + duration)
        synopsis = '\n'.join(lines)[:400]
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
            'vod_play_url': '正片$herexxx:%s' % nid,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        url = '%s/search/?q=%s' % (HOST, urllib.parse.quote(key or ''))
        items = _parse_cards(_http_get(url, referer=HOST + '/'))[:60]
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        if raw.startswith('herexxx:'):
            raw = raw[len('herexxx:'):]
        header = {'User-Agent': UA, 'Referer': HOST + '/'}
        url = ''
        if '.mp4' in raw:
            url = raw
        else:
            page_url = raw.rsplit('$', 1)[-1]
            html = _http_get(page_url, referer=HOST + '/')
            if html:
                b64 = _flashvar(html, 'video_url')
                url = _decode_video_url(b64)
                if url:
                    header['Referer'] = page_url
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
