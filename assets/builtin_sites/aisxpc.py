import gzip
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

BASE = 'https://aicjjc.cc'
UA = 'Mozilla/5.0 (Linux; Android 14; HarmonyOS; HUAWEI) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36'

FALLBACK_CATS = [
    ('c1', 'AI成人短剧', 'AIchengrenduanju'),
    ('c2', 'AI成人漫剧', 'AIchengrenmanju'),
    ('c3', 'AI换脸', 'AIhuanlian'),
    ('c4', 'AI魔改', 'AImogai'),
]

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

CACHE = {}
CATS_TTL = 3600
_CUR_BASE = [BASE]


def _now():
    return time.time()


def _http_get(url, referer=None, timeout=25):
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
                time.sleep(2)
            except Exception:
                pass
    return None


def _fetch(path, referer=None):
    base = _CUR_BASE[0]
    return _http_get(base + path, referer=referer or (base + '/home/'))


def _unescape(s):
    if not s:
        return ''
    return (s.replace('&nbsp;', ' ')
             .replace('&amp;', '&')
             .replace('&quot;', '"')
             .replace('&#39;', "'")
             .replace('&lt;', '<')
             .replace('&gt;', '>')
             .replace('\\/', '/'))


def _fix_url(raw):
    u = (raw or '').strip()
    if not u:
        return ''
    if u.startswith('//'):
        return 'https:' + u
    if u.startswith('/'):
        return _CUR_BASE[0] + u
    return u


def _strip_tags(s):
    if not s:
        return ''
    s = re.sub(r'<[^>]+>', ' ', s)
    s = _unescape(s)
    s = re.sub(r'\s+', ' ', s)
    return s.strip()


def _slug_of(category_id):
    t = (category_id or '').strip()
    for cid, _name, slug in FALLBACK_CATS:
        if t == cid or t == slug:
            return slug
    return 'AIchengrenduanju'


def _parse_cards(html):
    out = []
    if not html:
        return out
    card_re = re.compile(
        r'<a[^>]*href="/detail/(\d+)/"[^>]*>(.*?)</a>', re.S)
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


def _fetch_categories():
    v = CACHE.get('cats')
    if v and _now() - v[0] < v[2]:
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
            for c, _n, s in FALLBACK_CATS:
                if s == slug:
                    cid = c
                    break
            cats.append((cid, name))
    ttl = CATS_TTL
    if not cats:
        cats = [(c, n) for c, n, _s in FALLBACK_CATS]
        ttl = 300
    if len(CACHE) > 20:
        CACHE.clear()
    CACHE['cats'] = (_now(), cats, ttl)
    return cats


def _parse_episodes(play_html, series_id):
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
    url = str(data.get('url') or '').strip()
    frm = str(data.get('from') or '').strip()
    return url, frm


