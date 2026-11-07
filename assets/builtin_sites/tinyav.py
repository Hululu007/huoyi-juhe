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


BASE = 'https://tinyavideo.com'
UA = 'Mozilla/5.0 (Linux; Android 14; HarmonyOS; HUAWEI) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36'

CATS = [
    ('asian/new', '國產AV'),
    ('japanese/new', '日本AV'),
    ('uncensored-leak/new', 'JAV無碼'),
    ('fc2/new', 'FC2素人'),
    ('ai/new', 'AI短劇'),
    ('hentai/new', '裏番'),
    ('western/new', '歐美'),
    ('korean/new', '韓國'),
    ('chinese-subtitles', '中文字幕'),
    ('actresses/asian', '女優總覽·國產'),
    ('actresses/japanese', '女優總覽·日本AV'),
    ('maker/asian', '發行商·國產'),
    ('maker/japanese', '發行商·日本AV'),
]


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _http_get(url, referer=None, timeout=25):
    h = {'User-Agent': UA, 'Referer': referer or (BASE + '/'), 'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8', 'Accept-Language': 'zh-CN,zh;q=0.9', 'Accept-Encoding': 'gzip, deflate'}
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


def _fix_url(raw):
    u = (raw or '').strip()
    if not u:
        return ''
    if u.startswith('http://') or u.startswith('https://'):
        return u
    if u.startswith('//'):
        return 'https:' + u
    if u.startswith('/'):
        return BASE + u
    return u


def _unescape(s):
    if not s:
        return ''
    return _html.unescape(s)


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


def _video_url(sid):
    sid = (sid or '').strip()
    if sid.startswith('http'):
        return sid
    if sid.startswith('/'):
        return BASE + sid
    return BASE + '/' + sid


def _parse_video_cards(html):
    out = []
    seen = set()
    link_re = re.compile(r'href="(/video/[^"]+)"')
    img_re = re.compile(r'<img[^>]*src="([^"]+)"[^>]*alt="([^"]*)"')
    title_re = re.compile(r'videotitle"><a[^>]*>([^<]+)</a>')
    count_re = re.compile(r'count-number">([^<]+)<')
    for m in link_re.finditer(html or ''):
        vid = m.group(1)
        if vid in seen:
            continue
        seen.add(vid)
        start = m.start()
        window = (html or '')[start:start + 2500]
        cover = ''
        title = ''
        im = img_re.search(window)
        if im:
            cover = _fix_url(im.group(1))
            title = _unescape(im.group(2).strip())
        if not title:
            tm = title_re.search(window)
            if tm:
                title = _unescape(tm.group(1).strip())
        if not title:
            continue
        cm = count_re.search(window)
        remark = cm.group(1).strip() if cm else ''
        out.append({'vod_id': vid, 'vod_name': title, 'vod_pic': cover, 'vod_remarks': remark})
    return out


def _parse_person_cards(html):
    out = []
    seen = set()
    pat = re.compile(r'<div class="tiop[^"]*">.*?<a href="(/actress/[^"]+|/maker/[^"]+)"[^>]*>([^<]+)</a>.*?<span>([\d,]+) 部影片</span>', re.S)
    for m in pat.finditer(html or ''):
        href = m.group(1)
        if href in seen:
            continue
        seen.add(href)
        if href in ('/maker/asian', '/maker/japanese'):
            continue
        name = _unescape(m.group(2).strip())
        if not name:
            continue
        remark = '%s 部影片' % m.group(3)
        out.append({'vod_id': 'folder@%s' % href, 'vod_name': name, 'vod_pic': '', 'vod_remarks': remark, 'vod_tag': 'folder'})
    return out


def _extract_m3u8(html):
    m = re.search(r'window\.m3u8List\s*=\s*\[(.*?)\]', html or '', re.S)
    if not m:
        return ''
    um = re.search(r'(https?://[^"\'\s]+\.m3u8[^"\'\s]*)', m.group(1))
    return um.group(1) if um else ''


