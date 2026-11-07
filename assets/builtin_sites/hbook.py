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


BASE = 'https://hbook.tv'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
BUNNY_COOKIE = 'video_cdn_preference=bunny'

CATS = [
    ('latest', '最新视频', '/video'),
    ('free', '免费试看', '/free'),
    ('genre9', '中文字幕', '/genre/9'),
    ('actress', '女优', '/actress'),
    ('genre1', '痴女', '/genre/1'),
    ('genre2', '恋足', '/genre/2'),
    ('genre7', '高清', '/genre/7'),
    ('genre8', '独家', '/genre/8'),
    ('genre14', '后宫', '/genre/14'),
    ('genre17', '4K', '/genre/17'),
    ('genre37', '人妻', '/genre/37'),
]

PIC_RE = re.compile(r'data-src="([^"]+)"')
ALT_RE = re.compile(r'alt="([^"]*)"')
DUR_RE = re.compile(r'bottom-1 right-1[^>]*>\s*([\d:]+)\s*<')
ACTRESS_RE = re.compile(r'href="https://hbook\.tv/actress/(\d+)" title="([^"]+)"')
ACTRESS_PIC_RE = re.compile(r'<img[^>]+src="([^"]+)"')
ACTRESS_CNT_RE = re.compile(r'(\d+)部影片')
SOURCE_RE = re.compile(r'const source = "([^"]+)"')
H1_RE = re.compile(r'<h1[^>]*>(.*?)</h1>')
POSTER_RE = re.compile(r'data-poster="([^"]+)"')
H2_RE = re.compile(r'<h2[^>]*>(.*?)</h2>')
DUR2_RE = re.compile(r'title="视频时长".*?</svg>\s*([\d:]+)')
VIEWS_RE = re.compile(r'title="观看次数".*?</svg>\s*([\d,]+)')
ACTOR_RE = re.compile(r'href="https://hbook\.tv/actress/(\d+)"[^>]*>([^<]+)<')
TITLE_TAG_RE = re.compile(r'<title>(.*?)</title>')


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _unescape(s):
    if not s:
        return ''
    return _html.unescape(s).replace('\\/', '/').replace('&nbsp;', ' ').strip()


def _strip_tags(s):
    if not s:
        return ''
    return _unescape(re.sub(r'<[^>]+>', '', s))


def _fix_url(raw):
    u = _unescape(raw)
    if not u:
        return ''
    if u.startswith('http://') or u.startswith('https://') or u.startswith('data:'):
        return u
    if u.startswith('//'):
        return 'https:' + u
    if u.startswith('/'):
        return BASE + u
    return u


def _http_get(url, cookie=None, timeout=25):
    h = {'User-Agent': UA, 'Referer': BASE + '/', 'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8', 'Accept-Language': 'zh-CN,zh;q=0.9', 'Accept-Encoding': 'gzip, deflate'}
    if cookie:
        h['Cookie'] = cookie
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
    seen = set()
    for part in (html or '').split('href="https://hbook.tv/v/')[1:]:
        slug = part.split('"', 1)[0].strip()
        if not slug or slug in seen:
            continue
        seen.add(slug)
        block = part[:4000]
        pm = PIC_RE.search(block)
        pic = _fix_url(pm.group(1)) if pm else ''
        am = ALT_RE.search(block)
        name = _strip_tags(am.group(1)) if am else ''
        if not name:
            name = slug
        dm = DUR_RE.search(block)
        remark = dm.group(1) if dm else ''
        out.append({
            'vod_id': slug,
            'vod_name': name,
            'vod_pic': pic,
            'vod_remarks': remark,
        })
    return out


def _parse_actresses(html):
    out = []
    seen = set()
    for m in ACTRESS_RE.finditer(html or ''):
        aid = m.group(1)
        if aid in seen:
            continue
        seen.add(aid)
        start = m.start()
        block = html[start:start + 2500]
        pm = ACTRESS_PIC_RE.search(block)
        pic = _fix_url(pm.group(1)) if pm else ''
        cm = ACTRESS_CNT_RE.search(block)
        remark = '%s部影片' % cm.group(1) if cm else ''
        out.append({
            'vod_id': 'actress:' + aid,
            'vod_name': _strip_tags(m.group(2)),
            'vod_pic': pic,
            'vod_remarks': remark,
        })
    return out


def _detail_source(html):
    m = SOURCE_RE.search(html or '')
    return _unescape(m.group(1)) if m else ''


def _detail_source_live(slug, cookie=None):
    for _ in range(3):
        html = _http_get('%s/v/%s' % (BASE, slug), cookie=cookie)
        if html:
            src = _detail_source(html)
            if src:
                return src
        time.sleep(1)
    return ''


