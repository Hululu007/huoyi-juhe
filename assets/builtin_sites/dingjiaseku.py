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


BASE = 'https://yxql-imh-nh4d.taoquan26s111.cc'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

CATS = [
    ('200', '特色仓库'),
    ('300', '黑料精品'),
    ('400', '热播片库'),
    ('500', '精品资源'),
]

CARD_RE = re.compile(r'<a class="stui-vodlist__thumb[^"]*" href="/vodplay/(\d+)-1-1/" title="([^"]*)" data-original="([^"]*)"')
CAT_RE = re.compile(r'<a[^>]*href="/vodtype/(\d+)/"[^>]*>([^<]+)</a>')
TITLE_RE = re.compile(r'<h1 class="title">([^<]+)</h1>')
COVER_RE = re.compile(r'<div class="stui-content__thumb">.*?<img[^>]+data-original="([^"]+)"', re.S)
SYN_RE = re.compile(r'<p class="desc detail">.*?<span class="left">简介：(.*?)</span>', re.S)
PLAYBTN_RE = re.compile(r'<div class="play-btn">\s*<a href="(/vodplay/\d+-1-1/)">')
PLAYER_RE = re.compile(r'player_aaaa=.*?"url":"([^"]+)"', re.S)


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _decode(s):
    if not s:
        return ''
    return _html.unescape(s).replace('\\/', '/').strip()


def _fix_url(raw):
    u = (raw or '').strip()
    if not u:
        return ''
    if u.startswith('//'):
        return 'https:' + u
    if u.startswith('/'):
        return BASE + u
    return u


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


def _parse_cards(html):
    out = []
    seen = set()
    for m in CARD_RE.finditer(html or ''):
        vid = m.group(1).strip()
        if not vid or vid in seen:
            continue
        title = _decode(m.group(2))
        if not title:
            continue
        seen.add(vid)
        out.append({
            'vod_id': vid,
            'vod_name': title,
            'vod_pic': _fix_url(m.group(3)),
            'vod_remarks': '',
        })
    return out


def _parse_categories(html):
    out = []
    seen = set()
    for m in CAT_RE.finditer(html or ''):
        cid = m.group(1)
        if not cid.endswith('00'):
            continue
        name = _decode(m.group(2))
        if not name or name == '更多' or cid in seen:
            continue
        seen.add(cid)
        out.append((cid, name))
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
        return '顶级AI色库'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cats(self):
        cats = _parse_categories(_http_get(BASE + '/', referer=BASE + '/'))
        return cats or list(CATS)

    def _catalog(self, tid, pg):
        html = _http_get('%s/vodtype/%s-%s/' % (BASE, tid, pg), referer=BASE + '/')
        return _parse_cards(html)

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
        html = _http_get('%s/voddetail/%s/' % (BASE, nid), referer=BASE + '/')
        if not html:
            return {'list': []}
        tm = TITLE_RE.search(html)
        title = _decode(tm.group(1)) if tm else ''
        if not title:
            return {'list': []}
        cm = COVER_RE.search(html)
        cover = _fix_url(cm.group(1)) if cm else ''
        sm = SYN_RE.search(html)
        synopsis = _decode(sm.group(1)) if sm else ''
        pm = PLAYBTN_RE.search(html)
        play_path = pm.group(1) if pm else '/vodplay/%s-1-1/' % nid
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
            'vod_play_url': '第1集$dingjiaseku:%s' % _fix_url(play_path),
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        q = urllib.parse.quote(key or '')
        html = _http_get('%s/vodsearch/%s-------------/' % (BASE, q), referer=BASE + '/')
        items = _parse_cards(html)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        if raw.startswith('dingjiaseku:'):
            raw = raw[len('dingjiaseku:'):]
        url = _fix_url(raw)
        header = {'User-Agent': UA, 'Referer': url}
        if '.m3u8' in url:
            return {'parse': 0, 'playUrl': url, 'url': url, 'header': header}
        html = _http_get(url, referer=BASE + '/')
        m3u8 = ''
        if html:
            m = PLAYER_RE.search(html)
            if m:
                m3u8 = _decode(m.group(1))
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
