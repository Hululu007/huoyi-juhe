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


HOST = 'https://www.tokyomotion.net'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

CATS = [
    ('amateur', 'Amateur'),
    ('asian', 'Asian'),
    ('euro', 'Euro'),
    ('hentai', 'HENTAI'),
    ('homemade', 'Homemade'),
    ('jav', 'JAV'),
    ('pissing', 'Pissing'),
    ('voyeur', 'Voyeur'),
    ('webcam', 'WebCam'),
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


def _resolve_final(url, referer, timeout=25):
    h = {'User-Agent': UA, 'Referer': referer}
    if _HAS_REQ:
        try:
            r = requests.get(url, headers=h, timeout=timeout, allow_redirects=True)
            if r.url and r.url != url:
                return r.url
        except Exception:
            pass
    try:
        req = urllib.request.Request(url, headers=h)
        with urllib.request.urlopen(req, timeout=timeout, context=_ctx()) as resp:
            final = resp.geturl()
            if final and final != url:
                return final
    except Exception:
        pass
    return url


def _decode_entities(s):
    if not s:
        return ''
    return _html.unescape(s.replace('&nbsp;', ' ')).strip()


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
    for block in (html or '').split('<a href="/video/')[1:]:
        e = block.find('"')
        if e < 0:
            continue
        path = block[:e]
        if '/' not in path:
            continue
        card_end = block.find('</a>')
        card = block[:card_end] if card_end >= 0 else block
        head = block[:200] if len(block) > 200 else block
        if 'thumb-popu' not in head and 'thumb-overlay' not in card:
            continue
        page_url = '%s/video/%s' % (HOST, path)
        if page_url in seen:
            continue
        cover = ''
        ip = card.find('<img src="')
        if ip >= 0:
            s = ip + 10
            ce = card[s:].find('"')
            if ce >= 0:
                cover = card[s:s + ce]
        remark = ''
        dp = card.find('<div class="duration">')
        if dp >= 0:
            s = dp + 22
            de = card[s:].find('</div>')
            if de >= 0:
                remark = _strip_tags(card[s:s + de])
        title = ''
        tp = card.find('video-title')
        if tp >= 0:
            after = card[tp:]
            gt = after.find('>')
            if gt >= 0:
                s = gt + 1
                e2 = after[s:].find('</span>')
                if e2 >= 0:
                    title = _strip_tags(after[s:s + e2])
        title = _trunc(title, 90)
        if not title:
            continue
        seen.add(page_url)
        out.append({'vod_id': page_url, 'vod_name': title, 'vod_pic': cover, 'vod_remarks': remark})
    return out


def _catalog_url(tid, pg):
    def _wp(base):
        if pg <= 1:
            return base
        return '%s?page=%s' % (base, pg)
    if tid == 'latest':
        return _wp(HOST + '/videos')
    if tid.startswith('cat:'):
        return _wp('%s/videos/%s' % (HOST, tid[4:]))
    return _wp(HOST + '/videos')


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
    if ' - TOKYO Motion' in t:
        return t.rsplit(' - TOKYO Motion', 1)[0].strip()
    return t


class Spider(BaseSpider):
    def getName(self):
        return 'TokyoMotion'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=''):
        cats = [('latest', '最新视频')] + [('cat:%s' % s, n) for s, n in CATS]
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
            items = self.categoryContent('latest', 1).get('list') or []
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
        duration = _meta_content(html, 'property', 'video:duration')
        synopsis = ''
        try:
            total = int(float(duration))
            synopsis = '时长：%02d:%02d:%02d' % (total // 3600, (total // 60) % 60, total % 60)
        except Exception:
            synopsis = ''
        return {'list': [{
            'vod_id': page_url,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': '',
            'vod_year': '',
            'vod_area': '',
            'vod_content': synopsis,
            'type_name': '',
            'vod_tag': '',
            'vod_play_from': '在线播放',
            'vod_play_url': '正片$%s' % page_url,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        url = '%s/search?search_query=%s&search_type=videos&type=public' % (HOST, urllib.parse.quote(str(key or '')))
        html = _http_get(url, referer=HOST + '/')
        items = _cards(html)[:60]
        return {'list': items, 'page': _norm_pg(pg), 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        header = {'User-Agent': UA, 'Referer': HOST + '/'}
        if raw.startswith('http') and raw.endswith('.mp4'):
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        page_url = raw.split('$')[-1]
        html = _http_get(page_url, referer=HOST + '/')
        vsrc = ''
        p = (html or '').find('<source src="')
        if p >= 0:
            s = p + 13
            e = html[s:].find('"')
            if e >= 0:
                vsrc = html[s:s + e]
        if not vsrc:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        ref = urllib.parse.quote(page_url, safe='/:?=&%#@!$+,;\'~*()-._')
        url = _resolve_final(vsrc, ref)
        header['Referer'] = ref
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