def _cat_path(tid):
    for cid, _name, path in CATS:
        if cid == tid:
            return path
    return '/video'


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
        return 'HBook'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cats(self):
        return [(cid, name) for cid, name, _p in CATS]

    def _catalog(self, tid, pg):
        if tid == 'actress':
            html = _http_get('%s/actress?page=%s' % (BASE, pg), referer=BASE + '/')
            return _parse_actresses(html)
        if tid == 'free':
            if pg > 1:
                return []
            html = _http_get(BASE + '/free', referer=BASE + '/')
            return _parse_cards(html)
        path = _cat_path(tid)
        html = _http_get('%s%s?page=%s' % (BASE, path, pg), referer=BASE + '/')
        return _parse_cards(html)

    def homeContent(self, filter=''):
        cats = self._cats()
        items = self._catalog('latest', 1)
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in cats],
            'list': items,
        }

    def homeVideoContent(self):
        items = self._catalog('latest', 1)
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        items = self._catalog(tid, pg)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        if nid.startswith('actress:'):
            aid = nid[len('actress:'):]
            html = _http_get('%s/actress/%s' % (BASE, aid), referer=BASE + '/')
            if not html:
                return {'list': []}
            tm = TITLE_TAG_RE.search(html)
            name = _strip_tags(tm.group(1)) if tm else ''
            name = name.replace('日本av女优 - 小黄书 hbook.tv', '').strip()
            if not name:
                name = '女优 %s' % aid
            works = _parse_cards(html)
            pic = works[0]['vod_pic'] if works else ''
            eps = ['%s$hbook:%s' % (w['vod_name'], w['vod_id']) for w in works]
            return {'list': [{
                'vod_id': nid,
                'vod_name': name,
                'vod_pic': pic,
                'vod_actor': name,
                'vod_director': '',
                'vod_remarks': '',
                'vod_year': '',
                'vod_area': '',
                'vod_content': '',
                'type_name': '女优',
                'vod_tag': '女优',
                'vod_play_from': '在线播放',
                'vod_play_url': '#'.join(eps),
                'stills': [],
            }]}
        slug = nid
        html = _http_get('%s/v/%s' % (BASE, slug), referer=BASE + '/')
        if not html:
            return {'list': []}
        hm = H1_RE.search(html)
        title = _strip_tags(hm.group(1)) if hm else ''
        pm = POSTER_RE.search(html)
        poster = _fix_url(pm.group(1)) if pm else ''
        synopsis = ''
        for m in H2_RE.finditer(html):
            t = _strip_tags(m.group(1))
            if len(t) >= 20:
                synopsis = t
                break
        actors = []
        for m in ACTOR_RE.finditer(html):
            name = _strip_tags(m.group(2))
            if name and name not in actors:
                actors.append(name)
            if len(actors) >= 5:
                break
        remarks = ''
        dm = DUR2_RE.search(html)
        if dm:
            remarks = dm.group(1)
        vm = VIEWS_RE.search(html)
        if vm:
            remarks = (remarks + ' | ' + vm.group(1)).strip(' |')
        source = _detail_source(html)
        eps = []
        if source:
            label = '预览' if 'preview_manifest' in source else '在线播放'
            eps.append('%s$hbook:%s' % (label, slug))
        src2 = _detail_source_live(slug, cookie=BUNNY_COOKIE)
        if src2 and src2 != source:
            eps.append('线路2$hbook:bunny:%s' % slug)
        if not title:
            title = slug
        if not synopsis:
            synopsis = title
        stills = [poster] if poster else []
        return {'list': [{
            'vod_id': slug,
            'vod_name': title,
            'vod_pic': poster,
            'vod_actor': ', '.join(actors),
            'vod_director': '',
            'vod_remarks': remarks,
            'vod_year': '',
            'vod_area': '',
            'vod_content': synopsis,
            'type_name': '',
            'vod_tag': '',
            'vod_play_from': '在线播放',
            'vod_play_url': '#'.join(eps),
            'stills': stills,
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        url = '%s/search?q=%s' % (BASE, urllib.parse.quote(key or ''))
        items = _parse_cards(_http_get(url, referer=BASE + '/'))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        if raw.startswith('hbook:'):
            raw = raw[len('hbook:'):]
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        slug = raw
        cookie = None
        if raw.startswith('bunny:'):
            slug = raw[len('bunny:'):]
            cookie = BUNNY_COOKIE
        source = _detail_source_live(slug, cookie=cookie)
        return {'parse': 0, 'playUrl': source, 'url': source, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', '']

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
