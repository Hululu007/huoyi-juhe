import gzip
import html as _html
import re
import ssl
import time
import urllib.parse
import urllib.request

try:
    from base.spider import BaseSpider
except Exception:
    try:
        from base import BaseSpider
    except Exception:
        class BaseSpider:
            pass

BASE = 'https://gczwfrusk.forum'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

CATS = [
    ('7', '中文字幕'),
    ('8', '国产传媒'),
    ('9', '日本有码'),
    ('10', '日本无码'),
    ('11', '欧美无码'),
    ('12', '强奸乱伦'),
    ('13', '制服诱惑'),
    ('14', '国产主播'),
    ('15', '激情动漫'),
    ('16', '明星换脸'),
    ('17', '抖阴视频'),
    ('18', '女优明星'),
    ('22', '网曝黑料'),
    ('26', '伦理三级'),
    ('28', 'AV解说'),
    ('31', 'SM调教'),
    ('33', '萝莉少女'),
    ('34', '极品媚黑'),
    ('37', '女同性恋'),
    ('39', '网红头条'),
    ('43', '人妖系列'),
    ('45', '韩国主播'),
    ('47', 'VR视角'),
    ('59', '国产色情'),
    ('60', '主播直播'),
    ('61', '亚洲无码'),
    ('62', '亚洲有码'),
    ('63', '国产中文'),
    ('64', '美乳汁水'),
    ('65', '熟女自慰'),
    ('66', '人兽乱伦'),
    ('67', '欧美精品'),
    ('68', '萝莉岛'),
    ('69', '伦理三级'),
    ('70', '成人动漫'),
    ('71', '手机偷拍'),
    ('72', '制服丝袜'),
    ('73', '口交颜射'),
    ('74', '日本精品'),
    ('75', 'Cosplay'),
    ('76', '素人自拍'),
    ('77', '台湾辣妹'),
    ('78', '韩国御姐'),
    ('79', '唯美港姐'),
    ('80', '东南亚AV'),
    ('81', '欺辱凌辱'),
    ('82', '剧情介绍'),
    ('83', '多人多P'),
    ('84', '91探花'),
    ('85', '网红流出'),
    ('86', '野外露出'),
    ('87', '古装扮演'),
    ('88', '女优系列'),
    ('89', '可爱学生'),
    ('90', '风情旗袍'),
    ('91', '兽耳系列'),
    ('92', '瑜伽裤'),
    ('93', '闷骚护士'),
    ('94', '过膝袜'),
    ('95', '网曝门'),
    ('96', '传媒出品'),
    ('97', '女同3p'),
    ('98', '男同性恋'),
    ('99', '恋腿狂魔'),
]

try:
    import requests
    _HAS_REQ = True
except Exception:
    _HAS_REQ = False

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

CAT_RE = re.compile(r'href="/type/id/(\d+)\.html" title="([^"]+)"')
CARD_RE = re.compile(r'(?s)<a href="/display/id/(\d+)\.html"[^>]*>\s*<img[^>]*src="([^"]+)"')
TITLE_RE = re.compile(r'(?s)<h3 class="video-title">.*?<text>([^<]+)</text>')
H1_RE = re.compile(r'(?s)<h1[^>]*>.*?<text>([^<]+)</text>')
COVER_RE = re.compile(r'<img[^>]*src="([^"]*?/upload/vod/[^"]+)"')
DESC_RE = re.compile(r'<meta name="description" content="([^"]*)"')
PLAY_RE = re.compile(r"var playUrl = '([^']+)'")


def _http_get(url, referer=None, timeout=25):
    hdr = {
        'User-Agent': UA,
        'Referer': referer or (BASE + '/'),
        'Accept-Encoding': 'gzip, deflate',
    }
    if _HAS_REQ:
        try:
            r = requests.get(url, headers=hdr, timeout=timeout)
            if r.status_code == 200 and r.text and r.text.strip():
                return r.text
        except Exception:
            pass
    for attempt in range(3):
        try:
            req = urllib.request.Request(url, headers=hdr)
            with urllib.request.urlopen(req, timeout=timeout, context=CTX) as resp:
                data = resp.read()
                enc = (resp.headers.get('Content-Encoding') or '').lower()
            if enc == 'gzip' or data[:2] == b'\x1f\x8b':
                try:
                    data = gzip.decompress(data)
                except Exception:
                    pass
            text = data.decode('utf-8', 'replace')
            if text.strip():
                return text
        except Exception:
            if attempt < 2:
                time.sleep(1)
    return ''


