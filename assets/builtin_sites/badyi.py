import gzip
import html as _html
import json
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

try:
    import requests as _requests
except Exception:
    _requests = None

BASE = 'https://badyi.cc'
UA = 'Mozilla/5.0 (Linux; Android 14; HarmonyOS; HUAWEI) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36'

CATS = [
    ('c11', '后入'),
    ('c8', '玩偶姐姐'),
    ('c19', '蝴蝶逼'),
    ('c58', '蜜桃影像传媒'),
    ('c41', '主播'),
    ('c7', '饼干姐姐'),
    ('c66', '学妹'),
    ('c47', '精东影业'),
    ('c65', '姐弟'),
    ('c97', '情趣装扮'),
    ('c36', '巨屌'),
    ('c340', '媚黑'),
    ('c379', '熊'),
    ('c424', '职场'),
    ('c488', 'G综艺'),
    ('c296', '抓奸'),
    ('c86', '重口味'),
    ('c286', '亚洲'),
    ('c373', '圣诞'),
    ('c504', '咩咩'),
    ('c108', '波多野結衣'),
    ('c270', '调情'),
    ('c431', '茄子视频'),
    ('c307', '窥视'),
    ('c530', '篠田優'),
    ('c226', '摄像头破解'),
    ('c294', '饼干姐姐'),
    ('c78', '淫叫'),
    ('c142', '少妇'),
    ('c555', '拳交'),
    ('c485', '有码'),
    ('c354', '大黑屌'),
    ('c159', '人妻巨乳'),
    ('c187', '偷情'),
    ('c436', '厕拍'),
    ('c238', '抄底'),
    ('c369', '浅网'),
    ('c156', '小敏儿'),
    ('c277', '校服'),
    ('c137', '传媒'),
    ('c457', 'Chloe'),
    ('c491', '医生'),
    ('c385', '女上'),
    ('c126', '原创'),
    ('c99', '母子'),
    ('c109', '高潮'),
    ('c537', 'gay'),
    ('c565', '台湾粉红兔'),
    ('c391', '寝取'),
    ('c434', '深网'),
    ('c160', '日本'),
    ('c241', '多人轮奸'),
    ('c201', '阿朱'),
    ('c272', '潮喷'),
    ('c461', '猥亵'),
    ('c89', 'NicoLove'),
    ('c515', '留学生'),
    ('c446', '爸气十足'),
]
CAT_IDS = set(t for t, _ in CATS)

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

TIMEOUT = 30


def _now():
    return time.time()


def _clean(t):
    if not t:
        return ''
    t = re.sub(r'<[^>]+>', ' ', t)
    return _html.unescape(re.sub(r'\s+', ' ', t)).strip()


def _fix_url(raw):
    u = (raw or '').strip()
    if not u:
        return ''
    u = _html.unescape(u)
    if u.startswith('https://') or u.startswith('http://'):
        return u
    if u.startswith('https:/') or u.startswith('http:/'):
        return re.sub(r'^(https?:)/(?!/)', r'\1//', u)
    if u.startswith('//'):
        return 'https:' + u
    if u.startswith('/'):
        return BASE + u
    return u


def _http_get(url, referer=None, timeout=TIMEOUT):
    hdr = {
        'User-Agent': UA,
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9',
        'Accept-Encoding': 'gzip, deflate',
        'Connection': 'keep-alive',
    }
    if referer:
        hdr['Referer'] = referer
    for attempt in range(3):
        text = None
        if _requests is not None:
            try:
                resp = _requests.get(url, headers=hdr, timeout=timeout)
                if resp.status_code == 200:
                    text = resp.content.decode('utf-8', 'replace')
            except Exception:
                text = None
        if text is None:
            try:
                req = urllib.request.Request(url, headers=hdr)
                with urllib.request.urlopen(req, timeout=timeout, context=CTX) as resp:
                    if resp.status == 200:
                        data = resp.read()
                        enc = (resp.headers.get('Content-Encoding') or '').lower()
                        if enc == 'gzip' or data[:2] == b'\x1f\x8b':
                            try:
                                data = gzip.decompress(data)
                            except Exception:
                                pass
                        text = data.decode('utf-8', 'replace')
            except Exception:
                text = None
        if text is not None:
            return text
        if attempt < 2:
            try:
                time.sleep(1)
            except Exception:
                pass
    return None


