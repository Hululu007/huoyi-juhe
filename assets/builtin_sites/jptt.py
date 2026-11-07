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

BASE = 'https://jptt.tv'
UA = 'Mozilla/5.0 (Linux; Android 14; HarmonyOS; HUAWEI) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36'

CATS = [
    ('t7', '720p', 'tid', '7'),
    ('t15', '巨乳', 'tid', '15'),
    ('t3', 'AV女優片', 'tid', '3'),
    ('t2', '中出', 'tid', '2'),
    ('t21', 'HD', 'tid', '21'),
    ('t471', 'HD高畫質', 'tid', '471'),
    ('t9', '素人', 'tid', '9'),
    ('t278', '中文', 'tid', '278'),
    ('t16', '人妻', 'tid', '16'),
    ('t212', '無碼片', 'tid', '212'),
    ('t95', '熟女', 'tid', '95'),
    ('t34', '口交', 'tid', '34'),
    ('f93', '瑪丹娜', 'fid', '93'),
    ('f1', 'SOD', 'fid', '1'),
    ('f31', 'MOODYZ', 'fid', '31'),
    ('f1203', 'FC2高清版', 'fid', '1203'),
    ('f2', 'HMN WORKS', 'fid', '2'),
]

_CATMAP = {cid: (kind, arg) for cid, _, kind, arg in CATS}


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _http_get(url, referer=None, timeout=35):
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
            except Exception:
                pass
        except Exception:
            pass
        time.sleep(2)
    return ''


def _clean(t):
    if not t:
        return ''
    t = re.sub(r'<[^>]+>', ' ', t)
    return _html.unescape(re.sub(r'\s+', ' ', t)).strip()


def _unescape(s):
    return _html.unescape((s or '').replace('&nbsp;', ' ')).strip()


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
    link_re = re.compile(r'<a href="https?://jptt\.tv/video/([^"]+)">')
    img_re = re.compile(r'<img[^>]*src="([^"]+)"[^>]*alt="([^"]*)"')
    img_re2 = re.compile(r'<img[^>]*alt="([^"]*)"[^>]*src="([^"]+)"')
    dur_re = re.compile(r'p_duration">([^<]+)<')
    h_re = re.compile(r'(?s)<h[35][^>]*>(.*?)</h[35]>')
    for cap in link_re.finditer(html or ''):
        code = cap.group(1).strip()
        if not code or code in seen:
            continue
        start = cap.end()
        body = html[start:start + 1500]
        title = ''
        cover = ''
        m = img_re.search(body)
        if m:
            cover = _fix_url(m.group(1))
            title = _unescape(m.group(2).strip())
        if not cover:
            m = img_re2.search(body)
            if m:
                title = _unescape(m.group(1).strip())
                cover = _fix_url(m.group(2))
        if not title:
            m = h_re.search(body)
            if m:
                title = _unescape(_clean(m.group(1)))
        if not title:
            continue
        m = dur_re.search(body)
        remark = m.group(1).strip() if m else ''
        seen.add(code)
        vid = '/video/' + code
        out.append({'vod_id': vid, 'vod_name': title, 'vod_pic': cover, 'vod_remarks': remark})
    return out


class Spider(BaseSpider):
    def getName(self):
        return 'JPTT禁片天堂'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _catalog(self, tid):
        kind, arg = _CATMAP.get(tid, ('tid', '15'))
        url = '%s/tag_list?%s=%s' % (BASE, kind, arg)
        return _cards(_http_get(url, referer=BASE + '/'))

    def homeContent(self, filter=''):
        cats = [(cid, name) for cid, name, _, _ in CATS]
        items = self._catalog(cats[0][0]) if cats else []
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in cats],
            'list': items,
        }

    def homeVideoContent(self):
        cats = [(cid, name) for cid, name, _, _ in CATS]
        items = self._catalog(cats[0][0]) if cats else []
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        items = self._catalog(_norm_id(tid))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        if nid.startswith('http'):
            url = nid
        elif nid.startswith('/'):
            url = BASE + nid
        else:
            url = BASE + '/' + nid
        html = _http_get(url, referer=BASE + '/')
        if not html:
            return {'list': []}
        m = re.search(r'(?s)<h1[^>]*>(.*?)</h1>', html)
        title = _unescape(_clean(m.group(1))) if m else ''
        if not title:
            m = re.search(r'<meta property="og:title"[^>]*content="([^"]+)"', html)
            title = _unescape(m.group(1).strip()) if m else ''
        m = re.search(r'<meta property="og:image"[^>]*content="([^"]+)"', html)
        cover = _fix_url(m.group(1)) if m else ''
        m = re.search(r'<meta name="description"[^>]*content="([^"]+)"', html)
        synopsis = _unescape(m.group(1).strip()) if m else ''
        m = re.search(r'<source[^>]*data-src="([^"]+\.m3u8[^"]*)"', html)
        m3u8 = _fix_url(m.group(1)) if m else ''
        if not title or not m3u8:
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
            'vod_play_url': '播放$%s' % m3u8,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        url = '%s/search?kw=%s' % (BASE, urllib.parse.quote(str(key or '')))
        html = _http_get(url, referer=BASE + '/')
        return {'list': _cards(html), 'page': _norm_pg(pg), 'pagecount': 0, 'total': 0}

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
