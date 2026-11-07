try:
    from base.spider import BaseSpider
except Exception:
    try:
        from base import BaseSpider
    except Exception:
        class BaseSpider:
            pass


import base64
import gzip
import html as _html
import json
import random
import re
import ssl
import string
import time
import urllib.error
import urllib.parse
import urllib.request

try:
    import requests
    _HAS_REQ = True
except Exception:
    _HAS_REQ = False

ENTRY = 'https://luoliai.cc/?from=yng'
SUFFIX_FALLBACK = 'luoliai1.cyou'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
AES_KEY = b'a9yX32LpQvUt7wBc'
AES_IV = b'N7cPk2Bv38hWqFzM'

CATS = [
    ('2058', 'Ai视频'),
    ('2057', 'Ai真人剧'),
    ('2056', 'AI漫剧'),
    ('2055', 'Ai魔改'),
    ('2054', 'AI短剧'),
    ('2053', 'Ai换脸'),
]

_BASE_CACHE = {'base': '', 'ts': 0}

def _gf_mul(a, b):
    p = 0
    for _ in range(8):
        if b & 1:
            p ^= a
        hi = a & 0x80
        a = (a << 1) & 0xFF
        if hi:
            a ^= 0x1B
        b >>= 1
    return p


def _gf_pow(a, n):
    r = 1
    while n:
        if n & 1:
            r = _gf_mul(r, a)
        a = _gf_mul(a, a)
        n >>= 1
    return r


def _build_sboxes():
    sbox = []
    for i in range(256):
        inv = 0 if i == 0 else _gf_pow(i, 254)
        s = inv
        for kk in (1, 2, 3, 4):
            s ^= ((inv << kk) | (inv >> (8 - kk))) & 0xFF
        sbox.append((s ^ 0x63) & 0xFF)
    inv_sbox = [0] * 256
    for i, v in enumerate(sbox):
        inv_sbox[v] = i
    return sbox, inv_sbox


_SBOX, _INV_SBOX = _build_sboxes()
_RCON = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36, 0x6C, 0xD8, 0xAB, 0x4D]