def _fetch(path, referer=None):
    if path.startswith('http'):
        return _http_get(path, referer=referer or (BASE + '/'))
    return _http_get(BASE + path, referer=referer or (BASE + '/'))


_CARD_RE = re.compile(r'<a[^>]*href="/video/(\d+)"[^>]*>(.*?)</a>', re.S)
_LABEL_RE = re.compile(r'nav-card-cat">([^<]+)<')
_ALT_RE = re.compile(r'alt="([^"]+)"')
_META_IMG_RE = re.compile(r'itemprop="image"[^>]*content="([^"]+)"')
_IMG_RE = re.compile(r'<img[^>]*src="([^"]+)"')
_DATE_RE = re.compile(r'nav-card-date">([^<]+)<')
_TITLE_RE = re.compile(r'<title[^>]*>(.*?)</title>', re.S)
_OG_IMG_RE = re.compile(r'<meta property="og:image"[^>]*content="([^"]+)"')
_DESC_RE = re.compile(r'<meta name="description"[^>]*content="([^"]+)"')
_OG_VIDEO_RE = re.compile(r'<meta property="og:video"[^>]*content="([^"]+)"')
_CONTENT_URL_RE = re.compile(r'"contentUrl":"([^"]+?\.m3u8[^"]*)"')
_PAGE_TOTAL_RE = re.compile(r'nav-pg-info">\d+ / (\d+)<')
_CAT_RE = re.compile(r'href="/c(\d+)"[^>]*>([^<]+)<')


def _parse_cards(html):
    out = []
    if not html:
        return out
    seen = set()
    for m in _CARD_RE.finditer(html):
        vid = '/video/' + m.group(1)
        if vid in seen:
            continue
        seen.add(vid)
        body = m.group(2)
        title = ''
        am = _ALT_RE.search(body)
        if am:
            title = _clean(am.group(1))
        if not title:
            continue
        pic = ''
        im = _META_IMG_RE.search(body)
        if im:
            pic = _fix_url(im.group(1))
        if not pic:
            pm = _IMG_RE.search(body)
            if pm:
                pic = _fix_url(pm.group(1))
        remark = ''
        dm = _DATE_RE.search(body)
        if dm:
            remark = _clean(dm.group(1))
        out.append({
            'vod_id': vid,
            'vod_name': title,
            'vod_pic': pic,
            'vod_remarks': remark,
        })
    return out


def _norm_id(ids):
    if isinstance(ids, (list, tuple)):
        return str(ids[0]) if ids else ''
    return str(ids)


def _norm_pg(pg):
    try:
        return int(pg)
    except Exception:
        try:
            return int(str(pg).strip())
        except Exception:
            return 1


def _empty_detail(vod_id):
    return {'list': [{
        'vod_id': vod_id,
        'vod_name': '',
        'vod_pic': '',
        'vod_actor': '',
        'vod_director': '',
        'vod_remarks': '',
        'vod_year': '',
        'vod_area': '',
        'vod_content': '',
        'type_name': '',
        'vod_tag': '',
        'vod_play_from': '在线播放',
        'vod_play_url': '',
        'stills': [],
    }]}


