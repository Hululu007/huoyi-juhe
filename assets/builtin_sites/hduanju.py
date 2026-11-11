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


BASE = 'https://xiaonverjtx.click'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

CATS = [
    ('21', '无码专区'),
    ('25', '制服诱惑'),
    ('27', '三级伦理'),
    ('29', 'AI换脸'),
    ('30', '中文字幕'),
    ('32', '卡通动漫'),
    ('35', '欧美系列'),
    ('36', '美女主播'),
    ('38', '国产自拍'),
    ('40', '熟女人妻'),
    ('42', '萝莉少女'),
    ('44', '女同性爱'),
    ('46', '多人群交'),
    ('48', '美乳巨乳'),
    ('49', '强奸乱伦'),
    ('50', '抖阴视频'),
    ('51', '韩国主播'),
    ('52', '网红头条'),
    ('53', '网爆黑料'),
    ('54', '欧美无码'),
    ('55', '女优明星'),
    ('56', 'SM调教'),
    ('57', 'AV解说'),
    ('285', '生活都市'),
    ('286', '不偷恋情'),
    ('287', '学生校园'),
    ('288', '人妻熟女'),
    ('289', '暴力虐待'),
    ('290', '明星偶像'),
    ('291', '玄幻仙侠'),
    ('292', '科学幻想'),
    ('293', '街拍偷拍'),
    ('294', '丝袜美腿'),
    ('295', '欧美风情'),
    ('296', '网友自拍'),
    ('297', '卡通漫画'),
    ('298', '露出激情'),
    ('299', '唯美写真'),
    ('300', '女优情报'),
]

CAT_RE = re.compile(r'href="/type/id/(\d+)\.html"[^>]*>([^<]+)<')
CARD_RE = re.compile(r'<a[^>]*href="/info/id/(\d+)\.html"[^>]*class="video-unit"[^>]*>.*?<img[^>]*src="([^"]+)"[^>]*>.*?<div class="video-unit__caption">\s*(.*?)\s*</div>', re.S)
PLAY_RE = re.compile(r"var playUrl\s*=\s*'([^']+)'")
LD_RE = re.compile(r'"contentUrl":\s*"([^"]+)"')
H2_RE = re.compile(r'<h2 id="pagetitle">(.*?)</h2>', re.S)
COVER_RE = re.compile(r'<a href="/play/id/\d+\.html"[^>]*><img[^>]*src="([^"]+)"', re.S)
GENRE_RE = re.compile(r'aria-current="page"[^>]*href="/type/id/\d+\.html"[^>]*>([^<]+)<')
DESC_RE = re.compile(r'<meta name="description"[^>]*content="([^"]+)"')


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _unescape(s):
    if not s:
        return ''
    return _html.unescape(s).replace('&nbsp;', ' ').strip()


def _http_get(url, referer=None, timeout=30):
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
        time.sleep(2)
    return ''


def _parse_categories(html):
    out = []
    seen = set()
    for m in CAT_RE.finditer(html or ''):
        cid = m.group(1)
        name = m.group(2).strip()
        if not name or cid in seen:
            continue
        seen.add(cid)
        out.append((cid, name))
    return out


def _parse_cards(html):
    out = []
    seen = set()
    for m in CARD_RE.finditer(html or ''):
        vid = m.group(1)
        if vid in seen:
            continue
        seen.add(vid)
        title = _unescape(m.group(3))
        if not title:
            continue
        out.append({
            'vod_id': vid,
            'vod_name': title,
            'vod_pic': m.group(2).strip(),
            'vod_remarks': '',
        })
    return out


def _parse_play_url(html):
    m = PLAY_RE.search(html or '')
    if m:
        return m.group(1).strip()
    m = LD_RE.search(html or '')
    if m:
        return m.group(1).strip()
    return ''


def _detail_id(sid):
    s = (sid or '').strip().lstrip('/')
    if s.startswith('info/id/'):
        s = s[len('info/id/'):]
    if s.endswith('.html'):
        s = s[:-5]
    return s.rstrip('/')


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
        return 'H-短剧'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cats(self):
        cats = _parse_categories(_http_get(BASE, referer=BASE + '/'))
        return cats or list(CATS)

    def _catalog(self, tid, pg):
        if pg <= 1:
            url = '%s/type/id/%s.html' % (BASE, tid)
        else:
            url = '%s/type/id/%s/%s.html' % (BASE, tid, pg)
        return _parse_cards(_http_get(url, referer=BASE + '/'))

    def homeContent(self, filter=''):
        cats = self._cats()
        items = []
        if cats:
            items = self._catalog(cats[0][0], 1)
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in cats],
            'list': items,
        }

    def homeVideoContent(self):
        cats = self._cats()
        items = []
        if cats:
            items = self._catalog(cats[0][0], 1)
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        items = self._catalog(tid, pg)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        nid = _detail_id(_norm_id(ids))
        if not nid:
            return {'list': []}
        html = _http_get('%s/info/id/%s.html' % (BASE, nid), referer=BASE + '/')
        if not html:
            return {'list': []}
        hm = H2_RE.search(html)
        title = _unescape(hm.group(1)) if hm else ''
        if not title:
            return {'list': []}
        cm = COVER_RE.search(html)
        cover = cm.group(1).strip() if cm else ''
        gm = GENRE_RE.search(html)
        genre = _unescape(gm.group(1)) if gm else ''
        dm = DESC_RE.search(html)
        synopsis = _unescape(dm.group(1)) if dm else ''
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': '',
            'vod_year': '',
            'vod_area': '',
            'vod_content': synopsis,
            'type_name': genre,
            'vod_tag': genre,
            'vod_play_from': '在线播放',
            'vod_play_url': '播放$hduanju:%s' % nid,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        q = urllib.parse.quote(key or '')
        url = '%s/lookup/%s.html' % (BASE, q)
        items = _parse_cards(_http_get(url, referer=BASE + '/'))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        if '$' in raw:
            raw = raw.split('$', 1)[1].strip()
        if raw.startswith('hduanju:'):
            raw = raw[len('hduanju:'):]
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        m3u8 = ''
        if raw.endswith('.m3u8') or raw.endswith('.mp4'):
            m3u8 = raw
        else:
            if raw.startswith('http'):
                url = raw
            else:
                url = '%s/play/id/%s.html' % (BASE, _detail_id(raw))
            html = _http_get(url, referer=BASE + '/')
            if html:
                m3u8 = _parse_play_url(html)
        return {'parse': 0, 'playUrl': m3u8, 'url': m3u8, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', '']

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