def _unescape(s):
    if not s:
        return ''
    return _html.unescape(s).strip()


def _parse_categories(html):
    out = []
    seen = set()
    for m in CAT_RE.finditer(html or ''):
        cid = m.group(1)
        name = _unescape(m.group(2))
        if not name or cid in seen:
            continue
        seen.add(cid)
        out.append({'type_id': cid, 'type_name': name})
    return out


def _parse_cards(html):
    out = []
    seen = set()
    for m in CARD_RE.finditer(html or ''):
        vid = m.group(1)
        if vid in seen:
            continue
        cover = m.group(2).strip()
        tail = html[m.end():]
        window = tail[:3000]
        tm = TITLE_RE.search(window)
        title = _unescape(tm.group(1)) if tm else ''
        if not title:
            continue
        seen.add(vid)
        out.append({
            'vod_id': vid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_remarks': '',
        })
    return out


def _norm_id(ids):
    if isinstance(ids, (list, tuple)):
        return str(ids[0]) if ids else ''
    return str(ids or '')


def _norm_pg(pg):
    try:
        pg = int(pg)
    except Exception:
        pg = 1
    return pg if pg >= 1 else 1


class Spider(BaseSpider):

    def getName(self):
        return '中文短剧网'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=''):
        html = _http_get(BASE + '/type/id/7.html', referer=BASE + '/')
        cats = _parse_categories(html)
        if not cats:
            cats = [{'type_id': tid, 'type_name': name} for tid, name in CATS]
        items = []
        if cats:
            items = self._catalog(cats[0]['type_id'], 1)
        return {'class': cats, 'filters': {}, 'list': items}

    def homeVideoContent(self):
        items = self._catalog(CATS[0][0], 1)
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def _catalog(self, tid, pg):
        if pg <= 1:
            url = '%s/type/id/%s.html' % (BASE, tid)
        else:
            url = '%s/type/id/%s/%d.html' % (BASE, tid, pg)
        html = _http_get(url, referer=BASE + '/')
        return _parse_cards(html)

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        items = self._catalog(_norm_id(tid), pg)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        nid = _norm_id(ids).strip()
        if nid.startswith('/display/id/'):
            nid = nid[len('/display/id/'):]
        nid = nid.rstrip('/').rstrip('.html') if nid.endswith('.html') else nid.rstrip('/')
        if nid.endswith('.html'):
            nid = nid[:-5]
        if not nid:
            return {'list': []}
        html = _http_get('%s/display/id/%s.html' % (BASE, nid), referer=BASE + '/')
        if not html:
            return {'list': []}
        m = H1_RE.search(html)
        title = _unescape(m.group(1)) if m else ''
        if title.endswith('详情页'):
            title = title[:-3]
        m = COVER_RE.search(html)
        cover = m.group(1) if m else ''
        m = DESC_RE.search(html)
        synopsis = _unescape(m.group(1)) if m else ''
        if not title:
            return {'list': []}
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
            'type_name': '',
            'vod_tag': '',
            'vod_play_from': '在线播放',
            'vod_play_url': '播放$' + nid,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        enc = urllib.parse.quote(str(key or '').strip())
        url = '%s/search/%s.html' % (BASE, enc)
        html = _http_get(url, referer=BASE + '/')
        items = _parse_cards(html)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        header = {'User-Agent': UA}
        if raw.startswith('http'):
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        vid = raw.strip()
        if vid.startswith('/detail/id/'):
            vid = vid[len('/detail/id/'):]
        if vid.endswith('.html'):
            vid = vid[:-5]
        vid = vid.rstrip('/')
        if not vid:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        html = _http_get('%s/detail/id/%s.html' % (BASE, vid), referer=BASE + '/')
        m = PLAY_RE.search(html)
        stream = m.group(1).strip() if m else ''
        if not stream:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        return {'parse': 0, 'playUrl': stream, 'url': stream, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', b'', {}]

    def isVideoFormat(self, url):
        u = (url or '').lower()
        return u.endswith('.m3u8') or u.endswith('.mp4') or '.m3u8?' in u or '.mp4?' in u

    def manualVideoCheck(self):
        return False

    def action(self, action, params=None):
        return None
