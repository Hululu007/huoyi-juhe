import base64
import gzip
import hashlib
import html as _html
import json
import random
import re
import ssl
import string
import time
import urllib.parse
import urllib.request
import uuid

try:
    from base.spider import BaseSpider
except Exception:
    try:
        from base import BaseSpider
    except Exception:
        class BaseSpider:
            pass

API = 'https://zdap.gkquu.cn:4438/zd/'
ENTRY = 'http://zw.mmjvlook.top/'
MIRROR_FALLBACK = 'ifbbgjob.jvlookdp05.cn'
SIGN_SALT = '@1243asd31**21#'
AES_KEY = b'mh_aes=19@#$@%@#'
AES_IV = b'5e1y6w452uqw9jq8'
NONCE_ALPHABET = 'ABCDEFGHJKMNPQRSTWXYZabcdefhijkmnprstwxyz2345678'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

CATS = [
    ('19', '成人天堂'),
    ('22', '成人视频'),
]
PLATES = [19, 22]

try:
    import requests
    _HAS_REQ = True
except Exception:
    _HAS_REQ = False

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

_MIRROR_CACHE = {'host': '', 'ts': 0}


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


def _http_get(url, headers=None, timeout=25):
    hdr = {'User-Agent': UA, 'Accept': '*/*', 'Accept-Encoding': 'gzip, deflate'}
    if headers:
        hdr.update(headers)
    if _HAS_REQ:
        try:
            r = requests.get(url, headers=hdr, timeout=timeout)
            if r.status_code == 200 and r.text and r.text.strip():
                return r.text, r.url
        except Exception:
            pass
    for attempt in range(3):
        try:
            req = urllib.request.Request(url, headers=hdr)
            with urllib.request.urlopen(req, timeout=timeout, context=CTX) as resp:
                data = resp.read()
                enc = (resp.headers.get('Content-Encoding') or '').lower()
                final = resp.geturl()
            if enc == 'gzip' or data[:2] == b'\x1f\x8b':
                try:
                    data = gzip.decompress(data)
                except Exception:
                    pass
            return data.decode('utf-8', 'replace'), final
        except Exception:
            if attempt < 2:
                time.sleep(1)
    return '', url


def _url_host():
    now = time.time()
    if _MIRROR_CACHE['host'] and now - _MIRROR_CACHE['ts'] < 3600:
        return _MIRROR_CACHE['host']
    host = MIRROR_FALLBACK
    try:
        _, final = _http_get(ENTRY)
        parsed = urllib.parse.urlparse(final)
        if parsed.hostname:
            host = parsed.hostname
    except Exception:
        pass
    _MIRROR_CACHE['host'] = host
    _MIRROR_CACHE['ts'] = now
    return host


def _sign(timestamp, guid, nonce):
    raw = (timestamp + guid + nonce + SIGN_SALT).encode('utf-8')
    return hashlib.md5(raw).hexdigest().upper()


def _txt(v):
    if v is None:
        return ''
    if isinstance(v, str):
        return v.strip()
    return str(v).strip()


def _api_json(path, params=None):
    guid = str(uuid.uuid4())
    nonce = ''.join(random.choice(NONCE_ALPHABET) for _ in range(16))
    timestamp = str(int(time.time() * 1000))
    query = ''
    if params:
        query = '?' + urllib.parse.urlencode(params)
    url = API + path + query
    headers = {
        'Content-Type': 'application/x-www-form-urlencoded',
        'token': guid,
        'sign': _sign(timestamp, guid, nonce),
        'timestamp': timestamp,
        'nonce': nonce,
        'url': _url_host(),
    }
    body, _ = _http_get(url, headers=headers)
    if not body:
        return None
    try:
        obj = json.loads(body)
    except Exception:
        return None
    if not isinstance(obj, dict):
        return None
    if obj.get('returnValue') != 1:
        return None
    data = obj.get('returnData')
    if isinstance(data, str):
        try:
            raw = base64.b64decode(data.strip())
            pt = _aes_cbc_decrypt(raw, AES_KEY, AES_IV)
            return json.loads(pt.decode('utf-8', 'replace'))
        except Exception:
            return None
    if isinstance(data, (dict, list)):
        return data
    return {}


def _video_title(v):
    title = _txt(v.get('videoTitle'))
    if title:
        return title
    nick = _txt(v.get('nickName'))
    if nick:
        return nick
    user = _txt(v.get('userName'))
    if user:
        return user
    return _txt(v.get('videoId'))


