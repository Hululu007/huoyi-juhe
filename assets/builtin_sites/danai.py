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


ENTRY = 'https://danai88.cc/?from=yng'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
API_KEY = b'a9yX32LpQvUt7wBc'
API_IV = b'N7cPk2Bv38hWqFzM'
IMG_KEY = b'f5d965df75336270'
IMG_IV = b'97b60394abc2fbe1'
WORKER_URL = 'https://91crdjai.com/static/web/js/plugins/crypto-worker.js'
_BASE_CACHE = {'base': '', 'ts': 0}
_IMG_KEY_CACHE = None

FALLBACK_CATS = [
    ('2012', 'AI成人漫剧'),
    ('2011', 'Ai魔改'),
    ('2010', 'AI成人短剧'),
    ('1908', 'AI短剧'),
    ('1907', '野外露出'),
    ('1906', '女同性恋'),
    ('1905', '变性伪娘'),
    ('1904', '动漫卡通'),
    ('1903', '主奴调教'),
    ('1901', '人妻熟女'),
    ('1899', '欧美激情'),
    ('1897', '韩国三级'),
    ('1895', '强奸乱伦'),
    ('1893', '角色剧情'),
    ('1892', '凌辱快感'),
    ('1890', '多人群交'),
    ('1888', '无码流出'),
    ('1886', '中文字幕'),
    ('1884', '丝袜美腿'),
    ('1882', '制服诱惑'),
    ('1881', '重口性癖'),
    ('1878', 'V R 视角'),
    ('1877', 'A I 换脸'),
    ('1875', '反差母狗'),
    ('1873', '足浴撩妹'),
    ('1871', '港台辣妹'),
    ('1869', '淫妻作乐'),
    ('1867', 'A V 解说'),
    ('1865', '清纯学生'),
    ('1864', '传媒探花'),
    ('1861', '网曝事件'),
    ('1860', '制服丝袜'),
    ('1858', '自拍偷拍'),
    ('1857', '国产乱伦'),
    ('1853', '国产主播'),
    ('1852', '精品推荐'),
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


def _rand_sub():
    chars = string.ascii_letters + string.digits
    return ''.join(random.choice(chars) for _ in range(6))


def _resolve_base():
    now = time.time()
    if _BASE_CACHE['base'] and now - _BASE_CACHE['ts'] < 600:
        return _BASE_CACHE['base']
    suffix = 'danai88.cyou'
    try:
        req = urllib.request.Request(ENTRY, headers={'User-Agent': UA})
        with urllib.request.urlopen(req, timeout=20, context=_ctx()) as resp:
            html = resp.read().decode('utf-8', 'replace')
        m = re.search(r'\.([A-Za-z0-9.\-]+\.cyou)/', html)
        if m:
            suffix = m.group(1)
    except Exception:
        pass
    base = 'https://%s.%s' % (_rand_sub(), suffix)
    _BASE_CACHE['base'] = base
    _BASE_CACHE['ts'] = now
    return base


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
            except http.client.IncompleteRead as ie:
                return ie.partial.decode('utf-8', 'ignore')
        except Exception:
            pass
        time.sleep(1)
    return ''


def _fetch_bytes(url, referer=None, timeout=25):
    h = {'User-Agent': UA}
    if referer:
        h['Referer'] = referer
    for _ in range(3):
        if _HAS_REQ:
            try:
                r = requests.get(url, headers=h, timeout=timeout)
                if r.status_code == 200 and r.content:
                    return r.content
            except Exception:
                pass
        try:
            req = urllib.request.Request(url, headers=h)
            with urllib.request.urlopen(req, timeout=timeout, context=_ctx()) as resp:
                return resp.read()
        except urllib.error.HTTPError:
            return b''
        except Exception:
            pass
        time.sleep(1)
    return b''


def _api(path):
    base = _resolve_base()
    url = base + '/api' + path
    txt = _http_get(url, referer=base + '/')
    if not txt:
        return {}
    try:
        obj = json.loads(txt)
    except Exception:
        return {}
    if isinstance(obj, dict) and obj.get('cipher'):
        try:
            raw = base64.b64decode(obj['cipher'])
            pt = _aes_cbc_decrypt(raw, API_KEY, API_IV)
            obj = json.loads(pt.decode('utf-8', 'replace'))
        except Exception:
            return {}
    if not isinstance(obj, dict) or obj.get('code') != 0:
        return {}
    return obj.get('data') or {}


def _fix_url(u):
    if not u:
        return ''
    u = _html.unescape(u)
    u = u.replace('\\u0026', '&').replace('\\u002F', '/').replace('\\/', '/')
    if u.startswith('//'):
        return 'https:' + u
    return u


def _clean(t):
    if not t:
        return ''
    t = re.sub(r'<[^>]+>', ' ', t)
    return _html.unescape(re.sub(r'\s+', ' ', t)).strip()


def _underscore_bytes(s):
    return bytes(int(x) for x in (s or '').split('_') if x != '')


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
        return '大奶Ai短剧'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cats(self):
        data = _api('/categories')
        lst = data.get('list') if isinstance(data, dict) else None
        out = []
        if lst:
            for c in lst:
                if c.get('module') != 'video':
                    continue
                cid = str(c.get('id') or '')
                name = c.get('name') or ''
                if cid and name:
                    out.append((cid, name))
        return out or list(FALLBACK_CATS)

    def _cards(self, items):
        out = []
        for it in items or []:
            vid = str(it.get('id') or '')
            title = it.get('title') or ''
            if not vid or not title:
                continue
            out.append({
                'vod_id': vid,
                'vod_name': title,
                'vod_pic': self._pic(_fix_url(it.get('cover_url') or '')),
                'vod_remarks': str(it.get('hits') or ''),
            })
        return out

    def _catalog(self, tid, pg):
        data = _api('/categories/videos?ids=%s&page=%s' % (tid, pg))
        if not isinstance(data, dict):
            return [], 0
        total = data.get('count') or data.get('total') or 0
        return self._cards(data.get('list') or []), total

    def _pic(self, url):
        url = url or ''
        if not url:
            return ''
        return 'proxy://do=py&siteKey=danai&u=' + urllib.parse.quote(url, safe='')

    def _img_key_iv(self):
        global _IMG_KEY_CACHE
        if _IMG_KEY_CACHE:
            return _IMG_KEY_CACHE
        key, iv = IMG_KEY, IMG_IV
        try:
            src = _http_get(WORKER_URL, referer='https://91crdjai.com/')
            km = re.search(r'media_key:\s*"([\d_]+)"', src or '')
            im = re.search(r'media_iv:\s*"([\d_]+)"', src or '')
            if km and im:
                k2 = _underscore_bytes(km.group(1))
                v2 = _underscore_bytes(im.group(1))
                if len(k2) == 16 and len(v2) == 16:
                    key, iv = k2, v2
        except Exception:
            pass
        _IMG_KEY_CACHE = (key, iv)
        return _IMG_KEY_CACHE

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
        items, total = self._catalog(tid, pg)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': total}

    def detailContent(self, ids):
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        data = _api('/movie?id=%s' % urllib.parse.quote(nid))
        info = data.get('info') if isinstance(data, dict) else None
        if not info:
            return {'list': []}
        title = info.get('title') or ''
        if not title:
            return {'list': []}
        cover = _fix_url(info.get('cover_url') or '')
        parts = []
        cat = info.get('category') or ''
        if cat:
            parts.append('分类：' + cat)
        hits = info.get('hits')
        if hits:
            parts.append('播放：' + str(hits))
        eps = []
        play_url = info.get('play_url') or ''
        for seg in play_url.split('#'):
            seg = seg.strip()
            if not seg or '$' not in seg:
                continue
            name_part, url_part = seg.split('$', 1)
            url_part = _fix_url(url_part.strip())
            if not url_part.startswith('http'):
                continue
            name = name_part.rsplit('/', 1)[-1].strip() or '正片'
            eps.append('%s$danai:%s' % (name, url_part))
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': self._pic(cover),
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
        data = _api('/videos?kw=%s&page=%s' % (urllib.parse.quote(key or ''), pg))
        items = []
        total = 0
        if isinstance(data, dict):
            items = self._cards(data.get('list') or [])
            total = data.get('count') or data.get('total') or 0
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': total}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        if raw.startswith('danai:'):
            raw = raw[6:]
        url = _fix_url(raw)
        header = {'User-Agent': UA, 'Referer': _resolve_base() + '/'}
        if '.m3u8' in url:
            return {'parse': 0, 'playUrl': url, 'url': url, 'header': header}
        html = _http_get(url, referer=_resolve_base() + '/')
        m3u8 = ''
        if html:
            for m in re.finditer(r'https?://[^\s"\'<>]*\.m3u8[^\s"\'<>]*', html):
                m3u8 = _fix_url(m.group(0))
                break
        if m3u8:
            header['Referer'] = url
            return {'parse': 0, 'playUrl': m3u8, 'url': m3u8, 'header': header}
        if html:
            m2 = re.search(r'player_data=\{[^}]*"url":"([^"]+)"[^}]*"from":"([^"]+)"', html)
            if m2 and m2.group(2) == 'huangguo':
                try:
                    origin = urllib.parse.urlparse(url)
                    origin_url = '%s://%s' % (origin.scheme, origin.netloc)
                    ep_id, ep = m2.group(1).split('|', 1)
                    play_api = '%s/huangguo.php?ac=play&id=%s&ep=%s&_=%d' % (
                        origin_url, urllib.parse.quote(ep_id), urllib.parse.quote(ep), int(time.time() * 1000))
                    txt = _http_get(play_api, referer=url)
                    obj = json.loads(txt or '{}')
                    if obj.get('code') == 1 and str(obj.get('url') or '').startswith('/hgmedia.php?e='):
                        m3u8 = origin_url + obj['url']
                        header['Referer'] = url
                        return {'parse': 0, 'playUrl': m3u8, 'url': m3u8, 'header': header}
                except Exception:
                    pass
        return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}

    def localProxy(self, param):
        try:
            p = param
            if isinstance(p, str):
                try:
                    p = json.loads(p)
                except Exception:
                    p = dict(urllib.parse.parse_qsl(p))
            if not isinstance(p, dict):
                return [404, 'text/plain', '']
            u = p.get('u') or p.get('url') or ''
            if not u:
                return [404, 'text/plain', '']
            data = _fetch_bytes(u, referer=_resolve_base() + '/')
            if not data:
                return [404, 'text/plain', '']
            if data[:2] == b'\xff\xd8':
                ctype = 'image/jpeg'
            elif data[:4] == b'\x89PNG':
                ctype = 'image/png'
            else:
                key, iv = self._img_key_iv()
                data = _aes_cbc_decrypt(data, key, iv)
                if data[:2] == b'\xff\xd8':
                    ctype = 'image/jpeg'
                elif data[:4] == b'\x89PNG':
                    ctype = 'image/png'
                else:
                    return [404, 'text/plain', '']
            return [200, ctype, base64.b64encode(data).decode('ascii'), None, 1]
        except Exception:
            return [500, 'text/plain', '']

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
