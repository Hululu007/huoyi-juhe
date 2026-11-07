import gzip
import html as _html
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

BASE = 'https://51xz.vip'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

CATS = [
    ('home', '每日精选'),
    ('m:真实自拍', '真实自拍'),
    ('m:网红女神', '网红女神'),
    ('m:国产精品', '精品国产'),
    ('m:爱好男同', '爱好男同'),
    ('m:情感剧场', '情感剧场'),
    ('m:古装历史', '古装剧场'),
    ('m:年代农村', '年代农村'),
    ('m:穿越重生', '穿越重生'),
    ('m:今日吃瓜', '今日吃瓜'),
    ('m:海外吃瓜', '海外吃瓜'),
    ('m:娱乐吃瓜', '娱乐吃瓜'),
    ('m:网红黑料', '网红黑料'),
    ('m:日本无码', '日本AV'),
    ('m:国产av', '国产AV'),
    ('m:欧美av', '欧美AV'),
    ('m:动漫av', '动漫AV'),
]

try:
    import requests
    _HAS_REQ = True
except Exception:
    _HAS_REQ = False

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE


def _http_get(url, referer=None, timeout=25):
    hdr = {
        'User-Agent': UA,
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
        'Accept-Encoding': 'gzip, deflate',
    }
    if referer:
        hdr['Referer'] = referer
    if _HAS_REQ:
        try:
            r = requests.get(url, headers=hdr, timeout=timeout)
            if r.status_code == 200 and r.text and r.text.strip():
                return r.text
        except Exception:
            pass
    for attempt in range(3):
        try:
            req = urllib.request.Request(url, headers=hdr)
            with urllib.request.urlopen(req, timeout=timeout, context=CTX) as resp:
                data = resp.read()
                enc = (resp.headers.get('Content-Encoding') or '').lower()
            if enc == 'gzip' or data[:2] == b'\x1f\x8b':
                try:
                    data = gzip.decompress(data)
                except Exception:
                    pass
            return data.decode('utf-8', 'replace')
        except Exception:
            if attempt < 2:
                time.sleep(1)
    return ''


def _unescape(s):
    if not s:
        return ''
    return _html.unescape(s.replace('&nbsp;', ' ')).strip()


def _txt(v):
    if v is None:
        return ''
    if isinstance(v, str):
        return v.strip()
    return str(v).strip()


def _fmt_duration(secs):
    try:
        secs = int(secs)
    except Exception:
        return ''
    if secs <= 0:
        return ''
    h = secs // 3600
    m = (secs % 3600) // 60
    s = secs % 60
    if h > 0:
        return '%d:%02d:%02d' % (h, m, s)
    return '%d:%02d' % (m, s)


def _iso_seconds(s):
    m = re.search(r'PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?', s or '')
    if not m:
        return 0
    h = int(m.group(1)) if m.group(1) else 0
    mi = int(m.group(2)) if m.group(2) else 0
    se = int(m.group(3)) if m.group(3) else 0
    return h * 3600 + mi * 60 + se


def _field(block, key):
    m = re.search(r'\\?"' + re.escape(key) + r'\\"?:\\?"([^"\\]*)', block)
    if not m:
        return ''
    return _unescape(m.group(1))


def _parse_records(html):
    items = []
    seen = set()
    parts = html.split('\\"video\\":{')
    for block in parts[1:]:
        end = block.find('\\"},\\"')
        if end >= 0:
            block = block[:end]
        vid = _field(block, 'id')
        if not vid or vid in seen:
            continue
        slug = _field(block, 'slug')
        title = _field(block, 'titleZh')
        if not title:
            continue
        cover = _field(block, 'coverUrl')
        secs = _field(block, 'duration')
        seen.add(vid)
        if slug:
            url = '%s/video/%s/%s' % (BASE, vid, slug)
        else:
            url = '%s/video/%s/' % (BASE, vid)
        items.append({
            'vod_id': url,
            'vod_name': title[:90],
            'vod_pic': cover,
            'vod_remarks': _fmt_duration(secs),
        })
    if not items:
        urls = re.findall(r'"item":"(https://51xz\.vip/video/[^"]+)"', html)
        names = re.findall(r'"name":"([^"]+)"', html)
        for i, url in enumerate(urls):
            if url in seen:
                continue
            seen.add(url)
            title = _unescape(names[i + 1]) if i + 1 < len(names) else ''
            if not title:
                continue
            items.append({'vod_id': url, 'vod_name': title[:90], 'vod_pic': '', 'vod_remarks': ''})
    return items


