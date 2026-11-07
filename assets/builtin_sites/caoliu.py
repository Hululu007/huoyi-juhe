import base64
import datetime
import gzip
import hashlib
import json
import random
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

try:
    import requests as _requests
except Exception:
    _requests = None

BASE = 'https://caoliu.io'
APP = 'caoliu.io'
VERSION = '260901'
THELINK = 'https://rs.xiaoxx.com'
LINE = 'hd1'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
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

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

TIMEOUT = 60


def _now():
    return time.time()


def _xtime(a):
    a <<= 1
    if a & 0x100:
        a ^= 0x11b
    return a & 0xff


def _gmul(a, b):
    r = 0
    while b:
        if b & 1:
            r ^= a
        a = _xtime(a)
        b >>= 1
    return r


def _sbox_gen():
    sbox = [0] * 256
    for i in range(256):
        if i == 0:
            inv = 0
        else:
            inv = 1
            for _ in range(254):
                inv = _gmul(inv, i)
        s = inv
        for shift in (1, 2, 3, 4):
            s ^= ((inv << shift) | (inv >> (8 - shift))) & 0xff
        s ^= 0x63
        sbox[i] = s & 0xff
    return sbox


_SBOX = _sbox_gen()
_INV_SBOX = [0] * 256
for _i, _v in enumerate(_SBOX):
    _INV_SBOX[_v] = _i
_RCON = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36, 0x6c, 0xd8, 0xab, 0x4d]


