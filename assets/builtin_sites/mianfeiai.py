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


API = 'https://abcdefgh.xingkongtuieee.cc/tiaoapi.php?action=batch&yl_from=yuenvge'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

FALLBACK_CATS = [
    ('1', '国产'),
    ('6', '自拍'),
    ('60', 'AI短剧'),
    ('7', '三观尽毁'),
    ('24', '无码'),
    ('50', '有码'),
    ('25', '中字'),
    ('26', '欧美'),
    ('27', '动漫'),
    ('28', '三级片'),
    ('10', '反差婊'),
    ('11', '网爆门'),
    ('29', 'AV解说'),
    ('9', '传媒'),
    ('8', '迷奸强奸'),
    ('12', '偷拍'),
    ('30', '兄妹'),
    ('31', '母子'),
    ('32', '小姨'),
    ('33', '嫂子'),
    ('34', '野外'),
    ('35', '换妻'),
    ('36', '儿媳'),
    ('37', '下海'),
    ('2', '网红'),
    ('15', '学生妹'),
    ('3', '萝莉'),
    ('51', '黑料'),
    ('13', '福利姬'),
    ('14', '吃瓜'),
    ('16', '人兽'),
    ('5', '探花'),
    ('38', '瑜伽裤'),
    ('52', '技师'),
    ('53', '绿帽'),
    ('54', '丝足'),
    ('55', '偷情'),
    ('56', '校园'),
    ('57', '撸管'),
    ('4', '大秀'),
    ('58', '制服'),
    ('39', '兽耳系列'),
    ('20', '喷水'),
    ('40', '多人群P'),
    ('23', 'AI换脸'),
    ('22', '性虐'),
    ('17', '人妖'),
    ('41', 'Cosplay'),
    ('18', 'OnlyFans'),
    ('59', '黑巨炮'),
]

_SITE_CACHE = {'base': '', 'cookie': None, 'ts': 0}


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _http_get(url, cookie=None, timeout=25):
    h = {'User-Agent': UA, 'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8', 'Accept-Language': 'zh-CN,zh;q=0.9', 'Accept-Encoding': 'gzip, deflate', 'Referer': url}
    if cookie:
        h['Cookie'] = 'xk_gate=' + cookie
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


def _is_gate(html):
    return "var token='" in html or 'xk_gate' in html


def _parse_token(html):
    m = re.search(r"var token='([^']+)'", html or '')
    return m.group(1) if m else ''


def _resolve_site():
    now = time.time()
    if _SITE_CACHE['base'] and now - _SITE_CACHE['ts'] < 600:
        return _SITE_CACHE['base'], _SITE_CACHE['cookie']
    base = ''
    cookie = None
    for _ in range(3):
        try:
            body = _http_get(API)
            obj = json.loads(body or '{}')
            arr = obj.get('domains') or []
            if arr:
                base = str(arr[0]).rstrip('/')
                break
        except Exception:
            pass
        time.sleep(1)
    if not base or not base.startswith('http'):
        return '', None
    home = _http_get(base + '/?yl_from=yuenvge')
    if _is_gate(home):
        token = _parse_token(home)
        if token:
            cookie = token
    _SITE_CACHE['base'] = base
    _SITE_CACHE['cookie'] = cookie
    _SITE_CACHE['ts'] = now
    return base, cookie


def _get_text(url):
    base, cookie = _resolve_site()
    if not base:
        return ''
    for _ in range(3):
        txt = _http_get(url, cookie=cookie)
        if not txt:
            time.sleep(1)
            continue
        if _is_gate(txt):
            token = _parse_token(txt)
            if token:
                cookie = token
                txt = _http_get(url, cookie=cookie)
                if txt:
                    return txt
            return ''
        return txt
    return ''


def _fix_url(base, raw):
    u = (raw or '').strip()
    if not u:
        return ''
    if u.startswith('//'):
        return 'https:' + u
    if u.startswith('/'):
        return base + u
    return u


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
        return '免费AI短剧'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cats(self):
        base, _ = _resolve_site()
        cats = []
        if base:
            html = _get_text(base + '/')
            m = re.search(r'(?s)<div class="nav nav-cats" data-flag="vod">(.*?)</div>', html or '')
            scope = m.group(1) if m else (html or '')
            seen = set()
            for mm in re.finditer(r'href="/t/(\d+)\.html"[^>]*>([^<]+)<', scope):
                cid = mm.group(1)
                name = mm.group(2).strip()
                if name and cid not in seen:
                    seen.add(cid)
                    cats.append((cid, name))
        return cats or list(FALLBACK_CATS)

    def _cards(self, base, html):
        out = []
        seen = set()
        for mm in re.finditer(r'(?s)<a class="(?:pic|vpic)" href="/s/(\d+)\.html" title="([^"]+)" style="background-image:url\(([^)]+)\)"', html or ''):
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
                'vod_pic': _fix_url(base, mm.group(3)),
                'vod_remarks': '',
            })
        return out

    def _catalog(self, tid, pg):
        base, _ = _resolve_site()
        if not base:
            return []
        if pg <= 1:
            url = '%s/t/%s.html' % (base, tid)
        else:
            url = '%s/t/%s-%s.html' % (base, tid, pg)
        html = _get_text(url)
        return self._cards(base, html)

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
        base, _ = _resolve_site()
        if not base:
            return {'list': []}
        vid = nid.strip().lstrip('/')
        if vid.startswith('s/'):
            vid = vid[2:]
        vid = vid.split('/')[0].replace('.html', '')
        html = _get_text('%s/s/%s.html' % (base, vid))
        if not html:
            return {'list': []}
        title = ''
        m = re.search(r'(?s)<h1[^>]*>(.*?)</h1>', html)
        if m:
            title = _unescape(_clean(m.group(1)))
        if not title:
            m = re.search(r'<title>(.*?)</title>', html)
            if m:
                title = _unescape(m.group(1).strip())
                if title.endswith('_星空中文影院'):
                    title = title[:-len('_星空中文影院')]
        cover = ''
        m = re.search(r'background-image:url\(([^)]+)\)', html)
        if m:
            cover = _fix_url(base, m.group(1))
        synopsis = ''
        m = re.search(r'<meta name="description"[^>]*content="([^"]+)"', html)
        if m:
            synopsis = _unescape(m.group(1).strip())
        genre = ''
        m = re.search(r'href="/t/(\d+)\.html">([^<]+)<', html)
        if m:
            genre = _unescape(m.group(2).strip())
        play_path = ''
        m = re.search(r'href="(/s-p/\d+-1-1\.html)"', html)
        if m:
            play_path = m.group(1)
        if not title or not play_path:
            return {'list': []}
        play_html = _get_text(base + play_path)
        m3u8 = ''
        m = re.search(r'(?s)var player_data=(\{.*?\})\s*</script>', play_html or '')
        if m:
            try:
                obj = json.loads(m.group(1))
                m3u8 = obj.get('url') or ''
            except Exception:
                pass
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
            'type_name': genre,
            'vod_tag': genre,
            'vod_play_from': '在线播放',
            'vod_play_url': '播放$%s' % m3u8,
            'stills': [cover] if cover else [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        base, _ = _resolve_site()
        if not base:
            return {'list': [], 'page': pg, 'pagecount': 0, 'total': 0}
        url = base + '/sou/-.html?wd=' + urllib.parse.quote(key or '')
        html = _get_text(url)
        items = self._cards(base, html)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        header = {'User-Agent': UA, 'Referer': _resolve_site()[0] + '/'}
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
