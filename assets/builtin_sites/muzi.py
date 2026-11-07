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


BASE = 'https://web.mzsp1.cc/a'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

FALLBACK_CATS = [
    ('386', '黄瓜短剧'),
    ('244', '55资源'),
    ('119', '不卡资源'),
    ('286', '兔儿资源'),
    ('370', '森林资源'),
    ('358', '母子资源'),
    ('329', '库库资源'),
]


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
        time.sleep(2)
    return ''


def _unescape(s):
    return (s or '').replace('&amp;', '&').replace('&quot;', '"').replace('&#39;', "'").replace('&lt;', '<').replace('&gt;', '>').replace('\\/', '/')


def _clean(t):
    if not t:
        return ''
    t = re.sub(r'<[^>]+>', ' ', t)
    return _html.unescape(re.sub(r'\s+', ' ', t)).strip()


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
        return '母子视频'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cats(self):
        html = _http_get(BASE + '/')
        out = []
        seen = set()
        for mm in re.finditer(r'href="[^"]*/vod/type/id/(\d+)\.html"[^>]*>([^<]+)</a>', html or ''):
            cid = mm.group(1)
            name = mm.group(2).strip()
            if name and cid not in seen:
                seen.add(cid)
                out.append((cid, name))
        return out or list(FALLBACK_CATS)

    def _cards(self, html):
        out = []
        seen = set()
        for mm in re.finditer(r'(?s)<a class="stui-vodlist__thumb lazyload" href="[^"]*/vod/play/id/(\d+)/sid/\d+/nid/\d+\.html"[^>]*title="([^"]+)"[^>]*data-original="([^"]+)"', html or ''):
            vid = mm.group(1).strip()
            if not vid or vid in seen:
                continue
            title = _unescape(mm.group(2).strip())
            if not title:
                continue
            seen.add(vid)
            out.append({
                'vod_id': vid,
                'vod_name': title,
                'vod_pic': mm.group(3).strip(),
                'vod_remarks': '',
            })
        return out

    def _catalog(self, tid, pg):
        if pg <= 1:
            url = '%s/index.php/vod/type/id/%s.html' % (BASE, tid)
        else:
            url = '%s/index.php/vod/type/id/%s/page/%s.html' % (BASE, tid, pg)
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
        vid = nid.strip().lstrip('/')
        if '/vod/detail/id/' in vid:
            vid = vid.rsplit('/vod/detail/id/', 1)[-1]
        vid = vid.lstrip('/').replace('.html', '')
        html = _http_get('%s/index.php/vod/detail/id/%s.html' % (BASE, vid))
        if not html:
            return {'list': []}
        title = ''
        m = re.search(r'(?s)<h1[^>]*>(.*?)</h1>', html)
        if m:
            title = _unescape(_clean(m.group(1)))
        cover = ''
        m = re.search(r'data-original="(https?://[^"]+)"', html)
        if m:
            cover = m.group(1)
        synopsis = ''
        m = re.search(r'<meta name="description"[^>]*content="([^"]*)"', html)
        if m:
            synopsis = _unescape(m.group(1).strip())
        play_link = ''
        m = re.search(r'href="([^"]*/vod/play/id/%s/sid/\d+/nid/1\.html)"' % re.escape(vid), html)
        if m:
            play_link = m.group(1)
        if not title or not play_link:
            return {'list': []}
        play_html = _http_get('https://web.mzsp1.cc' + play_link)
        m3u8 = ''
        m = re.search(r'(?s)player_aaaa=.*?"url":"([^"]+)"', play_html or '')
        if m:
            m3u8 = _unescape(m.group(1))
        if not m3u8:
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
        url = '%s/index.php/vod/search/wd/%s.html' % (BASE, urllib.parse.quote(key or ''))
        items = self._cards(_http_get(url))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

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