class Spider(BaseSpider):

    def getName(self):
        return '八度影院'

    def getDependence(self):
        return []

    def init(self, extend=None):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=False):
        cats = [{'type_id': cid, 'type_name': name} for cid, name in CATS]
        return {'class': cats, 'filters': {}}

    def homeVideoContent(self):
        html = _fetch('/')
        items = _parse_cards(html)
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        tid = _norm_id(tid).strip()
        pg = _norm_pg(pg)
        if pg < 1:
            pg = 1
        if tid not in CAT_IDS:
            tid = 'c11'
        if pg <= 1:
            path = '/%s/' % tid
        else:
            path = '/%s/page/%d/' % (tid, pg)
        html = _fetch(path)
        items = _parse_cards(html)
        pagecount = 0
        if html:
            tm = _PAGE_TOTAL_RE.search(html)
            if tm:
                try:
                    pagecount = int(tm.group(1))
                except Exception:
                    pagecount = 0
        return {'list': items, 'page': pg, 'pagecount': pagecount, 'total': 0}

    def detailContent(self, ids):
        path = _norm_id(ids).strip()
        if not path:
            return _empty_detail(path)
        html = _fetch(path)
        if not html:
            return _empty_detail(path)
        title = ''
        tm = _TITLE_RE.search(html)
        if tm:
            title = _clean(tm.group(1)).split(' - ')[0]
        pic = ''
        pm = _OG_IMG_RE.search(html)
        if pm:
            pic = _fix_url(pm.group(1))
        content = ''
        dm = _DESC_RE.search(html)
        if dm:
            content = _clean(dm.group(1)).replace(' -91Pornhub.tv', '').strip()
        if not title:
            return _empty_detail(path)
        return {'list': [{
            'vod_id': path,
            'vod_name': title,
            'vod_pic': pic,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': '',
            'vod_year': '',
            'vod_area': '',
            'vod_content': content,
            'type_name': '',
            'vod_tag': '',
            'vod_play_from': '在线播放',
            'vod_play_url': '播放$%s' % path,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        if pg < 1:
            pg = 1
        kw = urllib.parse.quote(str(key).strip())
        text = _fetch('/api/search.php?q=%s&page=%d&per=12' % (kw, pg))
        items = []
        pagecount = pg
        total = 0
        if text:
            try:
                data = json.loads(text)
            except Exception:
                data = None
            if isinstance(data, dict):
                for a in data.get('articles') or []:
                    vid = a.get('url') or ''
                    if not vid.startswith('/video/'):
                        continue
                    title = _clean(str(a.get('title') or ''))
                    if not title:
                        continue
                    items.append({
                        'vod_id': vid,
                        'vod_name': title,
                        'vod_pic': _fix_url(str(a.get('img') or '')),
                        'vod_remarks': _clean(str(a.get('date') or '')),
                    })
                try:
                    pagecount = int(data.get('pages') or pg)
                except Exception:
                    pagecount = pg
                try:
                    total = int(data.get('total') or 0)
                except Exception:
                    total = 0
        seen = set()
        dedup = []
        for it in items:
            if it['vod_id'] in seen:
                continue
            seen.add(it['vod_id'])
            dedup.append(it)
        return {'list': dedup, 'page': pg, 'pagecount': pagecount, 'total': total}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        if not raw:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        if raw.startswith('http') and '.m3u8' in raw:
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        html = _fetch(raw, referer=BASE + '/')
        m3u8 = ''
        if html:
            m = _OG_VIDEO_RE.search(html)
            if m:
                m3u8 = _fix_url(m.group(1))
            if not m3u8:
                m = _CONTENT_URL_RE.search(html)
                if m:
                    m3u8 = _fix_url(m.group(1))
        if not m3u8:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        return {'parse': 0, 'playUrl': m3u8, 'url': m3u8, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', b'', {}]

    def isVideoFormat(self, url):
        u = str(url or '').lower().split('?')[0]
        return u.endswith(('.m3u8', '.mp4', '.mkv', '.webm', '.flv', '.ts'))

    def manualVideoCheck(self):
        return True

    def action(self, action, params=None):
        return {'code': 0, 'msg': 'ok'}
