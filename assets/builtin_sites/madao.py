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

BASE = 'https://Madaoavmodv026.xyz'
UA = 'Mozilla/5.0 (Linux; Android 14; HarmonyOS; HUAWEI) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36'

CATS = [
    ('domestic-media', '国产传媒'),
    ('guochanshipin', '国产视频'),
    ('japanese-av', '日本有码'),
    ('chinese-subtitles', '中文字幕'),
    ('ribenwuma', '无码视频'),
    ('AI', 'AI'),
]

_CATIDS = set(cid for cid, _ in CATS)


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
            except Exception:
                pass
        except Exception:
            pass
        time.sleep(1)
    return ''


def _http_post_form(url, form, referer=None, timeout=25):
    h = {'User-Agent': UA, 'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8', 'Content-Type': 'application/x-www-form-urlencoded'}
    if referer:
        h['Referer'] = referer
    data = form.encode('utf-8') if isinstance(form, str) else form
    for _ in range(3):
        if _HAS_REQ:
            try:
                r = requests.post(url, data=data, headers=h, timeout=timeout)
                if r.status_code == 200 and r.text:
                    return r.text
            except Exception:
                pass
        try:
            req = urllib.request.Request(url, data=data, headers=h, method='POST')
            with urllib.request.urlopen(req, timeout=timeout, context=_ctx()) as resp:
                return resp.read().decode('utf-8', 'replace')
        except urllib.error.HTTPError as e:
            try:
                return e.read().decode('utf-8', 'ignore')
            except Exception:
                pass
        except Exception:
            pass
        time.sleep(1)
    return ''


def _clean(t):
    if not t:
        return ''
    t = re.sub(r'<[^>]+>', ' ', t)
    return _html.unescape(re.sub(r'\s+', ' ', t)).strip()


def _unescape(s):
    return _html.unescape(s or '').strip()


def _fix_url(raw):
    u = (raw or '').strip()
    if not u:
        return ''
    if u.startswith('https:/') and not u.startswith('https://'):
        return 'https://' + u[len('https:/'):]
    if u.startswith('http:/') and not u.startswith('http://'):
        return 'http://' + u[len('http:/'):]
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


def _catalog_url(slug, pg):
    return '%s/vodshow/%s--------%d---/' % (BASE, slug, pg)


def _cards(html):
    out = []
    seen = set()
    anchor_re = re.compile(r'<a href="/av/([^"]+)" aria-label="([^"]+)"')
    img_re = re.compile(r'<img[^>]*src="([^"]+)"')
    dur_re = re.compile(r'>(\d{1,2}:\d{2})<')
    anchors = []
    for m in anchor_re.finditer(html or ''):
        anchors.append((m.start(), m.end(), m.group(1), _unescape(m.group(2).strip())))
    for i, (start, end, slug, title) in enumerate(anchors):
        if slug == 'app' or not title:
            continue
        vid = '/av/' + slug
        if vid in seen:
            continue
        if i + 1 < len(anchors):
            win_end = min(anchors[i + 1][0], end + 4000)
        else:
            win_end = min(end + 4000, len(html))
        if win_end <= end:
            continue
        win = html[end:win_end]
        m = img_re.search(win[:1500])
        cover = _fix_url(m.group(1)) if m else ''
        if not cover or '/template/' in cover:
            continue
        m = dur_re.search(win)
        remark = m.group(1) if m else ''
        seen.add(vid)
        out.append({'vod_id': vid, 'vod_name': title, 'vod_pic': cover, 'vod_remarks': remark})
    return out


def _parse_player(html):
    m = re.search(r'(?s)var player_aaaa=(\{.*?\})</script>', html or '')
    if not m:
        return None
    try:
        return json.loads(m.group(1))
    except Exception:
        return None


class Spider(BaseSpider):
    def getName(self):
        return '麻豆傳媒'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=''):
        cats = list(CATS)
        items = _cards(_http_get(_catalog_url(cats[0][0], 1), referer=BASE + '/'))
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in cats],
            'list': items,
        }

    def homeVideoContent(self):
        cats = list(CATS)
        items = _cards(_http_get(_catalog_url(cats[0][0], 1), referer=BASE + '/'))
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        tid = _norm_id(tid)
        slug = tid if tid in _CATIDS else CATS[0][0]
        html = _http_get(_catalog_url(slug, pg), referer=BASE + '/')
        items = _cards(html)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        if nid.startswith('http'):
            url = nid
        elif nid.startswith('/av/'):
            url = BASE + nid
        elif nid.startswith('av/'):
            url = BASE + '/' + nid
        elif nid.startswith('/'):
            url = BASE + nid
        else:
            url = BASE + '/av/' + nid
        html = _http_get(url, referer=BASE + '/')
        if not html:
            return {'list': []}
        player = _parse_player(html)
        m3u8 = ''
        vod = {}
        if isinstance(player, dict):
            m3u8 = player.get('url') or ''
            if isinstance(player.get('vod_data'), dict):
                vod = player['vod_data']
        m = re.search(r'<h1[^>]*>([^<]+)<', html)
        title = _unescape(m.group(1).strip()) if m else ''
        if not title:
            title = vod.get('vod_name') or ''
        if not title:
            m = re.search(r'(?s)<title[^>]*>(.*?)</title>', html)
            if m:
                t = _unescape(m.group(1).strip())
                pos = t.find(' 高清線上播放')
                if pos >= 0:
                    t = t[:pos]
                title = t
        m = re.search(r'<meta property="og:image"[^>]*content="([^"]+)"', html)
        cover = _fix_url(m.group(1)) if m else ''
        m = re.search(r'<meta name="description"[^>]*content="([^"]+)"', html)
        synopsis = _unescape(m.group(1).strip()) if m else ''
        actor = vod.get('vod_actor') or ''
        vclass = vod.get('vod_class') or ''
        if not title or not m3u8:
            return {'list': []}
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': actor,
            'vod_director': vod.get('vod_director') or '',
            'vod_remarks': '',
            'vod_year': '',
            'vod_area': '',
            'vod_content': synopsis,
            'type_name': vclass,
            'vod_tag': vclass,
            'vod_play_from': '在线播放',
            'vod_play_url': '播放$%s' % m3u8,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        form = 'wd=' + urllib.parse.quote(str(key or ''), safe='')
        html = _http_post_form(BASE + '/avsearch/', form, referer=BASE + '/')
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