def _video_item(plate_id, v):
    if not isinstance(v, dict):
        return None
    vid = _txt(v.get('videoId'))
    if not vid:
        return None
    title = _video_title(v)
    cover = _txt(v.get('videoCover'))
    if not title or not cover:
        return None
    dur = _txt(v.get('duration'))
    return {
        'vod_id': '%d:%s' % (plate_id, vid),
        'vod_name': title,
        'vod_pic': cover,
        'vod_remarks': '' if dur == '0' else dur,
    }


def _parse_video_list(plate_id, data):
    out = []
    seen = set()
    if isinstance(data, dict):
        lst = data.get('videoList')
        if isinstance(lst, list):
            for v in lst:
                item = _video_item(plate_id, v)
                if item and item['vod_id'] not in seen:
                    seen.add(item['vod_id'])
                    out.append(item)
    return out


def _first_label_id(plate_id):
    data = _api_json('sp/getPlateLabelList', {'plateId': str(plate_id)})
    if isinstance(data, dict):
        center = data.get('plateCenter')
        if isinstance(center, dict):
            labels = center.get('plateLabelList')
            if isinstance(labels, list) and labels:
                try:
                    return int(labels[0].get('exploreLabelId'))
                except Exception:
                    return 0
    return 0


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
        return 'XLook中文大全'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cats(self):
        data = _api_json('sp/getTabList')
        out = []
        if isinstance(data, dict):
            plates = data.get('plateList')
            if isinstance(plates, list):
                for p in plates:
                    if not isinstance(p, dict):
                        continue
                    try:
                        ptype = int(p.get('plateType') or 0)
                        pid = int(p.get('plateId') or 0)
                    except Exception:
                        continue
                    if ptype != 1 or pid not in PLATES:
                        continue
                    name = _txt(p.get('plateName'))
                    if name:
                        out.append({'type_id': str(pid), 'type_name': name})
        if not out:
            out = [{'type_id': tid, 'type_name': name} for tid, name in CATS]
        return out

    def homeContent(self, filter=''):
        cats = self._cats()
        items = []
        if cats:
            items = self._catalog(cats[0]['type_id'], 1)
        return {'class': cats, 'filters': {}, 'list': items}

    def homeVideoContent(self):
        items = self._catalog(CATS[0][0], 1)
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def _catalog(self, tid, pg):
        try:
            plate_id = int(tid)
        except Exception:
            return []
        if plate_id not in PLATES:
            return []
        label_id = _first_label_id(plate_id)
        if not label_id:
            return []
        data = _api_json('sp/getLabelVideoList', {
            'plateId': str(plate_id),
            'labelId': str(label_id),
            'page': str(pg),
            'size': '25',
        })
        if not isinstance(data, dict):
            return []
        return _parse_video_list(plate_id, data)

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        items = self._catalog(_norm_id(tid), pg)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        raw = _norm_id(ids)
        if ':' not in raw:
            return {'list': []}
        plate_s, video_id = raw.split(':', 1)
        try:
            plate_id = int(plate_s)
        except Exception:
            return {'list': []}
        data = _api_json('sp/getVideoDetail', {'plateId': str(plate_id), 'videoId': video_id})
        v = None
        if isinstance(data, dict) and isinstance(data.get('videoDetail'), dict):
            v = data['videoDetail']
        if not v:
            return {'list': []}
        title = _video_title(v)
        url = _txt(v.get('videoUrlOne')) or _txt(v.get('videoUrlTwo'))
        if not title or not url:
            return {'list': []}
        return {'list': [{
            'vod_id': raw,
            'vod_name': title,
            'vod_pic': _txt(v.get('videoCover')),
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': '',
            'vod_year': '',
            'vod_area': '',
            'vod_content': _txt(v.get('videoDes')),
            'type_name': '',
            'vod_tag': '',
            'vod_play_from': '在线播放',
            'vod_play_url': '播放$' + url,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        items = []
        seen = set()
        for plate_id in PLATES:
            data = _api_json('sp/getSearchList', {
                'plateId': str(plate_id),
                'searchName': str(key or ''),
                'page': '1',
                'size': '25',
            })
            if not isinstance(data, dict):
                continue
            for item in _parse_video_list(plate_id, data):
                if item['vod_id'] not in seen:
                    seen.add(item['vod_id'])
                    items.append(item)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        header = {'User-Agent': UA}
        if raw.startswith('http'):
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}

    def localProxy(self, param):
        return [404, 'text/plain', b'', {}]

    def isVideoFormat(self, url):
        u = (url or '').lower()
        return u.endswith('.m3u8') or u.endswith('.mp4') or '.m3u8?' in u or '.mp4?' in u

    def manualVideoCheck(self):
        return False

    def action(self, action, params=None):
        return None
