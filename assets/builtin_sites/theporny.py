try:
    from base.spider import BaseSpider
except Exception:
    try:
        from base import BaseSpider
    except Exception:
        class BaseSpider:
            pass


import base64
import datetime
import gzip
import hashlib
import html as _html
import http.client
import json
import random
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


HOSTS = [
    'https://v2.cdn199.com',
    'https://v2.kekecdn.net',
    'https://v2.luchu.org',
    'https://v2.madou.ws',
    'https://v2.papapa.biz',
    'https://v2.tianmtv.com',
    'https://v2.xiaoshuo.info',
    'https://v2.xiaoshuo.la',
]
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
APP = 'theporny.com'
VERSION = '260901'
THELINK = 'https://rs.xiaoxx.com'
LINE = 'hd1'
PAGE_SIZE = 24

CATS = [
    ('hot', '当前最热'),
    ('recent', '最近更新'),
    ('high', '站长推荐'),
    ('hd', '会员专享视频'),
    ('recent_hot', '最近加精'),
    ('10mins', '10分钟以上'),
    ('20mins', '20分钟以上'),
    ('month_discuss', '本月讨论'),
    ('month_favs', '本月收藏'),
    ('favs', '收藏最多'),
    ('month_hot', '本月最热'),
    ('last_month_hot', '上月最热'),
    ('c0', '国产传媒全集'),
    ('c1', '麻豆视频'),
    ('c2', '91制片厂'),
    ('c3', '玩偶姐姐'),
    ('c4', '小鸟酱专题'),
    ('c5', '糖心Vlog'),
    ('c6', '天美传媒'),
    ('c7', '蜜桃传媒'),
    ('c8', '皇家华人'),
    ('c9', '星空传媒'),
    ('ca', '精东影业'),
    ('cc', '成人头条'),
    ('cd', '乌鸦传媒'),
    ('cl', '开心鬼传媒'),
    ('japan', '日本高清AV'),
    ('banana', '汝工作室'),
    ('swag', '台湾Swag全集'),
    ('torture_all', '重口系列'),
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


def _evp_key_iv(password, salt):
    out = b''
    prev = b''
    while len(out) < 48:
        prev = hashlib.md5(prev + password + salt).digest()
        out += prev
    return out[:32], out[32:48]


def _cryptojs_decrypt(b64):
    raw = base64.b64decode(b64)
    if len(raw) < 16 or raw[:8] != b'Salted__':
        raise Exception('bad salted header')
    key, iv = _evp_key_iv(b'xxx', raw[8:16])
    pt = _aes_cbc_decrypt(raw[16:], key, iv)
    return pt.decode('utf-8', 'replace')


def _make_uuid():
    now = datetime.datetime.utcnow()
    rnd = random.randint(1000, 9999)
    return 'U%s%04d' % (now.strftime('%Y%m%d%H%M%S'), rnd)


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _post_js(host, url_path, extra, timeout=25):
    body = {
        'app': APP,
        'isStandalone': False,
        'theLink': THELINK,
        'uuid': _make_uuid(),
        'url': url_path,
        'version': VERSION,
        'deviceInfo': {},
    }
    if isinstance(extra, dict):
        body.update(extra)
    payload = json.dumps(body).encode('utf-8')
    h = {'User-Agent': UA, 'Content-Type': 'application/json', 'Authorization': 'Bearer undefined', 'Referer': 'https://theporny.com/', 'Origin': 'https://theporny.com'}
    if _HAS_REQ:
        try:
            r = requests.post(host + '/js', headers=h, data=payload, timeout=timeout)
            if r.status_code == 200 and r.text:
                return r.text
        except Exception:
            pass
    req = urllib.request.Request(host + '/js', data=payload, headers=h, method='POST')
    with urllib.request.urlopen(req, timeout=timeout, context=_ctx()) as resp:
        return resp.read().decode('utf-8', 'replace')


def _js_call(url_path, extra):
    last = ''
    for host in HOSTS:
        try:
            raw = _post_js(host, url_path, extra)
            obj = json.loads(raw or '{}')
            r = obj.get('r') if isinstance(obj, dict) else None
            if r:
                plain = _cryptojs_decrypt(r)
                return json.loads(plain)
            return obj
        except Exception as e:
            last = str(e)
            time.sleep(1)
    raise Exception(last or 'js call failed')


def _txt(v, keys):
    if not isinstance(v, dict):
        return ''
    for k in keys:
        val = v.get(k)
        if isinstance(val, str) and val:
            return val
        if isinstance(val, (int, float)):
            return str(val)
    return ''


def _cover_of(v):
    if not isinstance(v, dict):
        return ''
    t = v.get('thumbnails')
    if isinstance(t, list) and t:
        c = t[0]
        if isinstance(c, str):
            return c.strip()
    return ''


def _parse_items(data):
    out = []
    if not isinstance(data, list):
        return out
    for v in data:
        if not isinstance(v, dict):
            continue
        vid = _txt(v, ['id', 'vId'])
        title = _txt(v, ['title'])
        if not vid or not title:
            continue
        out.append({'vod_id': vid, 'vod_name': title, 'vod_pic': _cover_of(v), 'vod_remarks': _txt(v, ['durationStr'])})
    return out


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
        return 'thePorny'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=''):
        cats = list(CATS)
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
            items = self.categoryContent(CATS[0][0], 1).get('list') or []
        except Exception:
            items = []
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        try:
            data = _js_call('/sevenVideos?page=%s&type=%s' % (pg, tid), {})
        except Exception:
            return {'list': [], 'page': pg, 'pagecount': 0, 'total': 0}
        items = _parse_items(data)
        has_more = len(items) >= PAGE_SIZE
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        vid = _norm_id(ids)
        if not vid:
            return {'list': []}
        try:
            data = _js_call('/sevenVideos/%s' % vid, {'url_search': '?server=%s' % LINE})
        except Exception:
            return {'list': []}
        if not isinstance(data, dict):
            return {'list': []}
        title = _txt(data, ['title'])
        m3u8 = ''
        m = data.get('m3u8s')
        if isinstance(m, list) and m:
            u = m[0]
            if isinstance(u, str):
                m3u8 = u
        if not title or not m3u8:
            return {'list': []}
        cover = _cover_of(data)
        keywords = _txt(data, ['keywords_gem'])
        tags = _txt(data, ['tags'])
        user = _txt(data, ['user'])
        synopsis = ('%s\n%s\n作者：%s' % (keywords, tags, user)).strip()
        return {'list': [{
            'vod_id': vid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': user,
            'vod_director': '',
            'vod_remarks': '',
            'vod_year': '',
            'vod_area': '',
            'vod_content': synopsis,
            'type_name': '',
            'vod_tag': tags,
            'vod_play_from': '在线播放',
            'vod_play_url': '高速线路1$%s' % m3u8,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        try:
            data = _js_call('/searchSevenVideos', {
                'page': 1,
                'keywords': str(key or ''),
                'filterCategory': 'all',
                'filterTimeInDays': 'all',
                'filterViews': 'all',
                'filterDurationInMins': 'all',
                'sortBy': 'time',
                'keywordLogic': 'or',
            })
        except Exception:
            return {'list': [], 'page': _norm_pg(pg), 'pagecount': 0, 'total': 0}
        items = _parse_items(data)
        return {'list': items, 'page': _norm_pg(pg), 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        header = {'User-Agent': UA, 'Referer': 'https://theporny.com/'}
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
