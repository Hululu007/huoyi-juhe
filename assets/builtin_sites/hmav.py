import gzip
import html as _html
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

BASES = ['https://5.hmav7911.cc:8888', 'https://5.hmav7912.cc:8888', 'https://5.hmav7913.cc:8888']
BASE = BASES[0]
_BASE_STATE = {'base': '', 'ts': 0}
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

CATEGORIES = [
    ('1', '大陆'),
    ('2', '日韩'),
    ('3', '欧美'),
    ('4', '动漫'),
    ('5', '综艺'),
    ('6', '国产传媒'),
    ('7', '偷拍自拍'),
    ('35', '绿帽偷情'),
    ('37', '强奸迷奸'),
    ('10', '日韩无码'),
    ('11', '中文字幕'),
    ('12', '日韩杂类'),
    ('19', '欧美无码'),
    ('20', '黑白专区'),
    ('23', '少女动漫'),
    ('30', '网爆黑料'),
    ('28', '其他综艺'),
]

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

CACHE = {}
CACHE_TTL = 180

RE_ITEM = re.compile(
    r'<a\s+href="(/view/[0-9a-zA-Z]+)"\s+class="vod-img">([\s\S]{0,1200}?)</a>\s*'
    r'<a\s+href="/view/([0-9a-zA-Z]+)"\s+class="vod-title">([\s\S]*?)</a>',
    re.S)
RE_IMG = re.compile(r'data-original="([^"]+)"')
RE_DUR = re.compile(r'secondsToHMS\((\d+)\)')
RE_M3U8 = re.compile(r'https?://[^\s"\'<>]+?\.m3u8[^\s"\'<>]*')
RE_H1 = re.compile(r"<h1[^>]*>([\s\S]*?)</h1>", re.S)
RE_DATE = re.compile(r'formatDateString\((\d+)\)')
RE_TAGS = re.compile(r'href="/tag/([^"]+)"')
RE_CONTENT = re.compile(r'<div class="vod-content">([\s\S]*?)</div>')


def _now():
    return time.time()


def _http_get(url, referer=None, timeout=25):
    hdr = {
        'User-Agent': UA,
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
        'Accept-Encoding': 'gzip, deflate',
        'Connection': 'keep-alive',
    }
    if referer:
        hdr['Referer'] = referer
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
            for cs in ('utf-8', 'gbk', 'gb18030'):
                try:
                    return data.decode(cs)
                except Exception:
                    continue
            return data.decode('utf-8', 'replace')
        except Exception:
            if attempt < 2:
                try:
                    time.sleep(1)
                except Exception:
                    pass
    return None


def _unwrap(raw):
    if not raw:
        return ''
    m = re.search(r'decodeURIComponent\("([\s\S]*?)"\)', raw)
    if m:
        try:
            return urllib.parse.unquote(m.group(1))
        except Exception:
            return raw
    return raw


def _ensure_base():
    global BASE
    now = _now()
    if _BASE_STATE['base'] and now - _BASE_STATE['ts'] < 600:
        BASE = _BASE_STATE['base']
        return BASE
    for cand in BASES:
        try:
            body = _unwrap(_http_get(cand + '/', referer=cand + '/'))
        except Exception:
            body = ''
        if body and 'vod-img' in body:
            _BASE_STATE['base'] = cand
            _BASE_STATE['ts'] = now
            BASE = cand
            return cand
    _BASE_STATE['base'] = BASES[0]
    _BASE_STATE['ts'] = now
    BASE = BASES[0]
    return BASE


def _rebase(url):
    try:
        parts = urllib.parse.urlsplit(url)
        base_parts = urllib.parse.urlsplit(BASE)
        if parts.netloc and parts.netloc != base_parts.netloc:
            url = urllib.parse.urlunsplit((base_parts.scheme, base_parts.netloc, parts.path, parts.query, parts.fragment))
    except Exception:
        pass
    return url


def _txt(s):
    if not s:
        return ''
    s = re.sub(r'<[^>]+>', ' ', s)
    s = _html.unescape(s)
    return re.sub(r'\s+', ' ', s).strip()