def _hg_play(mid, mep, page_url):
    api = _CUR_BASE[0] + '/huangguo.php?ac=play&id=%s&ep=%s&_=%d' % (mid, mep, int(time.time() * 1000))
    hdr = {'User-Agent': UA, 'Referer': page_url, 'X-Requested-With': 'XMLHttpRequest'}
    if _requests is not None:
        try:
            sess = _requests.Session()
            sess.headers.update({'User-Agent': UA})
            sess.get(page_url, headers={'Referer': page_url}, timeout=25)
            resp = sess.get(api, headers=hdr, timeout=25)
            cookie = '; '.join('%s=%s' % (c.name, c.value) for c in sess.cookies)
            return resp.text, cookie
        except Exception:
            return '', ''
    try:
        import http.cookiejar
        jar = http.cookiejar.CookieJar()
        opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
        opener.open(urllib.request.Request(page_url, headers={'User-Agent': UA, 'Referer': page_url}), timeout=25)
        with opener.open(urllib.request.Request(api, headers=hdr), timeout=25, context=CTX) as resp:
            body = resp.read().decode('utf-8', 'replace')
        cookie = '; '.join('%s=%s' % (c.name, c.value) for c in jar)
        return body, cookie
    except Exception:
        return '', ''


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
        return 'Ai小视频'

    def getDependence(self):
        return []

    def init(self, extend=None):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=False):
        cats = [{'type_id': cid, 'type_name': name}
                for cid, name in _fetch_categories()]
        return {'class': cats, 'filters': {}}

    def homeVideoContent(self):
        html = _fetch('/home/')
        items = _parse_cards(html)
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        tid = _norm_id(tid)
        pg = _norm_pg(pg)
        if pg < 1:
            pg = 1
        slug = _slug_of(tid)
        if pg <= 1:
            path = '/aidj/%s/' % slug
        else:
            path = '/aidj/%s/page/%d/' % (slug, pg)
        html = _fetch(path)
        items = _parse_cards(html)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        raw = _norm_id(ids)
        nid = ''.join([ch for ch in raw if ch.isdigit()])
        if not nid:
            return _empty_detail(raw)
        html = _fetch('/detail/%s/' % nid)
        if not html:
            return _empty_detail(nid)
        title = ''
        tm = re.search(r'(?s)<h1[^>]*>(.*?)</h1>', html)
        if tm:
            title = _strip_tags(tm.group(1))
        if not title:
            tt = re.search(r'(?s)<title[^>]*>(.*?)</title>', html)
            if tt:
                title = _strip_tags(tt.group(1))
                for suffix in ('在线观看', '剧情介绍'):
                    pos = title.find(suffix)
                    if pos >= 0:
                        title = title[:pos].strip()
                        break
        if not title:
            return _empty_detail(nid)
        cover = ''
        cm = re.search(r'<img class="detail-poster"[^>]*src="([^"]+)"', html)
        if cm:
            cover = _fix_url(cm.group(1))
        if not cover:
            om = re.search(r'<meta property="og:image"[^>]*content="([^"]+)"', html)
            if om:
                cover = _fix_url(om.group(1))
        dm = re.search(r'(?s)<div class="detail-desc">(.*?)</div>', html)
        synopsis = _strip_tags(dm.group(1)) if dm else ''
        remark = ''
        mm = re.search(r'(?s)<div class="detail-meta">(.*?)</div>', html)
        if mm:
            remark = _strip_tags(mm.group(1))
        eps = []
        play_html = _fetch('/play/%s-1-1/' % nid)
        eps = _parse_episodes(play_html, nid)
        if not eps:
            bm = re.search(r'href="(/play/\d+-1-\d+/)"[^>]*>立即播放', html)
            if bm:
                eps = [(1, bm.group(1))]
        if not eps:
            return _empty_detail(nid)
        plays = []
        for no, path in eps:
            m2 = re.search(r'/play/(\d+)-1-(\d+)/', path)
            if m2:
                plays.append('第%d集$aisxpc:%s-1-%s' % (no, m2.group(1), m2.group(2)))
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
        if pg < 1:
            pg = 1
        kw = urllib.parse.quote_plus(str(key).strip())
        html = _fetch('/search/-------------/?wd=' + kw)
        items = _parse_cards(html)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        if raw.startswith('aisxpc:'):
            raw = raw.split(':', 1)[1].strip()
        if raw.startswith('http'):
            header = {'User-Agent': UA, 'Referer': _CUR_BASE[0] + '/home/'}
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        parts = raw.split('-')
        if len(parts) != 3:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        vid, sid, ep = parts[0], parts[1], parts[2]
        if not vid.isdigit() or not ep.isdigit():
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        play_page = '/play/%s-%s-%s/' % (vid, sid, ep)
        page_url = _CUR_BASE[0] + play_page
        html = _fetch(play_page, referer=page_url)
        url, frm = _parse_player_data(html)
        header = {'User-Agent': UA, 'Referer': page_url}
        if not url:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        if '.m3u8' in url or '.mp4' in url:
            return {'parse': 0, 'playUrl': url, 'url': url, 'header': header}
        if '|' not in url:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        mid, mep = url.split('|', 1)
        mid = mid.strip()
        mep = mep.strip()
        if frm != 'huangguo' or not mid or not mep:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        body, cookie = _hg_play(mid, mep, page_url)
        if not body:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        try:
            data = json.loads(body)
        except Exception:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        if data.get('code') != 1:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        proxy = str(data.get('url') or '').strip()
        if proxy.startswith('/hgmedia.php?e=') or proxy.startswith('/huangguo.php?ac=media&t='):
            full = _CUR_BASE[0] + proxy
        elif proxy.startswith('http'):
            full = proxy
        else:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        if cookie:
            header['Cookie'] = cookie
        return {'parse': 0, 'playUrl': full, 'url': full, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', b'', {}]

    def isVideoFormat(self, url):
        u = str(url or '').lower().split('?')[0]
        return u.endswith(('.m3u8', '.mp4', '.mkv', '.webm', '.flv', '.ts'))

    def manualVideoCheck(self):
        return True

    def action(self, action, params=None):
        return {'code': 0, 'msg': 'ok'}
