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


BASE = 'https://www.shaofudj.top/aa'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

CATS = [
    ('1', '玉兔资源'),
    ('10', '网曝系列'),
    ('43', '番茄资源'),
    ('61', '杏吧资源'),
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


def _unescape(s):
    if not s:
        return ''
    s = _html.unescape(s)
    s = s.replace('\\/', '/')
    def _sub(m):
        try:
            return chr(int(m.group(1), 16))
        except Exception:
            return m.group(0)
    s = re.sub(r'\\u([0-9a-fA-F]{4})', _sub, s)
    return s


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
    for block in (html or '').split('<li>'):
        m = re.search(r'vod/play/id/(\d+)/sid/1/nid/1\.html', block)
        if not m:
            continue
        vid = m.group(1)
        if vid in seen:
            continue
        seen.add(vid)
        cm = re.search(r'data-original="([^"]+)"', block)
        cover = _unescape(cm.group(1).strip()) if cm else ''
        tm = re.search(r'<h3 class="video-title">.*?<text>([^<]+)</text>', block, re.S)
        title = _unescape(tm.group(1).strip()) if tm else ''
        if not title:
            continue
        out.append({'vod_id': vid, 'vod_name': title, 'vod_pic': cover, 'vod_remarks': ''})
    return out


def _play_url(vid):
    url = '%s/index.php/vod/play/id/%s/sid/1/nid/1.html' % (BASE, vid)
    html = _http_get(url, referer=BASE + '/')
    if not html:
        return '', '', ''
    m = re.search(r'player_aaaa=\{.*?"url":"([^"]+)"', html, re.S)
    u = _unescape(m.group(1)) if m else ''
    nm = re.search(r'vod_name":"((?:[^"\\]|\\.)*)"', html)
    name = _unescape(nm.group(1)) if nm else ''
    cm = re.search(r'vod_class":"((?:[^"\\]|\\.)*)"', html)
    cls = _unescape(cm.group(1)) if cm else ''
    if not name:
        tm = re.search(r'<title>(.*?)</title>', html, re.S)
        if tm:
            name = _unescape(tm.group(1).strip()).split('在线播放')[0].strip()
    return u, name, cls


class Spider(BaseSpider):
    def getName(self):
        return '少妇·短剧AV'

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
        if pg <= 1:
            url = '%s/index.php/vod/type/id/%s.html' % (BASE, tid)
        else:
            url = '%s/index.php/vod/type/id/%s/page/%s.html' % (BASE, tid, pg)
        html = _http_get(url, referer=BASE + '/')
        items = _cards(html)
        total = 0
        tm = re.search(r'找到\s*(\d+)\s*条', html or '')
        if tm:
            try:
                total = int(tm.group(1))
            except Exception:
                total = 0
        if total > 0:
            has_more = pg * len(items) < total
        else:
            has_more = len(items) >= 20
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': total}

    def detailContent(self, ids):
        vid = _norm_id(ids)
        if not vid:
            return {'list': []}
        m3u8, title, cls = _play_url(vid)
        if not title or not m3u8:
            return {'list': []}
        eps = '播放$%s|%s' % (vid, m3u8)
        parts = []
        if cls:
            parts.append('分类：' + cls)
        return {'list': [{
            'vod_id': vid,
            'vod_name': title,
            'vod_pic': '',
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': '',
            'vod_year': '',
            'vod_area': '',
            'vod_content': '\n'.join(parts),
            'type_name': cls,
            'vod_tag': cls,
            'vod_play_from': '在线播放',
            'vod_play_url': eps,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        url = '%s/index.php/vod/search.html?wd=%s' % (BASE, urllib.parse.quote(str(key or '')))
        html = _http_get(url, referer=BASE + '/')
        items = _cards(html)
        return {'list': items, 'page': _norm_pg(pg), 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        vid = ''
        url = raw
        if '|' in raw:
            vid, url = raw.split('|', 1)
        header = {'User-Agent': UA}
        if vid:
            header['Referer'] = '%s/index.php/vod/play/id/%s/sid/1/nid/1.html' % (BASE, vid)
        else:
            header['Referer'] = BASE + '/'
        if url.startswith('http') and '.m3u8' in url:
            return {'parse': 0, 'playUrl': url, 'url': url, 'header': header}
        m = re.search(r'(\d+)', raw)
        if m:
            m3u8, _, _ = _play_url(m.group(1))
            if m3u8:
                header['Referer'] = '%s/index.php/vod/play/id/%s/sid/1/nid/1.html' % (BASE, m.group(1))
                return {'parse': 0, 'playUrl': m3u8, 'url': m3u8, 'header': header}
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
