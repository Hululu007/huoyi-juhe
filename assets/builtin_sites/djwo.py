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


BASE = 'https://langwonqyl.forum'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

CATS = [
    ('223', '国产视频'),
    ('224', '精品推荐'),
    ('225', '国产色情'),
    ('226', '中文字幕'),
    ('227', '主播直播'),
    ('228', '国产传媒'),
    ('229', '亚洲无码'),
    ('230', '日本有码'),
    ('231', '亚洲有码'),
    ('232', '日本无码'),
    ('233', '中文有码'),
    ('234', '欧美无码'),
    ('235', '巨乳美乳'),
    ('236', '强奸乱伦'),
    ('237', '人妻系列'),
    ('238', '制服诱惑'),
    ('239', '强奸精品'),
    ('240', '直播主播'),
    ('241', '欧美精品'),
    ('242', '激情动漫'),
    ('243', '萝莉少女'),
    ('244', '明星换脸'),
    ('245', '伦理三级'),
    ('246', '抖阴视频'),
    ('248', '女优明星'),
    ('249', '自拍偷拍'),
    ('250', '视频一区'),
    ('251', '制服丝袜'),
    ('252', '视频二区'),
    ('253', '口交颜射'),
    ('254', '网-曝-门'),
    ('255', '日本精品'),
    ('256', '视频三区'),
    ('257', 'Cosplay'),
    ('258', '伦理三级'),
    ('259', '素人自拍'),
    ('260', 'AV解说'),
    ('261', '台湾辣妹'),
    ('262', 'SM调教'),
    ('263', '韩国御姐'),
    ('264', '萝莉少女'),
    ('265', '唯美港姐'),
    ('267', '东南亚AV'),
    ('268', '女同性恋'),
    ('269', '欺辱凌辱'),
    ('270', '玩偶姐姐'),
    ('271', '剧情介绍'),
    ('272', '视频四区'),
    ('273', '多人多P'),
    ('274', '人妖系列'),
    ('275', '91探花'),
    ('276', '网红流出'),
    ('277', '野外露出'),
    ('278', '古装扮演'),
    ('279', '女优系列'),
    ('280', '可爱学生'),
    ('281', '风情旗袍'),
    ('282', '兽耳系列'),
    ('283', '瑜伽裤'),
    ('284', '闷骚护士'),
    ('285', '过膝袜'),
    ('286', '网曝门'),
    ('287', '传媒出品'),
    ('288', '女同性恋'),
    ('289', '男同性恋'),
    ('290', '恋腿狂魔'),
    ('293', '韩国主播'),
    ('294', 'VR视角'),
]

CARD_RE = re.compile(r'<a href="/info/id/(\d+)\.html"[^>]*>\s*<img[^>]*src="([^"]+)"', re.S)
TITLE_RE = re.compile(r'<h3 class="video-title">.*?<text>([^<]+)</text>', re.S)
CAT_RE = re.compile(r'href="/type/id/(\d+)\.html"[^>]*title="([^"]+)"')
PLAY_RE = re.compile(r"var playUrl\s*=\s*'([^']+\.m3u8[^']*)'")
H1_RE = re.compile(r'<h1 class="title">.*?<text>([^<]+)</text>', re.S)
TITLE_TAG_RE = re.compile(r'<title[^>]*>(.*?)</title>', re.S)
COVER_RE = re.compile(r'<img[^>]*src="([^"]*?/upload/vod/[^"]+)"')
DESC_RE = re.compile(r'<meta name="description" content="([^"]*)"')


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
                if r.status_code == 200 and r.text.strip():
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
                txt = data.decode('utf-8', 'replace')
                if txt.strip():
                    return txt
        except urllib.error.HTTPError as e:
            try:
                return e.read().decode('utf-8', 'ignore')
            except http.client.IncompleteRead as ie:
                return ie.partial.decode('utf-8', 'ignore')
        except Exception:
            pass
        time.sleep(2)
    return ''


def _parse_cards(html):
    out = []
    seen = set()
    for m in CARD_RE.finditer(html or ''):
        vid = m.group(1)
        if vid in seen:
            continue
        seen.add(vid)
        cover = m.group(2).strip()
        tail = html[m.end():m.end() + 3000]
        tm = TITLE_RE.search(tail)
        title = _unescape(tm.group(1)) if tm else ''
        if not title:
            continue
        out.append({
            'vod_id': vid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_remarks': '',
        })
    return out


def _parse_categories(html):
    out = []
    seen = set()
    for m in CAT_RE.finditer(html or ''):
        cid = m.group(1)
        name = _unescape(m.group(2))
        if not name or cid in seen:
            continue
        seen.add(cid)
        out.append((cid, name))
    return out


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
        return '短剧窝'

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
        hm = H1_RE.search(html)
        title = _unescape(hm.group(1)) if hm else ''
        if title.endswith('详情页'):
            title = title[:-3].strip()
        if not title:
            tm = TITLE_TAG_RE.search(html)
            title = _unescape(tm.group(1)) if tm else ''
            if title.endswith('-短剧窝详情页面'):
                title = title[:-len('-短剧窝详情页面')].strip()
        if not title:
            return {'list': []}
        cm = COVER_RE.search(html)
        cover = cm.group(1) if cm else ''
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
            'type_name': '',
            'vod_tag': '',
            'vod_play_from': '在线播放',
            'vod_play_url': '立即播放$djwo:%s' % nid,
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
        if raw.startswith('djwo:'):
            raw = raw[5:]
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        stream = ''
        if raw.startswith('http'):
            stream = raw
            header['Referer'] = stream
        else:
            nid = _detail_id(raw)
            html = _http_get('%s/play/id/%s.html' % (BASE, nid), referer=BASE + '/')
            if html:
                m = PLAY_RE.search(html)
                if m:
                    stream = m.group(1).strip()
                    header['Referer'] = stream
        return {'parse': 0, 'playUrl': stream, 'url': stream, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', '']

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
