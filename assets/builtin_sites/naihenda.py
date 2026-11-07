try:
    from base.spider import BaseSpider
except Exception:
    try:
        from base import BaseSpider
    except Exception:
        class BaseSpider:
            pass


import datetime
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


UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
DATE_TOKENS = ['0e', 'r1', '2o', 'd3', '4a', 'x5', '6c', 'd7x', '8g', 'b9']

CATS = [
    ('25', '网曝门事件'),
    ('28', '步兵无码'),
    ('134', '起点传媒'),
]

_HOST_CACHE = {'base': '', 'ts': 0}


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _http_get(url, timeout=25):
    h = {'User-Agent': UA, 'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8', 'Accept-Language': 'zh-CN,zh;q=0.9', 'Accept-Encoding': 'gzip, deflate'}
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


def _date_part(n):
    if n >= 10:
        return DATE_TOKENS[(n // 10) % 10] + DATE_TOKENS[n % 10]
    return DATE_TOKENS[n]


def _date_code():
    now = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=3)
    return _date_part(now.month - 1) + _date_part(now.day)


def _host_candidates():
    code = _date_code()
    return ['https://%s%s.naihendacina.buzz' % (p, code) for p in ('55', '66', '77')]


def _resolve_base():
    now = time.time()
    if _HOST_CACHE['base'] and now - _HOST_CACHE['ts'] < 3600:
        return _HOST_CACHE['base']
    cands = _host_candidates()
    for base in cands:
        try:
            if _HAS_REQ:
                r = requests.get(base + '/ddd/', headers={'User-Agent': UA}, timeout=15)
                if r.status_code == 200:
                    _HOST_CACHE['base'] = base
                    _HOST_CACHE['ts'] = now
                    return base
            else:
                req = urllib.request.Request(base + '/ddd/', headers={'User-Agent': UA})
                with urllib.request.urlopen(req, timeout=15, context=_ctx()) as resp:
                    if resp.status == 200:
                        _HOST_CACHE['base'] = base
                        _HOST_CACHE['ts'] = now
                        return base
        except Exception:
            pass
    return cands[0] if cands else ''


def _unescape(s):
    return (s or '').replace('&amp;', '&').replace('&quot;', '"').replace('&#39;', "'").replace('&lt;', '<').replace('&gt;', '>').replace('\\/', '/')


def _clean(t):
    if not t:
        return ''
    t = re.sub(r'<[^>]+>', ' ', t)
    return _html.unescape(re.sub(r'\s+', ' ', t)).strip()


def _encode_path(s):
    out = ''
    for b in (s or '').encode('utf-8'):
        c = chr(b)
        if c.isalnum() or c in '-_.~':
            out += c
        else:
            out += '%%%02X' % b
    return out


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
        return '奶很大'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cats(self):
        base = _resolve_base()
        out = []
        if base:
            html = _http_get(base + '/ddd/')
            names = dict(CATS)
            seen = set()
            for mm in re.finditer(r'href="/vodtype/(\d+)\.html"', html or ''):
                cid = mm.group(1)
                if cid in names and cid not in seen:
                    seen.add(cid)
                    out.append((cid, names[cid]))
        return out or list(CATS)

    def _cards(self, html):
        out = []
        seen = set()
        for mm in re.finditer(r'(?s)<a href="/voddetail/(\d+)/"[^>]*class="group-item[^"]*"[^>]*>.*?<img[^>]*src="([^"]+)"[^>]*>.*?<p>(.*?)</p>', html or ''):
            vid = mm.group(1).strip()
            if not vid or vid in seen:
                continue
            title = _unescape(_clean(mm.group(3)))
            if not title:
                continue
            seen.add(vid)
            out.append({
                'vod_id': vid,
                'vod_name': title,
                'vod_pic': _unescape(mm.group(2).strip()),
                'vod_remarks': '',
            })
        return out

    def _catalog(self, tid, pg):
        base = _resolve_base()
        if not base:
            return []
        if pg <= 1:
            url = '%s/vodtype/%s/' % (base, tid)
        else:
            url = '%s/vodtype/%s-%s/' % (base, tid, pg)
        return self._cards(_http_get(url))

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
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        base = _resolve_base()
        if not base:
            return {'list': []}
        vid = nid.strip()
        html = _http_get('%s/voddetail/%s/' % (base, vid))
        if not html:
            return {'list': []}
        title = ''
        m = re.search(r'(?s)<h1[^>]*>(.*?)</h1>', html)
        if m:
            title = _unescape(_clean(m.group(1)))
        cover = ''
        m = re.search(r'<img[^>]*data-src="(https?://[^"]+)"', html)
        if m:
            cover = _unescape(m.group(1).strip())
        synopsis = ''
        m = re.search(r'<meta name="description"[^>]*content="([^"]+)"', html)
        if m:
            synopsis = _unescape(m.group(1).strip())
        play_html = _http_get('%s/vodplay/%s-1-1/' % (base, vid))
        m3u8 = ''
        m = re.search(r'(?s)player_data=.*?"url":"([^"]+)"', play_html or '')
        if m:
            m3u8 = _unescape(m.group(1))
        if not title and play_html:
            m = re.search(r'(?s)<title>(.*?)</title>', play_html)
            if m:
                title = _unescape(m.group(1).strip()).split('-在线观看播放')[0].strip()
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
            'stills': [cover] if cover else [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        base = _resolve_base()
        if not base:
            return {'list': [], 'page': pg, 'pagecount': 0, 'total': 0}
        url = '%s/vodsearch/%s-------------.html' % (base, _encode_path((key or '').strip()))
        items = self._cards(_http_get(url))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        header = {'User-Agent': UA, 'Referer': _resolve_base() + '/'}
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