def _key_expansion(key):
    nk = len(key) // 4
    nr = nk + 6
    w = [list(key[i * 4:(i + 1) * 4]) for i in range(nk)]
    for i in range(nk, 4 * (nr + 1)):
        t = list(w[i - 1])
        if i % nk == 0:
            t = t[1:] + t[:1]
            t = [_SBOX[b] for b in t]
            t[0] ^= _RCON[i // nk - 1]
        elif nk > 6 and i % nk == 4:
            t = [_SBOX[b] for b in t]
        w.append([w[i - nk][j] ^ t[j] for j in range(4)])
    return w, nr


def _inv_shift_rows(s):
    out = [0] * 16
    for r in range(4):
        for c in range(4):
            out[r + 4 * c] = s[r + 4 * ((c - r) % 4)]
    return out


def _inv_mix_columns(s):
    out = [0] * 16
    for c in range(4):
        col = s[c * 4:(c + 1) * 4]
        out[c * 4 + 0] = _gmul(col[0], 14) ^ _gmul(col[1], 11) ^ _gmul(col[2], 13) ^ _gmul(col[3], 9)
        out[c * 4 + 1] = _gmul(col[0], 9) ^ _gmul(col[1], 14) ^ _gmul(col[2], 11) ^ _gmul(col[3], 13)
        out[c * 4 + 2] = _gmul(col[0], 13) ^ _gmul(col[1], 9) ^ _gmul(col[2], 14) ^ _gmul(col[3], 11)
        out[c * 4 + 3] = _gmul(col[0], 11) ^ _gmul(col[1], 13) ^ _gmul(col[2], 9) ^ _gmul(col[3], 14)
    return out


def _add_round_key(s, w, rnd):
    rk = []
    for i in range(4):
        rk.extend(w[rnd * 4 + i])
    return [s[i] ^ rk[i] for i in range(16)]


def _aes_decrypt_block(block, w, nr):
    s = list(block)
    s = _add_round_key(s, w, nr)
    for rnd in range(nr - 1, 0, -1):
        s = [_INV_SBOX[b] for b in s]
        s = _inv_shift_rows(s)
        s = _add_round_key(s, w, rnd)
        s = _inv_mix_columns(s)
    s = [_INV_SBOX[b] for b in s]
    s = _inv_shift_rows(s)
    s = _add_round_key(s, w, 0)
    return bytes(s)


def _evp_key_iv(password, salt, kl=32, ivl=16):
    d = b''
    p = b''
    while len(d) < kl + ivl:
        p = hashlib.md5(p + password + salt).digest()
        d += p
    return d[:kl], d[kl:kl + ivl]


def _cryptojs_decrypt(b64):
    raw = base64.b64decode(b64)
    if raw[:8] != b'Salted__':
        raise ValueError('bad cipher header')
    key, iv = _evp_key_iv(b'xxx', raw[8:16])
    w, nr = _key_expansion(key)
    ct = raw[16:]
    pt = b''
    prev = iv
    for i in range(0, len(ct), 16):
        blk = ct[i:i + 16]
        d = _aes_decrypt_block(blk, w, nr)
        pt += bytes(a ^ b for a, b in zip(d, prev))
        prev = blk
    pad = pt[-1]
    return pt[:-pad].decode('utf-8')


def _uuid():
    now = datetime.datetime.now(datetime.timezone.utc)
    return 'U' + now.strftime('%Y%m%d%H%M%S') + str(random.randint(1000, 9999))


def _js_post_once(host, body_bytes, headers, timeout=TIMEOUT):
    raw = None
    if _requests is not None:
        try:
            resp = _requests.post(host + '/js', data=body_bytes, headers=headers, timeout=timeout)
            if resp.status_code == 200:
                raw = resp.json()
        except Exception:
            raw = None
    if raw is None:
        try:
            req = urllib.request.Request(host + '/js', data=body_bytes, headers=headers, method='POST')
            with urllib.request.urlopen(req, timeout=timeout, context=CTX) as resp:
                if resp.status == 200:
                    raw = json.loads(resp.read().decode('utf-8', 'replace'))
        except Exception:
            raw = None
    return raw


def _js_call(url_path, extra=None):
    body = {
        'app': APP,
        'isStandalone': False,
        'theLink': THELINK,
        'uuid': _uuid(),
        'url': url_path,
        'version': VERSION,
        'deviceInfo': {},
    }
    if extra:
        body.update(extra)
    body_bytes = json.dumps(body).encode('utf-8')
    headers = {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer undefined',
        'User-Agent': UA,
        'Referer': BASE + '/',
        'Origin': BASE,
    }
    last_err = ''
    for host in HOSTS:
        for _attempt in range(2):
            try:
                raw = _js_post_once(host, body_bytes, headers)
                if raw is None:
                    last_err = 'no response@' + host
                    break
                if isinstance(raw, dict) and raw.get('blocked'):
                    last_err = 'blocked@' + host
                    break
                r = raw.get('r', '') if isinstance(raw, dict) else ''
                if r:
                    return json.loads(_cryptojs_decrypt(r))
                return raw
            except Exception as e:
                last_err = str(e)
                continue
    raise Exception(last_err or 'js call failed')


def _cover(v):
    t = v.get('thumbnails') or v.get('thumbNails') or []
    if isinstance(t, list) and t:
        return t[0] or ''
    return ''


def _parse_items(data):
    out = []
    if not isinstance(data, list):
        return out
    for v in data:
        vid = v.get('id') or v.get('vId') or ''
        title = v.get('title') or ''
        if not vid or not title:
            continue
        out.append({
            'vod_id': vid,
            'vod_name': title,
            'vod_pic': _cover(v),
            'vod_remarks': v.get('durationStr') or '',
        })
    return out


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


def _empty_detail(vod_id):
    return {'list': [{
        'vod_id': vod_id,
        'vod_name': '',
        'vod_pic': '',
        'vod_actor': '',
        'vod_director': '',
        'vod_remarks': '',
        'vod_year': '',
        'vod_area': '',
        'vod_content': '',
        'type_name': '',
        'vod_tag': '',
        'vod_play_from': '在线播放',
        'vod_play_url': '',
        'stills': [],
    }]}


class Spider(BaseSpider):

    def getName(self):
        return '草榴视频'

    def getDependence(self):
        return []

    def init(self, extend=None):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=False):
        cats = [{'type_id': cid, 'type_name': name} for cid, name in CATS]
        return {'class': cats, 'filters': {}}

    def homeVideoContent(self):
        try:
            data = _js_call('/sevenVideos?page=1&type=hot', {})
            items = _parse_items(data)
        except Exception:
            items = []
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        tid = _norm_id(tid).strip()
        pg = _norm_pg(pg)
        if pg < 1:
            pg = 1
        if not tid or tid == 'all':
            tid = 'hot'
        try:
            data = _js_call('/sevenVideos?page=%d&type=%s' % (pg, tid), {})
            items = _parse_items(data)
        except Exception:
            items = []
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        vid = _norm_id(ids).strip()
        if not vid:
            return _empty_detail(vid)
        try:
            data = _js_call('/sevenVideos/%s' % vid, {'url_search': '?server=' + LINE})
        except Exception:
            return _empty_detail(vid)
        if not isinstance(data, dict):
            return _empty_detail(vid)
        title = data.get('title') or ''
        m3u8 = ''
        m3u8s = data.get('m3u8s') or []
        if isinstance(m3u8s, list) and m3u8s:
            m3u8 = m3u8s[0] or ''
        if not m3u8:
            m3u8 = data.get('m3u8') or ''
        if not title or not m3u8:
            return _empty_detail(vid)
        keywords = data.get('keywords_gem') or ''
        tags = data.get('tags') or ''
        user = data.get('user') or ''
        synopsis = (keywords + '\n' + tags + '\n' + ('作者：' + user if user else '')).strip()
        return {'list': [{
            'vod_id': vid,
            'vod_name': title,
            'vod_pic': _cover(data),
            'vod_actor': user,
            'vod_director': '',
            'vod_remarks': data.get('durationStr') or '',
            'vod_year': '',
            'vod_area': '',
            'vod_content': synopsis,
            'type_name': '',
            'vod_tag': '',
            'vod_play_from': '在线播放',
            'vod_play_url': '高速线路1$%s' % m3u8,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        if pg < 1:
            pg = 1
        try:
            data = _js_call('/searchSevenVideos', {
                'page': pg,
                'keywords': str(key).strip(),
                'filterCategory': 'all',
                'filterTimeInDays': 'all',
                'filterViews': 'all',
                'filterDurationInMins': 'all',
                'sortBy': 'time',
                'keywordLogic': 'or',
            })
            items = _parse_items(data)
        except Exception:
            items = []
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        if not raw:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        if raw.startswith('http') and '.m3u8' in raw:
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}

    def localProxy(self, param):
        return [404, 'text/plain', b'', {}]

    def isVideoFormat(self, url):
        u = str(url or '').lower().split('?')[0]
        return u.endswith(('.m3u8', '.mp4', '.mkv', '.webm', '.flv', '.ts'))

    def manualVideoCheck(self):
        return True

    def action(self, action, params=None):
        return {'code': 0, 'msg': 'ok'}
