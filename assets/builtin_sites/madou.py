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
import json
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

BASE = 'https://madouai.xyz'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

CATS = [
    ('2', 'AV - 中文字幕'),
    ('1', '国产自拍（最新更新）'),
    ('8', 'AV - 无码流出'),
    ('27', '每日更新'),
    ('21', '反差母狗'),
    ('4', '探花大神'),
    ('7', '91大神'),
    ('10', '麻豆x性吧联合原创'),
    ('13', '清纯少女'),
    ('6', '麻豆原创AI'),
    ('20', '破解偷拍'),
    ('28', '世界杯专栏'),
    ('19', '黑料吃瓜'),
    ('14', '重口调教'),
    ('15', '直播大秀'),
    ('22', '白虎嫩妹'),
    ('16', '网红主播'),
    ('23', '家庭乱伦'),
    ('9', '麻豆传媒'),
    ('17', '媚黑母狗'),
    ('24', '熟女偷情'),
    ('18', '白虎少女'),
    ('25', '网黄原创'),
]


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _http_get(url, referer=None, timeout=25):
    h = {'User-Agent': UA, 'Accept': 'application/json', 'Accept-Language': 'zh-CN,zh;q=0.9', 'Accept-Encoding': 'gzip, deflate'}
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
            except Exception:
                pass
        except Exception:
            pass
        time.sleep(1)
    return ''


def _http_json(url, referer=None):
    txt = _http_get(url, referer=referer)
    if not txt:
        return {}
    try:
        return json.loads(txt)
    except Exception:
        return {}


def _clean(t):
    if not t:
        return ''
    t = re.sub(r'<[^>]+>', ' ', t)
    return _html.unescape(re.sub(r'\s+', ' ', t)).strip()


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


def _encode_component(s):
    out = []
    for b in str(s).encode('utf-8'):
        c = chr(b)
        if c.isalnum() or c in '-_.~':
            out.append(c)
        else:
            out.append('%%%02X' % b)
    return ''.join(out)


def _playable_url(video_url):
    u = (video_url or '').strip()
    if not u:
        return ''
    if u.lower().endswith('.m3u8'):
        path = u[1:] if u.startswith('/') else u
        return '%s/api/v1/m3u8/proxy?path=%s' % (BASE, _encode_component(path))
    if u.startswith('http'):
        return u
    if u.startswith('/'):
        return BASE + u
    return BASE + '/' + u


def _fix_cover(raw):
    u = (raw or '').strip()
    if not u:
        return ''
    if u.startswith('http'):
        return u
    if u.startswith('/'):
        return BASE + u
    return BASE + '/' + u


def _fmt_duration(secs):
    try:
        secs = int(secs)
    except Exception:
        return ''
    if secs <= 0:
        return ''
    return '%02d:%02d' % (secs // 60, secs % 60)


def _parse_items(data):
    out = []
    items = data.get('items') if isinstance(data, dict) else None
    if not isinstance(items, list):
        return out
    for v in items:
        if not isinstance(v, dict):
            continue
        vid = v.get('id')
        if not isinstance(vid, (int, float)):
            continue
        title = v.get('title') or ''
        if not title:
            continue
        cover = _fix_cover(v.get('coverUrl') or '')
        dur = v.get('durationSec')
        try:
            dur = int(dur)
        except Exception:
            dur = 0
        out.append({'vod_id': str(int(vid)), 'vod_name': title, 'vod_pic': cover, 'vod_remarks': _fmt_duration(dur)})
    return out


def _parse_categories(data):
    out = []
    if not isinstance(data, list):
        return out
    for v in data:
        if not isinstance(v, dict):
            continue
        if v.get('type') != 'video':
            continue
        if v.get('enabled') is False:
            continue
        vid = v.get('id')
        if not isinstance(vid, (int, float)):
            continue
        name = v.get('name') or ''
        if not name:
            continue
        out.append((str(int(vid)), name))
    return out


class Spider(BaseSpider):
    def getName(self):
        return '2048成人短剧'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cats(self):
        v = _http_json(BASE + '/api/v1/categories?type=video')
        data = v.get('data') if isinstance(v, dict) else None
        lst = _parse_categories(data)
        return lst or list(CATS)

    def _catalog(self, tid, pg):
        url = '%s/api/v1/videos?categoryId=%s&page=%d&size=20' % (BASE, urllib.parse.quote(str(tid), safe=''), pg)
        v = _http_json(url)
        data = v.get('data') if isinstance(v, dict) else None
        if not isinstance(data, dict):
            return []
        return _parse_items(data)

    def homeContent(self, filter=''):
        cats = self._cats()
        items = self._catalog(cats[0][0], 1) if cats else []
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in cats],
            'list': items,
        }

    def homeVideoContent(self):
        cats = self._cats()
        items = self._catalog(cats[0][0], 1) if cats else []
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        items = self._catalog(_norm_id(tid), pg)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        nid = _norm_id(ids).strip()
        if not nid:
            return {'list': []}
        v = _http_json('%s/api/v1/videos/%s' % (BASE, urllib.parse.quote(nid, safe='')))
        data = v.get('data') if isinstance(v, dict) else None
        if not isinstance(data, dict):
            return {'list': []}
        title = data.get('title') or ''
        cover = _fix_cover(data.get('coverUrl') or '')
        synopsis = data.get('description') or ''
        m3u8 = _playable_url(data.get('videoUrl') or '')
        if not title or not m3u8:
            return {'list': []}
        try:
            dur = int(data.get('durationSec') or 0)
        except Exception:
            dur = 0
        author = data.get('authorName') or ''
        try:
            views = int(data.get('viewCount') or 0)
        except Exception:
            views = 0
        parts = []
        if synopsis:
            parts.append(synopsis)
        if dur:
            parts.append('时长：' + _fmt_duration(dur))
        if author:
            parts.append('作者：' + author)
        if views:
            parts.append('播放：' + str(views))
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': author,
            'vod_director': '',
            'vod_remarks': _fmt_duration(dur),
            'vod_year': '',
            'vod_area': '',
            'vod_content': '\n'.join(parts),
            'type_name': '',
            'vod_tag': '',
            'vod_play_from': '在线播放',
            'vod_play_url': '播放$%s' % m3u8,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        url = '%s/api/v1/videos/search?q=%s' % (BASE, urllib.parse.quote(str(key or '').strip(), safe=''))
        v = _http_json(url)
        data = v.get('data') if isinstance(v, dict) else None
        items = _parse_items(data) if isinstance(data, dict) else []
        return {'list': items, 'page': _norm_pg(pg), 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        if raw.startswith('http'):
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', '']

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
