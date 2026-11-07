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


BASES = ['https://taosevfqz.lol', 'https://taosevilo.buzz']
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
_BASE_CACHE = {'base': '', 'ts': 0}

CATS = [
    ('295', '无码热门'),
    ('297', '制服乱伦'),
    ('298', '三级性交'),
    ('299', '换脸淫梦'),
    ('300', '中文精选'),
    ('301', '卡通动漫'),
    ('302', '欧美系列'),
    ('303', '美女主播'),
    ('304', '国产自拍'),
    ('305', '熟女有码'),
    ('306', '萝莉群交'),
    ('307', '女同性爱'),
    ('308', '多人群交'),
    ('309', '美乳巨乳'),
    ('310', '强奸调教'),
    ('311', '抖阴视频'),
    ('312', '韩国主播'),
    ('313', '网红头条'),
    ('314', '网爆黑料'),
    ('315', '欧美无码'),
    ('316', '女优明星'),
    ('317', 'SM调教'),
    ('326', 'AV在线'),
    ('702', '国产自拍'),
    ('703', '主播诱惑'),
    ('704', '探花约炮'),
    ('705', '偷拍偷窥'),
    ('706', '网曝吃瓜'),
    ('707', '抖阴短片'),
    ('708', '传媒剧情'),
    ('709', '日韩主播'),
    ('710', '日韩无码'),
    ('711', '中文字幕'),
    ('712', 'AV解说'),
    ('713', '换脸明星'),
    ('714', '强奸乱伦'),
    ('715', '女优明星'),
    ('716', '欧美激情'),
    ('717', '重口激情'),
    ('718', '三级伦理'),
    ('719', '剧情动漫'),
    ('720', 'SM调教'),
    ('721', '女同性恋'),
    ('722', 'VR视角'),
]


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _resolve_base():
    now = time.time()
    if _BASE_CACHE['base'] and now - _BASE_CACHE['ts'] < 3600:
        return _BASE_CACHE['base']
    for base in BASES:
        ok = False
        if _HAS_REQ:
            try:
                r = requests.get(base, headers={'User-Agent': UA}, timeout=15)
                ok = r.status_code == 200
            except Exception:
                ok = False
        else:
            try:
                req = urllib.request.Request(base, headers={'User-Agent': UA})
                with urllib.request.urlopen(req, timeout=15, context=_ctx()) as resp:
                    ok = resp.status == 200
            except Exception:
                ok = False
        if ok:
            _BASE_CACHE['base'] = base
            _BASE_CACHE['ts'] = now
            return base
    _BASE_CACHE['base'] = BASES[0]
    _BASE_CACHE['ts'] = now
    return BASES[0]


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


def _unescape(s):
    if not s:
        return ''
    return _html.unescape(s).replace('\\/', '/')


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


def _encode_path(s):
    out = []
    for b in (s or '').encode('utf-8'):
        ch = chr(b)
        if ch.isalnum() or ch in '-_.~':
            out.append(ch)
        else:
            out.append('%%%02X' % b)
    return ''.join(out)


def _live_cats(html):
    out = []
    seen = set()
    pat = re.compile(r'<a[^>]*href="/type/id/(\d+)\.html"[^>]*>(.*?)</a>', re.S)
    for m in pat.finditer(html or ''):
        cid = m.group(1)
        name = re.sub(r'<[^>]+>', '', m.group(2)).strip()
        if not name or cid in seen:
            continue
        seen.add(cid)
        out.append((cid, name))
    return out


def _cards(html):
    out = []
    seen = set()
    pat = re.compile(r'<a href="/info/id/(\d+)\.html"[^>]*title="([^"]+)"[^>]*>.*?<img[^>]*src="([^"]+)"', re.S)
    for m in pat.finditer(html or ''):
        vid = m.group(1)
        if vid in seen:
            continue
        seen.add(vid)
        title = _unescape(m.group(2).strip())
        if not title:
            continue
        out.append({'vod_id': vid, 'vod_name': title, 'vod_pic': _unescape(m.group(3).strip()), 'vod_remarks': ''})
    return out


class Spider(BaseSpider):
    def getName(self):
        return 'AI成人短剧1'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cats(self):
        base = _resolve_base()
        html = _http_get(base)
        live = _live_cats(html) if html else []
        return live or list(CATS)

    def homeContent(self, filter=''):
        cats = self._cats()
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
            items = self.categoryContent(self._cats()[0][0], 1).get('list') or []
        except Exception:
            items = []
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        base = _resolve_base()
        if pg <= 1:
            url = '%s/type/id/%s.html' % (base, tid)
        else:
            url = '%s/type/id/%s/%s.html' % (base, tid, pg)
        html = _http_get(url, referer=base + '/')
        items = _cards(html)
        nxt = '/type/id/%s/%s.html' % (tid, pg + 1)
        has_more = bool(items) and nxt in (html or '')
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        vid = _norm_id(ids)
        if not vid:
            return {'list': []}
        base = _resolve_base()
        html = _http_get('%s/info/id/%s.html' % (base, vid), referer=base + '/')
        if not html:
            return {'list': []}
        title = ''
        for m in re.finditer(r'<h1[^>]*>(.*?)</h1>', html, re.S):
            t = re.sub(r'<[^>]+>', '', m.group(1)).strip()
            if t and t != 'AI成人短剧':
                title = _unescape(t)
        cover = ''
        cm = re.search(r'<img class="video-img[^"]*"[^>]*src="([^"]+)"', html)
        if cm:
            cover = _unescape(cm.group(1).strip())
        synopsis = ''
        dm = re.search(r'<meta name="description"[^>]*content="([^"]+)"', html)
        if dm:
            synopsis = _unescape(dm.group(1).strip())
        play_html = _http_get('%s/play/id/%s.html' % (base, vid), referer='%s/info/id/%s.html' % (base, vid))
        m3u8 = ''
        pm = re.search(r'(https?://[^"\'\s]+\.m3u8[^"\'\s]*)', play_html or '')
        if pm:
            m3u8 = _unescape(pm.group(1).strip())
        if not title or not m3u8:
            return {'list': []}
        return {'list': [{
            'vod_id': vid,
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
            'vod_play_url': '播放$%s' % m3u8,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        base = _resolve_base()
        url = '%s/lookup/%s.html' % (base, _encode_path(str(key or '').strip()))
        html = _http_get(url, referer=base + '/')
        items = _cards(html)
        return {'list': items, 'page': _norm_pg(pg), 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        header = {'User-Agent': UA, 'Referer': _resolve_base() + '/'}
        if raw.startswith('http'):
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', b'', {}]

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
