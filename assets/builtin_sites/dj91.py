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


BASE = 'https://app.91dju.cyou'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
AES_KEY = b'a9yX32LpQvUt7wBc'
AES_IV = b'N7cPk2Bv38hWqFzM'

CATS = [
    ('2041', 'AI短剧'),
    ('2042', 'AI漫剧'),
    ('2034', '国产原创'),
    ('2035', '吃瓜爆料'),
    ('2037', '91探花'),
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
    h = {'User-Agent': UA, 'Accept': 'application/json, text/plain, */*', 'Accept-Language': 'zh-CN,zh;q=0.9', 'Accept-Encoding': 'gzip, deflate'}
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


def _api(path):
    txt = _http_get(BASE + '/api' + path, referer=BASE + '/')
    if not txt:
        return {}
    try:
        obj = json.loads(txt)
    except Exception:
        return {}
    if isinstance(obj, dict) and obj.get('cipher'):
        try:
            raw = base64.b64decode(obj['cipher'])
            pt = _aes_cbc_decrypt(raw, AES_KEY, AES_IV)
            obj = json.loads(pt.decode('utf-8', 'replace'))
        except Exception:
            return {}
    if not isinstance(obj, dict):
        return {}
    return obj


def _fix_url(u):
    if not u:
        return ''
    u = _html.unescape(u)
    u = u.replace('\\u0026', '&').replace('\\u002F', '/').replace('\\/', '/')
    if u.startswith('//'):
        return 'https:' + u
    return u


def _str(v):
    if v is None:
        return ''
    return str(v)


def _parse_items(body):
    out = []
    data = body.get('data') if isinstance(body, dict) else None
    lst = data.get('list') if isinstance(data, dict) else None
    for it in lst or []:
        if not isinstance(it, dict):
            continue
        vid = _str(it.get('id'))
        title = it.get('title') or ''
        if not vid or not title:
            continue
        out.append({
            'vod_id': vid,
            'vod_name': title,
            'vod_pic': _fix_url(it.get('cover_url') or ''),
            'vod_remarks': '',
        })
    return out


def _parse_episodes(play_url, series_id):
    eps = []
    for seg in (play_url or '').split('#'):
        seg = seg.strip()
        if not seg or '$' not in seg:
            continue
        name, url = seg.split('$', 1)
        name = name.strip()
        if name.startswith('http://localhost:8080/'):
            name = name[len('http://localhost:8080/'):]
        url = url.strip()
        if not name or not url:
            continue
        eps.append('%s$dj91:%s' % (name, url))
    return eps


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
        return '91短剧'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cats(self):
        body = _api('/config')
        data = body.get('data') if isinstance(body, dict) else None
        ids = []
        if isinstance(data, dict):
            for field in ('home_rec_cat_id', 'core_category_ids'):
                raw = data.get(field) or ''
                ids += [p.strip() for p in str(raw).split(',') if p.strip()]
        if ids:
            batch = _api('/categories/batch/%s' % ','.join(ids))
            bdata = batch.get('data') if isinstance(batch, dict) else None
            lst = None
            if isinstance(bdata, dict):
                lst = bdata.get('list')
            elif isinstance(bdata, list):
                lst = bdata
            out = []
            for it in lst or []:
                if not isinstance(it, dict):
                    continue
                if it.get('module') != 'video':
                    continue
                cid = _str(it.get('id'))
                name = it.get('name') or ''
                if cid and name:
                    out.append((cid, name))
            if out:
                return out
        return list(CATS)

    def _catalog(self, tid, pg):
        path = '/videos?category_id=%s&page=%s&ps=28' % (urllib.parse.quote(tid), pg)
        body = _api(path)
        items = _parse_items(body)
        data = body.get('data') if isinstance(body, dict) else None
        pages = 0
        if isinstance(data, dict):
            try:
                pages = int(data.get('pages') or 0)
            except Exception:
                pages = 0
        return items, pages

    def homeContent(self, filter=''):
        cats = self._cats()
        items = []
        if cats:
            items, _ = self._catalog(cats[0][0], 1)
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in cats],
            'list': items,
        }

    def homeVideoContent(self):
        cats = self._cats()
        items = []
        if cats:
            items, _ = self._catalog(cats[0][0], 1)
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        items, pages = self._catalog(tid, pg)
        return {'list': items, 'page': pg, 'pagecount': pages, 'total': 0}

    def detailContent(self, ids):
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        body = _api('/movie?id=%s' % urllib.parse.quote(nid))
        data = body.get('data') if isinstance(body, dict) else None
        info = data.get('info') if isinstance(data, dict) else None
        if not isinstance(info, dict):
            return {'list': []}
        title = info.get('title') or ''
        eps = _parse_episodes(info.get('play_url') or '', nid)
        if not title or not eps:
            return {'list': []}
        cover = _fix_url(info.get('cover_url') or '')
        cat = info.get('category') or ''
        hits = info.get('hits')
        parts = []
        if cat:
            parts.append('分类：' + cat)
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
            'type_name': cat,
            'vod_tag': cat,
            'vod_play_from': '在线播放',
            'vod_play_url': '#'.join(eps),
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        path = '/videos?kw=%s&page=1&ps=13' % urllib.parse.quote(key or '')
        body = _api(path)
        items = _parse_items(body)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        if raw.startswith('dj91:'):
            raw = raw[5:]
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        m3u8 = ''
        if raw.startswith('http'):
            path = '/parse_video?url=%s' % urllib.parse.quote(raw, safe='')
            body = _api(path)
            data = body.get('data') if isinstance(body, dict) else None
            if isinstance(data, dict):
                m3u8 = data.get('m3u8_url') or ''
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
