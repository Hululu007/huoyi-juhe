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


BASE = 'http://zi.ri511.xyz'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

TABS = [('hot', '热门'), ('latest', '最新'), ('rec', '推荐')]

FALLBACK_STREAMERS = [
    ('135', '琳琳'),
    ('123', '小媛'),
    ('32', '愛子'),
    ('167', '吴夢夢'),
    ('194', 'princessdolly'),
    ('107', '灣灣'),
    ('52', 'chinh'),
    ('161', 'Mio'),
    ('169', '沐沐'),
    ('85', '菲菲'),
    ('46', 'candybaby'),
    ('89', 'funnyg'),
    ('3', '貝拉'),
    ('241', 'aprillady'),
    ('149', '芊芊'),
    ('132', '黎兒'),
    ('239', '娃娃'),
    ('160', 'minicat'),
]


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _http_get(url, timeout=25):
    h = {'User-Agent': UA, 'Referer': BASE, 'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8', 'Accept-Language': 'zh-CN,zh;q=0.9', 'Accept-Encoding': 'gzip, deflate'}
    for _ in range(3):
        if _HAS_REQ:
            try:
                r = requests.get(url, headers=h, timeout=timeout)
                if r.status_code == 200 and r.text.strip():
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
                txt = data.decode('utf-8', 'replace')
                if txt.strip():
                    return txt
        except urllib.error.HTTPError as e:
            try:
                return e.read().decode('utf-8', 'ignore')
            except http.client.IncompleteRead as ie:
                return ie.partial.decode('utf-8', 'ignore')
        except Exception:
            pass
        time.sleep(1)
    return ''


def _fix_url(raw):
    u = (raw or '').strip()
    if not u:
        return ''
    if u.startswith('//'):
        return 'https:' + u
    if u.startswith('/'):
        return BASE + u
    return u


def _unescape(s):
    if not s:
        return ''
    return _html.unescape(s).replace('\\/', '/')


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


def _title_from_alt(alt):
    t = _unescape((alt or '').strip())
    pos = t.find('-swag-')
    if pos >= 0:
        rest = t[pos + 6:].strip()
        if rest:
            return rest
    return t


def _cards(html):
    out = []
    seen = set()
    pat = re.compile(r'<a href="/category/(\d+)/(\d+)">.*?<img[^>]*alt="([^"]*)"[^>]*data-src="([^"]+)"', re.S)
    dur_re = re.compile(r'fa-clock-o"></i>\s*([^<\s]+)')
    for m in pat.finditer(html or ''):
        key = '%s/%s' % (m.group(1), m.group(2))
        if key in seen:
            continue
        seen.add(key)
        title = _title_from_alt(m.group(3))
        if not title:
            continue
        tail = (html or '')[m.end():m.end() + 800]
        dm = dur_re.search(tail)
        remark = dm.group(1).strip() if dm else ''
        out.append({'vod_id': key, 'vod_name': title, 'vod_pic': _fix_url(m.group(4)), 'vod_remarks': remark})
    return out


def _tab_sections(html):
    m = re.search(r'<dl class="tab-bd">(.*?)</dl>', html or '', re.S)
    if not m:
        return []
    return re.findall(r'<dd[^>]*>(.*?)</dd>', m.group(1), re.S)


def _streamers(html):
    out = []
    seen = set()
    pat = re.compile(r'<a href="/category/(\d+)">([^<]{1,30})</a>')
    for m in pat.finditer(html or ''):
        sid, name = m.group(1), _unescape(m.group(2).strip())
        if not name or sid in seen:
            continue
        seen.add(sid)
        out.append(('s%s' % sid, name))
    return out


def _fallback_cats():
    out = list(TABS)
    for sid, name in FALLBACK_STREAMERS:
        out.append(('s%s' % sid, name))
    return out


class Spider(BaseSpider):
    def getName(self):
        return 'SWAG资源合集'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cats(self):
        out = list(TABS)
        html = _http_get(BASE + '/category')
        streamers = _streamers(html) if html else []
        if not streamers:
            return _fallback_cats()
        out.extend(streamers)
        return out

    def homeContent(self, filter=''):
        cats = self._cats()
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
            items = self.categoryContent(self._cats()[0][0], 1).get('list') or []
        except Exception:
            items = []
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        tab_ids = [t[0] for t in TABS]
        if tid in tab_ids:
            idx = tab_ids.index(tid)
            html = _http_get(BASE + '/?a=11&t=sys')
            sections = _tab_sections(html)
            items = _cards(sections[idx]) if idx < len(sections) else []
            return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}
        if not (tid or '').startswith('s'):
            return {'list': [], 'page': pg, 'pagecount': 0, 'total': 0}
        sid = tid[1:]
        if pg <= 1:
            url = '%s/category/%s' % (BASE, sid)
        else:
            url = '%s/category/%s?page=%s' % (BASE, sid, pg)
        html = _http_get(url)
        items = _cards(html)
        total = None
        tm = re.search(r'page_total\s*=\s*(\d+)', html or '')
        if tm:
            try:
                total = int(tm.group(1))
            except Exception:
                total = None
        if not items:
            has_more = False
        elif total is not None:
            has_more = pg < total
        else:
            has_more = len(items) >= 24
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        key = _norm_id(ids)
        if not key:
            return {'list': []}
        html = _http_get('%s/category/%s' % (BASE, key))
        if not html:
            return {'list': []}
        trailer = ''
        vm = re.search(r'<video[^>]*src="([^"]+)"', html, re.S)
        if vm:
            trailer = _unescape(vm.group(1))
        title = ''
        tm = re.search(r'<div class="online-title">\s*(.*?)\s*</div>', html, re.S)
        if tm:
            title = _unescape(tm.group(1).strip())
        cover = ''
        pm = re.search(r'<video[^>]*poster="([^"]+)"', html, re.S)
        if pm:
            cover = _fix_url(pm.group(1))
        views = ''
        vm2 = re.search(r'(\d[\d.]*[wk])', html)
        if vm2:
            views = vm2.group(1)
        duration = ''
        dm = re.search(r'(\d+分\d+秒)', html)
        if dm:
            duration = dm.group(1)
        parts = []
        for m in re.finditer(r'<p[^>]*>([^<]{6,200})</p>', html, re.S):
            t = _unescape(m.group(1).strip())
            if any(w in t for w in ('下载', '会员', 'VIP', '百度', '解压', '提取', '存储')):
                continue
            if t not in parts:
                parts.append(t)
            if len(parts) >= 5:
                break
        actor = ''
        am = re.search(r'<h3 class="f-18">([^<]+?)\s*/', html)
        if am:
            actor = _unescape(am.group(1).strip())
        if not title or not trailer:
            return {'list': []}
        if views and duration:
            remark = views + ' ' + duration
        else:
            remark = views or duration
        return {'list': [{
            'vod_id': key,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': actor,
            'vod_director': '',
            'vod_remarks': remark,
            'vod_year': '',
            'vod_area': '',
            'vod_content': ' '.join(parts),
            'type_name': '',
            'vod_tag': '',
            'vod_play_from': '在线播放',
            'vod_play_url': '预告片$%s' % trailer,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        url = '%s/search?content=%s' % (BASE, urllib.parse.quote(str(key or '')))
        html = _http_get(url)
        items = _cards(html)
        return {'list': items, 'page': _norm_pg(pg), 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        if raw.startswith('http'):
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
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