def _extract_tags(html):
    start = (html or '').find('field-video-tags')
    if start < 0:
        return []
    region = html[start:start + 2000]
    tags = []
    seen = set()
    for m in re.finditer(r'#([^<\s]{1,30})', region):
        tag = m.group(1).strip()
        if tag and tag not in seen:
            seen.add(tag)
            tags.append(tag)
    return tags


class Spider(BaseSpider):
    def getName(self):
        return 'TinyAV'

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
        url = '%s/%s?page=%s' % (BASE, tid, pg - 1)
        html = _http_get(url)
        is_index = tid.startswith('actresses/') or tid.startswith('maker/')
        if is_index:
            items = _parse_person_cards(html)
        else:
            items = _parse_video_cards(html)
        has_more = ('?page=%s"' % pg) in (html or '')
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        sid = _norm_id(ids)
        if not sid:
            return {'list': []}
        if sid.startswith('folder@'):
            folder = sid[len('folder@'):]
            html = _http_get(_video_url(folder))
            cards = _parse_video_cards(html)
            title = ''
            tm = re.search(r'<title[^>]*>(.*?)</title>', html or '', re.S)
            if tm:
                title = _unescape(tm.group(1).strip().split(' | ')[0])
            eps = []
            for c in cards:
                eps.append('%s$%s' % (c['vod_name'], c['vod_id']))
            if not eps:
                return {'list': []}
            return {'list': [{
                'vod_id': sid,
                'vod_name': title,
                'vod_pic': '',
                'vod_actor': '',
                'vod_director': '',
                'vod_remarks': '',
                'vod_year': '',
                'vod_area': '',
                'vod_content': '',
                'type_name': '',
                'vod_tag': 'folder',
                'vod_play_from': '在线播放',
                'vod_play_url': '#'.join(eps),
                'stills': [],
            }]}
        url = _video_url(sid)
        html = _http_get(url)
        title = ''
        hm = re.search(r'<h1[^>]*class="[^"]*vdtitle[^"]*"[^>]*>(.*?)</h1>', html or '', re.S)
        if hm:
            title = _unescape(hm.group(1).strip())
        tags = _extract_tags(html)
        cover = ''
        cm = re.search(r'<video[^>]*poster="([^"]+)"', html or '')
        if cm:
            cover = _fix_url(cm.group(1))
        synopsis = ''
        for label, pat in [
            ('發行日期', r'發行日期\s*</div>\s*<div[^>]*>\s*([\d-]+)'),
            ('影片類型', r'影片類型\s*</div>\s*<div[^>]*>\s*([^<]+?)\s*</div>'),
            ('頻道', r'頻道\s*</div>\s*<div[^>]*>\s*([^<]+?)\s*</div>'),
        ]:
            m = re.search(pat, html or '')
            if m:
                v = _unescape(m.group(1).strip())
                if v:
                    if synopsis:
                        synopsis += ' / '
                    synopsis += '%s：%s' % (label, v)
        if tags:
            if synopsis:
                synopsis += ' / '
            synopsis += '標籤：' + '、'.join(tags)
        m3u8 = _extract_m3u8(html)
        if not title or not m3u8:
            return {'list': []}
        return {'list': [{
            'vod_id': sid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': '',
            'vod_year': '',
            'vod_area': '',
            'vod_content': synopsis,
            'type_name': '',
            'vod_tag': '、'.join(tags),
            'vod_play_from': '在线播放',
            'vod_play_url': '播放$%s' % m3u8,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        url = '%s/search?fulltext=%s' % (BASE, urllib.parse.quote(str(key or '')))
        html = _http_get(url)
        items = _parse_video_cards(html)
        return {'list': items, 'page': _norm_pg(pg), 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        if raw.startswith('http'):
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        html = _http_get(_video_url(raw))
        found = _extract_m3u8(html)
        if not found:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        return {'parse': 0, 'playUrl': found, 'url': found, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', b'', {}]

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