def _fmt_dur(sec):
    try:
        sec = int(sec)
    except Exception:
        return ''
    if sec <= 0:
        return ''
    if sec >= 3600:
        return '%d:%02d:%02d' % (sec // 3600, (sec % 3600) // 60, sec % 60)
    return '%d:%02d' % (sec // 60, sec % 60)


def _page(url):
    _ensure_base()
    url = _rebase(url)
    ck = 'P:' + url
    v = CACHE.get(ck)
    if v and _now() - v[0] < CACHE_TTL:
        return v[1]
    body = _unwrap(_http_get(url, referer=BASE + '/'))
    if body and len(body) > 300:
        if len(CACHE) > 400:
            CACHE.clear()
        CACHE[ck] = (_now(), body)
    return body


def _parse_list(body):
    out = []
    if not body:
        return out
    seen = set()
    for m in RE_ITEM.finditer(body):
        vid = m.group(3)
        if vid in seen:
            continue
        seg = m.group(2)
        name = _txt(m.group(4))
        if not name:
            continue
        seen.add(vid)
        pic = ''
        im = RE_IMG.search(seg)
        if im:
            pic = im.group(1)
            if pic.startswith('//'):
                pic = 'https:' + pic
        dur = ''
        dm = RE_DUR.search(seg)
        if dm:
            dur = _fmt_dur(dm.group(1))
        out.append({'vod_id': vid, 'vod_name': name, 'vod_pic': pic, 'vod_remarks': dur})
    return out


def _total_pages(body):
    m = re.search(r'var\s+total\s*=\s*parseInt\((\d+)\)', body or '')
    return int(m.group(1)) if m else 1


def _list_merged(kind, cid_or_kw, pg, merge):
    items = []
    seen = set()
    total = 1
    start = (pg - 1) * merge + 1
    for i in range(merge):
        p = start + i
        if kind == 'category':
            url = '%s/category/%s/' % (BASE, cid_or_kw) if p == 1 else '%s/category/%s/%d/' % (BASE, cid_or_kw, p)
        else:
            url = '%s/search/%s/' % (BASE, cid_or_kw) if p == 1 else '%s/search/%s/%d/' % (BASE, cid_or_kw, p)
        body = _page(url)
        if not body:
            break
        if i == 0:
            total = _total_pages(body)
        got = _parse_list(body)
        if not got:
            break
        for it in got:
            if it['vod_id'] not in seen:
                seen.add(it['vod_id'])
                items.append(it)
        if p >= total:
            break
    pagecount = max(1, (total + merge - 1) // merge)
    return items, pagecount, total


def _detail(vod_id):
    body = _page('%s/view/%s' % (BASE, vod_id))
    d = {'vod_id': vod_id, 'vod_name': '', 'vod_pic': '', 'vod_content': '', 'vod_year': '', 'vod_remarks': '', 'type_name': '', 'm3u8': ''}
    if not body:
        return d
    m = RE_H1.search(body)
    if m:
        d['vod_name'] = _txt(m.group(1))
    ms = RE_M3U8.findall(body)
    if ms:
        cand = [u for u in ms if '.m3u8' in u]
        d['m3u8'] = (cand[0] if cand else ms[0]).replace('&amp;', '&')
    dm = RE_DATE.search(body)
    if dm:
        try:
            ts = int(dm.group(1))
            d['vod_year'] = time.strftime('%Y', time.localtime(ts))
            d['vod_remarks'] = time.strftime('%Y-%m-%d', time.localtime(ts))
        except Exception:
            pass
    cm = RE_CONTENT.search(body)
    if cm:
        d['vod_content'] = _txt(cm.group(1))
    tags = []
    for t in RE_TAGS.findall(body):
        t = urllib.parse.unquote(t)
        if t and t not in tags:
            tags.append(t)
    if tags:
        d['type_name'] = ' / '.join(tags[:3])
    if not d['vod_content'] and tags:
        d['vod_content'] = '标签：' + '、'.join(tags)
    return d


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


class Spider(BaseSpider):

    def getName(self):
        return '🔞hmav'

    def getDependence(self):
        return []

    def init(self, extend=None):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=False):
        return {'class': [{'type_id': tid, 'type_name': name} for tid, name in CATEGORIES], 'filters': {}}

    def homeVideoContent(self):
        items = _parse_list(_page(BASE + '/'))
        if not items:
            items, _, _ = _list_merged('category', '30', 1, 1)
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        tid = _norm_id(tid)
        pg = _norm_pg(pg)
        if pg < 1:
            pg = 1
        items, pagecount, _ = _list_merged('category', tid, pg, 4)
        return {'list': items, 'page': pg, 'pagecount': pagecount, 'total': 0}

    def detailContent(self, ids):
        vid = _norm_id(ids)
        m = re.search(r'([0-9a-fA-F]{16})', vid)
        if m:
            vid = m.group(1)
        d = _detail(vid)
        play_url = '正片$hmav:%s' % vid if d['m3u8'] else ''
        return {'list': [{
            'vod_id': vid,
            'vod_name': d['vod_name'] or ('视频 ' + vid),
            'vod_pic': d['vod_pic'],
            'vod_actor': '',
            'vod_remarks': d['vod_remarks'],
            'vod_year': d['vod_year'],
            'vod_area': '',
            'vod_content': d['vod_content'],
            'type_name': d['type_name'],
            'vod_play_from': '河马AV',
            'vod_play_url': play_url,
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        if pg < 1:
            pg = 1
        kw = urllib.parse.quote(str(key).strip())
        items, pagecount, _ = _list_merged('search', kw, pg, 3)
        return {'list': items, 'page': pg, 'pagecount': pagecount, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        url = raw
        if '$' in raw:
            url = raw.split('$', 1)[1]
        if url.startswith('hmav:'):
            vid = url.split(':', 1)[1].strip()
            d = _detail(vid)
            m3u8 = d.get('m3u8', '')
            if m3u8:
                return {'parse': 0, 'playUrl': m3u8, 'url': m3u8, 'header': {'User-Agent': UA, 'Referer': BASE + '/'}}
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        if url.startswith('http'):
            return {'parse': 0, 'playUrl': url, 'url': url, 'header': {'User-Agent': UA, 'Referer': BASE + '/'}}
        return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}

    def localProxy(self, param):
        return [404, 'text/plain', b'', {}]

    def isVideoFormat(self, url):
        return False

    def manualVideoCheck(self):
        return True

    def action(self, action, params=None):
        return {'code': 0, 'msg': 'ok'}