def _expand_key(key):
    nk = len(key) // 4
    nr = nk + 6
    w = list(key)
    for i in range(nk, 4 * (nr + 1)):
        t = w[4 * (i - 1):4 * i]
        if i % nk == 0:
            t = [_SBOX[t[1]] ^ _RCON[i // nk - 1], _SBOX[t[2]], _SBOX[t[3]], _SBOX[t[0]]]
        elif nk > 6 and i % nk == 4:
            t = [_SBOX[b] for b in t]
        base = 4 * (i - nk)
        w += [w[base + j] ^ t[j] for j in range(4)]
    return w, nr


def _decrypt_block(block, rk, nr):
    s = [block[r + 4 * c] for c in range(4) for r in range(4)]

    def add_rk(rnd):
        for c in range(4):
            for r in range(4):
                s[r + 4 * c] ^= rk[16 * rnd + 4 * c + r]

    def inv_shift():
        old = s[:]
        for r in range(4):
            for c in range(4):
                s[r + 4 * c] = old[r + 4 * ((c - r) % 4)]

    def inv_sub():
        for i in range(16):
            s[i] = _INV_SBOX[s[i]]

    def inv_mix():
        for c in range(4):
            i = 4 * c
            a0, a1, a2, a3 = s[i], s[i + 1], s[i + 2], s[i + 3]
            s[i] = _gf_mul(a0, 14) ^ _gf_mul(a1, 11) ^ _gf_mul(a2, 13) ^ _gf_mul(a3, 9)
            s[i + 1] = _gf_mul(a0, 9) ^ _gf_mul(a1, 14) ^ _gf_mul(a2, 11) ^ _gf_mul(a3, 13)
            s[i + 2] = _gf_mul(a0, 13) ^ _gf_mul(a1, 9) ^ _gf_mul(a2, 14) ^ _gf_mul(a3, 11)
            s[i + 3] = _gf_mul(a0, 11) ^ _gf_mul(a1, 13) ^ _gf_mul(a2, 9) ^ _gf_mul(a3, 14)

    add_rk(nr)
    for rnd in range(nr - 1, 0, -1):
        inv_shift()
        inv_sub()
        add_rk(rnd)
        inv_mix()
    inv_shift()
    inv_sub()
    add_rk(0)
    return bytes(s[r + 4 * c] for c in range(4) for r in range(4))


def _aes_cbc_decrypt(ct, key, iv):
    try:
        from Crypto.Cipher import AES as _AES
        pt = _AES.new(key, _AES.MODE_CBC, iv).decrypt(ct)
    except Exception:
        rk, nr = _expand_key(key)
        out = bytearray()
        prev = iv
        for off in range(0, len(ct), 16):
            blk = ct[off:off + 16]
            if len(blk) < 16:
                break
            dec = _decrypt_block(list(blk), rk, nr)
            out += bytes(b ^ p for b, p in zip(dec, prev))
            prev = blk
        pt = bytes(out)
    if pt:
        n = pt[-1]
        if 1 <= n <= 16 and len(pt) >= n and pt[-n:] == bytes([n]) * n:
            pt = pt[:-n]
    return pt



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


def _clean(t):
    if not t:
        return ''
    t = re.sub(r'<[^>]+>', ' ', t)
    return _html.unescape(re.sub(r'\s+', ' ', t)).strip()


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


def _rand_sub():
    chars = string.ascii_letters + string.digits
    return ''.join(random.choice(chars) for _ in range(6))


def _resolve_base():
    now = time.time()
    if _BASE_CACHE['base'] and now - _BASE_CACHE['ts'] < 600:
        return _BASE_CACHE['base']
    suffix = SUFFIX_FALLBACK
    try:
        html = _http_get(ENTRY)
        m = re.search(r'randomSub \+ "\.([A-Za-z0-9.\-]+\.cyou)/', html or '')
        if m:
            suffix = m.group(1)
    except Exception:
        pass
    base = 'https://%s.%s' % (_rand_sub(), suffix)
    _BASE_CACHE['base'] = base
    _BASE_CACHE['ts'] = now
    return base


def _api_json(path):
    base = _resolve_base()
    url = base + '/api' + path
    txt = _http_get(url)
    if not txt:
        return {}
    try:
        body = json.loads(txt)
    except Exception:
        return {}
    if isinstance(body, dict) and body.get('cipher'):
        try:
            raw = base64.b64decode(body['cipher'])
            pt = _aes_cbc_decrypt(raw, AES_KEY, AES_IV)
            body = json.loads(pt.decode('utf-8', 'replace'))
        except Exception:
            return {}
    if not isinstance(body, dict) or body.get('code') != 0:
        return {}
    return body


def _fix_url(raw, base):
    u = (raw or '').strip()
    if not u:
        return ''
    if u.startswith('//'):
        return 'https:' + u
    if u.startswith('/'):
        return base + u
    if '://' in u:
        scheme, rest = u.split('://', 1)
        if '/' in rest:
            host, path = rest.split('/', 1)
            cleaned = []
            prev_slash = False
            for ch in path:
                if ch == '/':
                    if prev_slash:
                        continue
                    prev_slash = True
                else:
                    prev_slash = False
                cleaned.append(ch)
            return '%s://%s/%s' % (scheme, host, ''.join(cleaned).lstrip('/'))
    return u


def _parse_categories(body):
    out = []
    data = body.get('data') if isinstance(body, dict) else None
    if isinstance(data, dict):
        lst = data.get('list')
        if isinstance(lst, list):
            for c in lst:
                if not isinstance(c, dict):
                    continue
                if c.get('module') != 'video':
                    continue
                cid = c.get('id')
                name = c.get('name') or ''
                if cid is None or not name:
                    continue
                out.append((str(cid), name))
    return out


def _parse_items(body, base):
    out = []
    data = body.get('data') if isinstance(body, dict) else None
    if isinstance(data, dict):
        lst = data.get('list')
        if isinstance(lst, list):
            for v in lst:
                if not isinstance(v, dict):
                    continue
                vid = v.get('id')
                title = v.get('title') or ''
                if vid is None or not title:
                    continue
                out.append({
                    'vod_id': str(vid),
                    'vod_name': title,
                    'vod_pic': _fix_url(v.get('cover_url') or '', base),
                    'vod_remarks': '',
                })
    return out


def _list_count(body):
    data = body.get('data') if isinstance(body, dict) else None
    if isinstance(data, dict):
        for k in ('count', 'total'):
            try:
                return int(data.get(k) or 0)
            except Exception:
                continue
    return 0


def _parse_episodes(play_url, series_id):
    eps = []
    for part in (play_url or '').split('#'):
        part = part.strip()
        if not part or '$' not in part:
            continue
        name, url = part.split('$', 1)
        url = url.strip()
        if url.startswith('http'):
            name = name.strip().rsplit('/', 1)[-1]
            eps.append('%s$%s' % (name, url))
    return eps


def _parse_player_data(html):
    m = re.search(r'player_data=\{"[^}]*"url":"([^"]+)"[^}]*"from":"([^"]+)"', html or '')
    if not m:
        return None
    return m.group(1), m.group(2)


def _parse_direct_m3u8(html):
    m = re.search(r'https?://[^\s"\']+\.m3u8[^\s"\']*', html or '')
    if not m:
        return ''
    return m.group(0).replace('\\u0026', '&').replace('\\/', '/')


def _page_origin(url):
    if '://' in url:
        scheme, rest = url.split('://', 1)
        host = rest.split('/')[0]
        return '%s://%s' % (scheme, host)
    return url


class Spider(BaseSpider):
    def getName(self):
        return '萝莉AI短剧'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cats(self):
        try:
            body = _api_json('/categories')
            lst = _parse_categories(body)
            if lst:
                return lst
        except Exception:
            pass
        return list(CATS)

    def homeContent(self, filter=''):
        cats = self._cats()
        items = []
        if cats:
            body = _api_json('/categories/videos?ids=%s&page=1' % cats[0][0])
            items = _parse_items(body, _resolve_base())
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in cats],
            'list': items,
        }

    def homeVideoContent(self):
        cats = self._cats()
        items = []
        if cats:
            body = _api_json('/categories/videos?ids=%s&page=1' % cats[0][0])
            items = _parse_items(body, _resolve_base())
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        body = _api_json('/categories/videos?ids=%s&page=%d' % (_norm_id(tid), pg))
        items = _parse_items(body, _resolve_base())
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        body = _api_json('/movie?id=%s' % urllib.parse.quote(nid))
        data = body.get('data') if isinstance(body, dict) else None
        info = data.get('info') if isinstance(data, dict) else None
        if not isinstance(info, dict):
            return {'list': []}
        title = info.get('title') or ''
        play_url = info.get('play_url') or ''
        if not title or not play_url:
            return {'list': []}
        eps = _parse_episodes(play_url, nid)
        if not eps:
            return {'list': []}
        base = _resolve_base()
        cover = _fix_url(info.get('cover_url') or '', base)
        genre = info.get('category') or ''
        hits = info.get('hits')
        parts = []
        if genre:
            parts.append('分类：' + genre)
        if hits:
            parts.append('播放：' + str(hits))
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': str(hits or ''),
            'vod_year': '',
            'vod_area': '',
            'vod_content': '\n'.join(parts),
            'type_name': genre,
            'vod_tag': genre,
            'vod_play_from': '在线播放',
            'vod_play_url': '#'.join(eps),
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        body = _api_json('/videos?kw=%s&page=1' % urllib.parse.quote(str(key or '')))
        items = _parse_items(body, _resolve_base())
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        header = {'User-Agent': UA}
        if not raw.startswith('http'):
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        page_url = raw.split('$')[-1].strip()
        html = _http_get(page_url)
        if not html:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        direct = _parse_direct_m3u8(html)
        if direct:
            return {'parse': 0, 'playUrl': direct, 'url': direct, 'header': header}
        pd = _parse_player_data(html)
        if not pd:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        code, frm = pd
        if frm != 'huangguo':
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        parts = code.split('|')
        if len(parts) < 2 or not parts[0] or not parts[1]:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        origin = _page_origin(page_url)
        millis = int(time.time() * 1000)
        api = '%s/huangguo.php?ac=play&id=%s&ep=%s&_=%d' % (origin, urllib.parse.quote(parts[0]), urllib.parse.quote(parts[1]), millis)
        txt = _http_get(api, referer=page_url)
        try:
            obj = json.loads(txt or '{}')
        except Exception:
            obj = {}
        if not isinstance(obj, dict) or obj.get('code') != 1:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        proxy = obj.get('url') or ''
        if not proxy.startswith('/hgmedia.php?e='):
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        url = origin + proxy
        header['Referer'] = page_url
        return {'parse': 0, 'playUrl': url, 'url': url, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', '']

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
