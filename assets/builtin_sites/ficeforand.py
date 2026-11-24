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


BASE = 'https://ficeforand.aicjjc.cc'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

CATS = [
    ('c1', 'AI成人短剧', 'AIchengrenduanju'),
    ('c2', 'AI成人漫剧', 'AIchengrenmanju'),
    ('c3', 'AI换脸', 'AIhuanlian'),
    ('c4', 'AI魔改', 'AImogai'),
]

_CACHE = {}
CATS_TTL = 3600


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _http_get(url, referer=None, timeout=25, extra=None):
    h = {'User-Agent': UA, 'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8', 'Accept-Language': 'zh-CN,zh;q=0.9', 'Accept-Encoding': 'gzip, deflate'}
    if referer:
        h['Referer'] = referer
    if extra:
        h.update(extra)
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


def _fetch(path, referer=None, extra=None):
    return _http_get(BASE + path, referer=referer or (BASE + '/home/'), extra=extra)


def _unescape(s):
    if not s:
        return ''
    return _html.unescape(s).replace('&nbsp;', ' ').strip()


def _strip_tags(s):
    if not s:
        return ''
    s = re.sub(r'<[^>]+>', ' ', s)
    s = _unescape(s)
    return re.sub(r'\s+', ' ', s).strip()


def _fix_url(u):
    if not u:
        return ''
    u = _html.unescape(u).strip()
    if u.startswith('//'):
        return 'https:' + u
    if u.startswith('/'):
        return BASE + u
    return u


def _slug_of(tid):
    t = (tid or '').strip()
    for cid, _name, slug in CATS:
        if t == cid or t == slug:
            return slug
    return 'AIchengrenduanju'


def _parse_cards(html):
    out = []
    if not html:
        return out
    card_re = re.compile(r'<a[^>]*href="/detail/(\d+)/"[^>]*>(.*?)</a>', re.S)
    h3_re = re.compile(r'<h3[^>]*>([^<]+)</h3>')
    alt_re = re.compile(r'alt="([^"]+)"')
    title_re = re.compile(r'title="([^"]+)"')
    img_re = re.compile(r'<img[^>]*src="([^"]+)"')
    badge_re = re.compile(r'video-badge">([^<]+)<')
    date_re = re.compile(r'(\d{4}-\d{2}-\d{2})')
    seen = set()
    for m in card_re.finditer(html):
        vid = m.group(1).strip()
        if not vid or vid in seen:
            continue
        seen.add(vid)
        body = m.group(2)
        title = ''
        hm = h3_re.search(body)
        if hm:
            title = hm.group(1).strip()
        if not title:
            am = alt_re.search(body)
            if am:
                title = am.group(1).strip()
        if not title:
            tm = title_re.search(m.group(0))
            if tm:
                title = tm.group(1).strip()
        title = _unescape(title)
        if not title:
            continue
        im = img_re.search(body)
        cover = _fix_url(im.group(1)) if im else ''
        bm = badge_re.search(body)
        badge = bm.group(1).strip() if bm else ''
        dm = date_re.search(body)
        date = dm.group(1) if dm else ''
        if date and badge:
            remark = '%s · %s' % (date, badge)
        else:
            remark = date or badge
        out.append({
            'vod_id': vid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_remarks': remark,
        })
    return out


def _parse_episodes(play_html):
    eps = []
    if not play_html:
        return eps
    pat = re.compile(r'href="(/play/\d+-1-(\d+)/)"[^>]*>\s*第(\d+)集')
    seen = set()
    for m in pat.finditer(play_html):
        path = m.group(1)
        if path in seen:
            continue
        seen.add(path)
        try:
            no = int(m.group(2))
        except Exception:
            no = 0
        eps.append((no, path))
    eps.sort(key=lambda x: x[0])
    return eps


