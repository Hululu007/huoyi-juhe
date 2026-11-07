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

UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
API_KEY = b'a9yX32LpQvUt7wBc'
API_IV = b'N7cPk2Bv38hWqFzM'

CATS = [
    (1997, 'Ai短剧'),
    (1661, 'SM重味'),
    (1660, 'AV明星'),
    (1659, '强奸乱伦'),
    (1658, '制服诱惑'),
    (1657, '人妻系列'),
    (1656, '中文字幕'),
    (1655, '伦理影片'),
    (1654, '自拍偷拍'),
    (1653, '成人动漫'),
    (1652, '欧美劲爆'),
    (1651, '国产主播'),
    (1650, '日韩无码'),
    (1649, '香港伦理'),
    (1648, '韩国伦理'),
    (1647, '邻家人妻'),
    (1646, '长腿丝袜'),
    (1645, '国模私拍'),
    (1644, '欧美情色'),
    (1643, '成人动漫'),
    (1642, '网红主播'),
    (1641, 'AV明星'),
    (1640, '日本无码'),
    (1639, '国产情色'),
    (1634, '中文字幕'),
]

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
    h = {'User-Agent': UA, 'Accept': 'application/json', 'Accept-Language': 'zh-CN,zh;q=0.9', 'Accept-Encoding': 'gzip, deflate'}
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


def _api_host():
    chars = string.ascii_letters + string.digits
    sub = ''.join(random.choice(chars) for _ in range(6))
    return 'https://%s.javzw.cyou' % sub


def _decrypt_cipher(cipher_b64):
    raw = base64.b64decode(cipher_b64.strip())
    pt = _aes_cbc_decrypt(raw, API_KEY, API_IV)
    return json.loads(pt.decode('utf-8', 'replace'))


def _api_get(path):
    url = _api_host() + path
    last = ''
    for _ in range(3):
        txt = _http_get(url)
        if not txt:
            time.sleep(1)
            continue
        try:
            body = json.loads(txt)
        except Exception:
            last = 'bad json'
            time.sleep(1)
            continue
        if isinstance(body, dict) and body.get('cipher'):
            try:
                v = _decrypt_cipher(body['cipher'])
            except Exception as e:
                last = str(e)
                time.sleep(1)
                continue
            if isinstance(v, dict) and 'data' in v:
                return v['data']
            return v
        if isinstance(body, dict):
            if body.get('code') not in (None, 0):
                last = str(body.get('msg') or body.get('code'))
                time.sleep(1)
                continue
            if 'data' in body:
                return body['data']
            return body
        return body
    return {}


def _parse_categories(data):
    out = []
    lst = data.get('list') if isinstance(data, dict) else None
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


def _parse_videos(data):
    items = []
    total_pages = 1
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
                items.append({
                    'vod_id': str(vid),
                    'vod_name': title,
                    'vod_pic': v.get('cover_url') or '',
                    'vod_remarks': v.get('category') or '',
                })
        try:
            pg = int(data.get('page') or 1)
        except Exception:
            pg = 1
        try:
            total_pages = int(data.get('pages') or 1)
        except Exception:
            total_pages = 1
        return items, pg < total_pages
    return items, False


def _parse_play_list(play_url):
    out = []
    for part in (play_url or '').split('#'):
        part = part.strip()
        if not part:
            continue
        if '$' in part:
            label, url = part.split('$', 1)
            url = url.strip()
            if url.startswith('http'):
                label = label.rsplit('/', 1)[-1].strip()
                out.append((label, url))
        elif part.startswith('http'):
            out.append(('第%02d集' % (len(out) + 1), part))
    return out


class Spider(BaseSpider):
    def getName(self):
        return 'Jav中文'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cats(self):
        try:
            data = _api_get('/api/categories')
            lst = _parse_categories(data)
            if lst:
                return lst
        except Exception:
            pass
        return [(str(cid), name) for cid, name in CATS]

    def _catalog(self, tid, pg):
        data = _api_get('/api/videos?category_id=%s&page=%d' % (tid, pg))
        items, _ = _parse_videos(data)
        return items

    def homeContent(self, filter=''):
        cats = self._cats()
        items = self._catalog(cats[0][0], 1) if cats else []
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in cats],
            'list': items,
        }

    def homeVideoContent(self):
        cats = self._cats()
        items = self._catalog(cats[0][0], 1) if cats else []
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        items = self._catalog(_norm_id(tid), pg)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        nid = _norm_id(ids).strip().strip('/')
        if not nid:
            return {'list': []}
        data = _api_get('/api/movie?id=%s' % urllib.parse.quote(nid))
        info = data.get('info') if isinstance(data, dict) else None
        if not isinstance(info, dict):
            info = data if isinstance(data, dict) else {}
        title = info.get('title') or ''
        if not title:
            return {'list': []}
        cover = info.get('cover_url') or ''
        genre = info.get('category') or ''
        eps = _parse_play_list(info.get('play_url') or '')
        if not eps:
            return {'list': []}
        play_url = '#'.join('%s$%s' % (label, url) for label, url in eps)
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': genre,
            'vod_year': '',
            'vod_area': '',
            'vod_content': '',
            'type_name': genre,
            'vod_tag': genre,
            'vod_play_from': '在线播放',
            'vod_play_url': play_url,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        enc = urllib.parse.quote(str(key or '').strip(), safe='')
        data = _api_get('/api/videos?kw=%s&page=1' % enc)
        items, _ = _parse_videos(data)
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        header = {'User-Agent': UA}
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