def _catalog_url(tid, pg):
    if tid == 'home':
        return BASE
    name = tid[2:] if tid.startswith('m:') else tid
    enc = urllib.parse.quote(name)
    if pg <= 1:
        return '%s/m/%s' % (BASE, enc)
    return '%s/m/%s?page=%d' % (BASE, enc, pg)


def _meta_content(html, attr, key):
    marker = '%s="%s"' % (attr, key)
    p = html.find(marker)
    if p < 0:
        return ''
    after = html[p:]
    c = after.find('content="')
    if c < 0:
        return ''
    s = c + 9
    e = after.find('"', s)
    if e < 0:
        return ''
    return _unescape(after[s:e])


def _ld_field(html, key):
    marker = '"%s":' % key
    p = html.find(marker)
    if p < 0:
        return ''
    rest = html[p + len(marker):].lstrip()
    if not rest.startswith('"'):
        return ''
    rest = rest[1:]
    e = rest.find('"')
    if e < 0:
        return ''
    return _unescape(rest[:e])


def _extract_m3u8(html):
    first = ''
    for m in re.finditer(r'https?://[^\s"\\]+\.m3u8', html):
        u = m.group(0)
        if not first:
            first = u
        if 'xvideoapi' in u:
            return u
    return first


def _norm_id(ids):
    if isinstance(ids, (list, tuple)):
        return str(ids[0]) if ids else ''
    return str(ids or '')


def _norm_pg(pg):
    try:
        pg = int(pg)
    except Exception:
        pg = 1
    return pg if pg >= 1 else 1


class Spider(BaseSpider):

    def getName(self):
        return '51X'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=''):
        cats = [{'type_id': tid, 'type_name': name} for tid, name in CATS]
        html = _http_get(BASE, referer=BASE + '/')
        items = _parse_records(html)
        return {'class': cats, 'filters': {}, 'list': items}

    def homeVideoContent(self):
        html = _http_get(BASE, referer=BASE + '/')
        items = _parse_records(html)
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        tid = _norm_id(tid)
        if tid == 'home' and pg > 1:
            return {'list': [], 'page': pg, 'pagecount': pg, 'total': 0}
        html = _http_get(_catalog_url(tid, pg), referer=BASE + '/')
        items = _parse_records(html)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        raw = _norm_id(ids)
        html = _http_get(raw, referer=BASE + '/')
        if not html:
            return {'list': []}
        title = _meta_content(html, 'property', 'og:title')
        title = title[:-len(' · 51X')].strip() if title.endswith(' · 51X') else title
        if not title:
            return {'list': []}
        cover = _meta_content(html, 'property', 'og:image')
        desc = _ld_field(html, 'description')
        secs = _iso_seconds(_ld_field(html, 'duration'))
        if secs > 0 and desc:
            synopsis = '%s\n时长：%s' % (desc, _fmt_duration(secs))
        elif secs > 0:
            synopsis = '时长：' + _fmt_duration(secs)
        else:
            synopsis = desc[:400]
        stream = _extract_m3u8(html)
        ep = stream if stream else raw
        return {'list': [{
            'vod_id': raw,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': _fmt_duration(secs),
            'vod_year': '',
            'vod_area': '',
            'vod_content': synopsis[:400],
            'type_name': '',
            'vod_tag': '',
            'vod_play_from': '在线播放',
            'vod_play_url': '正片$' + ep,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        url = '%s/search?q=%s' % (BASE, urllib.parse.quote(str(key or '').strip()))
        html = _http_get(url, referer=BASE + '/')
        items = _parse_records(html)[:60]
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        if '.m3u8' in raw:
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        page_url = raw
        html = _http_get(page_url, referer=BASE + '/')
        url = _extract_m3u8(html)
        if not url:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        header['Referer'] = page_url
        return {'parse': 0, 'playUrl': url, 'url': url, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', b'', {}]

    def isVideoFormat(self, url):
        u = (url or '').lower()
        return u.endswith('.m3u8') or u.endswith('.mp4') or '.m3u8?' in u or '.mp4?' in u

    def manualVideoCheck(self):
        return False

    def action(self, action, params=None):
        return None