def _parse_player_data(html):
    if not html:
        return '', ''
    m = re.search(r'var player_data=(\{.*?\})</script>', html, re.S)
    if not m:
        return '', ''
    try:
        data = json.loads(m.group(1))
    except Exception:
        return '', ''
    return str(data.get('url') or '').strip(), str(data.get('from') or '').strip()


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
        return 'AI小视频'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cats(self):
        v = _CACHE.get('cats')
        if v and time.time() - v[0] < v[2]:
            return v[1]
        cats = []
        html = _fetch('/home/')
        if html:
            pat = re.compile(r'<a[^>]*href="/aidj/([^/]+)/"[^>]*>([^<]+)</a>')
            seen = set()
            for m in pat.finditer(html):
                slug = m.group(1).strip()
                name = _unescape(m.group(2).strip())
                if not name or slug in seen:
                    continue
                seen.add(slug)
                cid = 'c1'
                for c, _n, s in CATS:
                    if s == slug:
                        cid = c
                        break
                cats.append((cid, name))
        ttl = CATS_TTL
        if not cats:
            cats = [(c, n) for c, n, _s in CATS]
            ttl = 300
        if len(_CACHE) > 20:
            _CACHE.clear()
        _CACHE['cats'] = (time.time(), cats, ttl)
        return cats

    def homeContent(self, filter=''):
        cats = self._cats()
        items = _parse_cards(_fetch('/home/'))
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in cats],
            'list': items,
        }

    def homeVideoContent(self):
        items = _parse_cards(_fetch('/home/'))
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        slug = _slug_of(_norm_id(tid))
        if pg <= 1:
            path = '/aidj/%s/' % slug
        else:
            path = '/aidj/%s/page/%d/' % (slug, pg)
        items = _parse_cards(_fetch(path))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        nid = ''.join([ch for ch in _norm_id(ids) if ch.isdigit()])
        if not nid:
            return {'list': []}
        html = _fetch('/detail/%s/' % nid)
        if not html:
            return {'list': []}
        title = ''
        tm = re.search(r'<h1[^>]*>(.*?)</h1>', html, re.S)
        if tm:
            title = _strip_tags(tm.group(1))
        if not title:
            tt = re.search(r'<title[^>]*>(.*?)</title>', html, re.S)
            if tt:
                title = _strip_tags(tt.group(1))
                for suffix in ('在线观看', '剧情介绍'):
                    pos = title.find(suffix)
                    if pos >= 0:
                        title = title[:pos].strip()
                        break
        if not title:
            return {'list': []}
        cover = ''
        cm = re.search(r'<img class="detail-poster"[^>]*src="([^"]+)"', html)
        if cm:
            cover = _fix_url(cm.group(1))
        if not cover:
            om = re.search(r'<meta property="og:image"[^>]*content="([^"]+)"', html)
            if om:
                cover = _fix_url(om.group(1))
        dm = re.search(r'<div class="detail-desc">(.*?)</div>', html, re.S)
        synopsis = _strip_tags(dm.group(1)) if dm else ''
        remark = ''
        mm = re.search(r'<div class="detail-meta">(.*?)</div>', html, re.S)
        if mm:
            remark = _strip_tags(mm.group(1))
        eps = _parse_episodes(_fetch('/play/%s-1-1/' % nid))
        if not eps:
            bm = re.search(r'href="(/play/\d+-1-\d+/)"[^>]*>立即播放', html)
            if bm:
                eps = [(1, bm.group(1))]
        if not eps:
            return {'list': []}
        plays = []
        for no, path in eps:
            m2 = re.search(r'/play/(\d+)-1-(\d+)/', path)
            if m2:
                plays.append('第%d集$ficeforand:%s-1-%s' % (no, m2.group(1), m2.group(2)))
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': remark,
            'vod_year': '',
            'vod_area': '',
            'vod_content': synopsis,
            'type_name': '',
            'vod_tag': '',
            'vod_play_from': '在线播放',
            'vod_play_url': '#'.join(plays),
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        kw = urllib.parse.quote_plus((key or '').strip())
        items = _parse_cards(_fetch('/search/-------------/?wd=' + kw))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        if raw.startswith('ficeforand:'):
            raw = raw[len('ficeforand:'):]
        header = {'User-Agent': UA, 'Referer': BASE + '/home/'}
        if raw.startswith('http'):
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        parts = raw.split('-')
        if len(parts) != 3:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        vid, sid, ep = parts[0], parts[1], parts[2]
        if not vid.isdigit() or not ep.isdigit():
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        play_page = '/play/%s-%s-%s/' % (vid, sid, ep)
        page_url = BASE + play_page
        header = {'User-Agent': UA, 'Referer': page_url}
        html = _fetch(play_page, referer=page_url)
        url, frm = _parse_player_data(html)
        if not url:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        if '.m3u8' in url or '.mp4' in url:
            return {'parse': 0, 'playUrl': url, 'url': url, 'header': header}
        if '|' not in url or frm != 'huangguo':
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        mid, mep = url.split('|', 1)
        mid = mid.strip()
        mep = mep.strip()
        if not mid or not mep:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        body = _fetch('/huangguo.php?ac=play&id=%s&ep=%s' % (mid, mep), referer=page_url, extra={'X-Requested-With': 'XMLHttpRequest'})
        if not body:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        try:
            data = json.loads(body)
        except Exception:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        if data.get('code') != 1:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        proxy = str(data.get('url') or '').strip()
        if not (proxy.startswith('/hgmedia.php?e=') or proxy.startswith('/huangguo.php?ac=media&t=')):
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        full = BASE + proxy
        return {'parse': 0, 'playUrl': full, 'url': full, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', '']

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
