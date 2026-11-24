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
import hashlib
import http.client
import json
import os
import re
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

try:
    from Crypto.Cipher import AES as _AES
    _HAS_CRYPTO = True
except Exception:
    _AES = None
    _HAS_CRYPTO = False


API = "https://newavapi.9xyrp3kg4b86.com"
WEB = "https://www.a-ijav.com"
UA = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36"
AES_KEY = b"0XxdjmI55ZjjqQLO3nI7gGqrBP0Vz9jS"
AES_IV_BASE = "RWf23muavY"
SIGN_KEY = "NRkw0g3iJLDvw5tJ5PuVt5276z0SOuyL"
SUFFIX = "NWSdef"
PAGE = 20
BLOCKED_TAG_IDS = {619}
BLOCKED_TAG_WORDS = ("loli",)
_SSL_CTX = None


def _gf_mul(a, b):
    r = 0
    while b:
        if b & 1:
            r ^= a
        a = ((a << 1) ^ 0x11B) & 0xFF if a & 0x80 else (a << 1) & 0xFF
        b >>= 1
    return r


def _gf_pow(a, e):
    r = 1
    while e:
        if e & 1:
            r = _gf_mul(r, a)
        a = _gf_mul(a, a)
        e >>= 1
    return r


def _rotl8(x, k):
    return ((x << k) & 0xFF) | (x >> (8 - k))


def _build_sbox():
    sbox = []
    for i in range(256):
        inv = 0 if i == 0 else _gf_pow(i, 254)
        s = inv ^ _rotl8(inv, 1) ^ _rotl8(inv, 2) ^ _rotl8(inv, 3) ^ _rotl8(inv, 4)
        s = (s ^ 0x63) & 0xFF
        sbox.append(s)
    return sbox


_SBOX = _build_sbox()
_INV_SBOX = [0] * 256
for _i, _v in enumerate(_SBOX):
    _INV_SBOX[_v] = _i
_RCON = [1, 2, 4, 8, 16, 32, 64, 128, 27, 54, 108, 216, 171, 77, 154, 47]


def _expand_key(key):
    nk = len(key) // 4
    nr = nk + 6
    w = [list(key[i * 4:(i + 1) * 4]) for i in range(nk)]
    for i in range(nk, 4 * (nr + 1)):
        t = list(w[i - 1])
        if i % nk == 0:
            t = [_SBOX[t[1]] ^ _RCON[i // nk - 1], _SBOX[t[2]], _SBOX[t[3]], _SBOX[t[0]]]
        elif nk > 6 and i % nk == 4:
            t = [_SBOX[b] for b in t]
        w.append([w[i - nk][j] ^ t[j] for j in range(4)])
    return w, nr


def _xtime(a):
    return ((a << 1) ^ 0x1B) & 0xFF if a & 0x80 else (a << 1) & 0xFF


def _mix_column(c):
    a0, a1, a2, a3 = c
    t = a0 ^ a1 ^ a2 ^ a3
    u = a0
    c[0] ^= t ^ _xtime(a0 ^ a1)
    c[1] ^= t ^ _xtime(a1 ^ a2)
    c[2] ^= t ^ _xtime(a2 ^ a3)
    c[3] ^= t ^ _xtime(a3 ^ u)
    return c


def _inv_mix_column(c):
    a0, a1, a2, a3 = c
    c[0] = _gf_mul(a0, 14) ^ _gf_mul(a1, 11) ^ _gf_mul(a2, 13) ^ _gf_mul(a3, 9)
    c[1] = _gf_mul(a0, 9) ^ _gf_mul(a1, 14) ^ _gf_mul(a2, 11) ^ _gf_mul(a3, 13)
    c[2] = _gf_mul(a0, 13) ^ _gf_mul(a1, 9) ^ _gf_mul(a2, 14) ^ _gf_mul(a3, 11)
    c[3] = _gf_mul(a0, 11) ^ _gf_mul(a1, 13) ^ _gf_mul(a2, 9) ^ _gf_mul(a3, 14)
    return c


def _shift_rows(s):
    return [s[0], s[5], s[10], s[15], s[4], s[9], s[14], s[3], s[8], s[13], s[2], s[7], s[12], s[1], s[6], s[11]]


def _inv_shift_rows(s):
    return [s[0], s[13], s[10], s[7], s[4], s[1], s[14], s[11], s[8], s[5], s[2], s[15], s[12], s[9], s[6], s[3]]


def _add_round_key(s, w, rnd):
    return [s[i] ^ w[rnd * 4 + i // 4][i % 4] for i in range(16)]


def _aes_encrypt_block(block, w, nr):
    s = _add_round_key(list(block), w, 0)
    for rnd in range(1, nr):
        s = [_SBOX[b] for b in s]
        s = _shift_rows(s)
        for col in range(4):
            c = _mix_column([s[col * 4 + r] for r in range(4)])
            for r in range(4):
                s[col * 4 + r] = c[r]
        s = _add_round_key(s, w, rnd)
    s = [_SBOX[b] for b in s]
    s = _shift_rows(s)
    return bytes(_add_round_key(s, w, nr))


def _aes_decrypt_block(block, w, nr):
    s = _add_round_key(list(block), w, nr)
    for rnd in range(nr - 1, 0, -1):
        s = _inv_shift_rows(s)
        s = [_INV_SBOX[b] for b in s]
        s = _add_round_key(s, w, rnd)
        for col in range(4):
            c = _inv_mix_column([s[col * 4 + r] for r in range(4)])
            for r in range(4):
                s[col * 4 + r] = c[r]
    s = _inv_shift_rows(s)
    s = [_INV_SBOX[b] for b in s]
    return bytes(_add_round_key(s, w, 0))


def _pkcs7_pad(data):
    n = 16 - len(data) % 16
    return data + bytes([n]) * n


def _pkcs7_unpad(data):
    if not data:
        return data
    n = data[-1]
    if 1 <= n <= 16 and data[-n:] == bytes([n]) * n:
        return data[:-n]
    return data


def _aes_cbc_encrypt(data, key, iv):
    if _HAS_CRYPTO:
        return _AES.new(key, _AES.MODE_CBC, iv).encrypt(_pkcs7_pad(data))
    w, nr = _expand_key(key)
    out = bytearray()
    prev = iv
    padded = _pkcs7_pad(data)
    for i in range(0, len(padded), 16):
        blk = bytes(padded[i + j] ^ prev[j] for j in range(16))
        enc = _aes_encrypt_block(blk, w, nr)
        out += enc
        prev = enc
    return bytes(out)


def _aes_cbc_decrypt(data, key, iv):
    if _HAS_CRYPTO:
        return _pkcs7_unpad(_AES.new(key, _AES.MODE_CBC, iv).decrypt(data))
    w, nr = _expand_key(key)
    out = bytearray()
    prev = iv
    for i in range(0, len(data), 16):
        blk = data[i:i + 16]
        dec = _aes_decrypt_block(blk, w, nr)
        out += bytes(dec[j] ^ prev[j] for j in range(16))
        prev = blk
    return _pkcs7_unpad(bytes(out))


def _ssl_ctx():
    global _SSL_CTX
    if _SSL_CTX is None:
        _SSL_CTX = ssl.create_default_context()
    return _SSL_CTX


def _proxy_for(parsed):
    host = (parsed.hostname or "").lower()
    no_proxy = os.environ.get("no_proxy") or os.environ.get("NO_PROXY") or ""
    for item in no_proxy.replace(",", " ").split():
        item = item.strip().lower()
        if item and (host == item or host.endswith("." + item) or item == "*"):
            return None
    if parsed.scheme == "https":
        raw = os.environ.get("https_proxy") or os.environ.get("HTTPS_PROXY") or ""
    else:
        raw = os.environ.get("http_proxy") or os.environ.get("HTTP_PROXY") or ""
    if not raw:
        return None
    p = urllib.parse.urlparse(raw if "://" in raw else "http://" + raw)
    if not p.hostname:
        return None
    return (p.hostname, p.port or 80)


def _http_post_json(url, payload, headers, timeout=45):
    parsed = urllib.parse.urlparse(url)
    host = parsed.hostname or ""
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    path = parsed.path or "/"
    if parsed.query:
        path += "?" + parsed.query
    body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    req_headers = {"Content-Type": "application/json", "Content-Length": str(len(body))}
    req_headers.update(headers)
    proxy = _proxy_for(parsed)
    if proxy:
        if parsed.scheme == "https":
            conn = http.client.HTTPSConnection(proxy[0], proxy[1], timeout=timeout, context=_ssl_ctx())
            conn.set_tunnel(host, port)
        else:
            conn = http.client.HTTPConnection(proxy[0], proxy[1], timeout=timeout)
            path = url
    elif parsed.scheme == "https":
        conn = http.client.HTTPSConnection(host, port, timeout=timeout, context=_ssl_ctx())
    else:
        conn = http.client.HTTPConnection(host, port, timeout=timeout)
    try:
        conn.request("POST", path, body=body, headers=req_headers)
        resp = conn.getresponse()
        data = resp.read()
        enc = ""
        try:
            enc = resp.getheader("Content-Encoding") or ""
        except Exception:
            pass
        if "gzip" in enc.lower():
            try:
                data = gzip.decompress(data)
            except Exception:
                pass
        return resp.status, data
    finally:
        try:
            conn.close()
        except Exception:
            pass


def _sign(params):
    parts = []
    for k in sorted(params.keys()):
        parts.append("%s=%s" % (k, params[k]))
    raw = "&".join(parts) + "&" + SIGN_KEY
    return hashlib.md5(raw.encode("utf-8")).hexdigest()


def _api(path, params=None):
    base = {"timestamp": int(time.time() * 1000)}
    base.update(dict(params or {}))
    base["encode_sign"] = _sign(base)
    plain = json.dumps(base, separators=(",", ":"), ensure_ascii=False)
    iv = (AES_IV_BASE + SUFFIX).encode("utf-8")
    cipher = base64.b64encode(_aes_cbc_encrypt(plain.encode("utf-8"), AES_KEY, iv)).decode("ascii")
    payload = {"post-data": cipher}
    headers = {
        "Accept": "application/json",
        "User-Agent": UA,
        "Origin": WEB,
        "Referer": WEB + "/en/",
        "suffix": SUFFIX,
        "lang": "en",
    }
    last_err = None
    for attempt in range(3):
        try:
            status, data = _http_post_json(API + path, payload, headers)
            if status != 200:
                raise ValueError("http %d" % status)
            env = json.loads(data.decode("utf-8", "ignore"))
            if isinstance(env, dict) and isinstance(env.get("data"), str) and isinstance(env.get("suffix"), str):
                raw = _aes_cbc_decrypt(base64.b64decode(env["data"]), AES_KEY, (AES_IV_BASE + env["suffix"]).encode("utf-8"))
                return json.loads(raw.decode("utf-8", "ignore"))
            return env
        except Exception as e:
            last_err = e
            time.sleep(0.8 * (attempt + 1))
    raise last_err if last_err else ValueError("api failed")


def _norm_pg(pg):
    try:
        pg = int(pg)
    except Exception:
        pg = 1
    return pg if pg >= 1 else 1


def _norm_ids(ids):
    if isinstance(ids, str):
        parts = ids.split(",")
        return [p.strip() for p in parts if p.strip()]
    if isinstance(ids, (list, tuple)):
        out = []
        for x in ids:
            out.extend(_norm_ids(str(x)))
        return out
    return [str(ids)]


def _clean_tags(tags):
    out = []
    for t in tags or []:
        if not isinstance(t, dict):
            continue
        tid = t.get("id")
        name = str(t.get("name") or "").strip()
        if not name:
            continue
        try:
            if int(tid) in BLOCKED_TAG_IDS:
                continue
        except Exception:
            pass
        low = name.lower()
        if any(w in low for w in BLOCKED_TAG_WORDS):
            continue
        out.append(name)
    return out


def _full_name(mash, title):
    mash = str(mash or "").strip()
    title = str(title or "").strip()
    if mash and not title.lower().startswith(mash.lower()):
        return ("%s %s" % (mash, title)).strip()
    return title


def _vod_item(v):
    name = _full_name(v.get("mash"), v.get("title"))
    actors = []
    for a in v.get("actor") or []:
        if isinstance(a, dict) and a.get("name"):
            actors.append(str(a["name"]))
    remarks = str(v.get("duration") or "")
    if actors:
        remarks = (remarks + " " + ", ".join(actors[:2])).strip()
    return {
        "vod_id": str(v.get("id")),
        "vod_name": name,
        "vod_pic": str(v.get("thumb") or v.get("preview") or ""),
        "vod_remarks": remarks,
    }


def _play_header():
    return {"User-Agent": UA, "Referer": WEB + "/"}


class Spider(BaseSpider):
    def getName(self):
        return "🔞AiJav"

    def getDependence(self):
        return []

    def init(self, extend=""):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=""):
        classes = [{"type_id": "free", "type_name": "免费视频"}]
        return {"class": classes, "list": [], "filters": {}}

    def homeVideoContent(self):
        try:
            res = _api("/video/lists", {"type": "3", "page": 1, "limit": PAGE})
            data = (res or {}).get("data") or {}
            items = [_vod_item(v) for v in (data.get("data") or [])]
            return {"list": items}
        except Exception:
            return {"list": []}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        tid = str(tid or "")
        if tid != "free":
            return {"list": [], "page": pg, "pagecount": 1, "limit": PAGE, "total": 0}
        try:
            res = _api("/video/lists", {"type": "3", "page": pg, "limit": PAGE})
            data = (res or {}).get("data") or {}
            items = [_vod_item(v) for v in (data.get("data") or [])]
            total = 0
            pagecount = 1
            try:
                total = int(data.get("total") or 0)
            except Exception:
                pass
            try:
                pagecount = int(data.get("last_page") or 1)
            except Exception:
                pass
            return {"list": items, "page": pg, "pagecount": pagecount, "limit": PAGE, "total": total}
        except Exception:
            return {"list": [], "page": pg, "pagecount": 1, "limit": PAGE, "total": 0}

    def detailContent(self, ids):
        ids = _norm_ids(ids)
        vid = (ids[0] if ids else "").strip()
        vid = vid.split("$")[-1].strip()
        if not re.match(r"^\d+$", vid):
            return {"list": []}
        try:
            res = _api("/video/info", {"vid": int(vid)})
        except Exception:
            return {"list": []}
        if not isinstance(res, dict) or res.get("code") != 1:
            return {"list": []}
        v = res.get("data") or {}
        name = _full_name(v.get("mash"), v.get("title"))
        actors = []
        for a in v.get("actor") or []:
            if isinstance(a, dict) and a.get("name"):
                actors.append(str(a["name"]))
        pub = v.get("publisher") or {}
        pub_name = str(pub.get("name") or "") if isinstance(pub, dict) else str(pub or "")
        tags = _clean_tags(v.get("tags"))
        desc = str(v.get("description") or "").strip()
        if desc.startswith("["):
            desc = re.sub(r"^\[[^\]]*\]", "", desc).strip()
        bits = []
        if desc and desc != "AV video":
            bits.append(desc)
        if tags:
            bits.append("分类: " + ", ".join(tags))
        if pub_name:
            bits.append("出品: " + pub_name)
        if v.get("duration"):
            bits.append("时长: " + str(v.get("duration")))
        if v.get("publish_date"):
            bits.append("发布: " + str(v.get("publish_date")))
        vod = {
            "vod_id": str(v.get("id") or vid),
            "vod_name": name,
            "vod_pic": str(v.get("thumb") or v.get("preview") or ""),
            "vod_actor": ", ".join(actors),
            "vod_director": str(v.get("director") or ""),
            "vod_remarks": str(v.get("duration") or ""),
            "vod_content": "\n".join(bits),
            "vod_play_from": "AiJav",
            "vod_play_url": "正片$" + str(v.get("id") or vid),
        }
        return {"list": [vod]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        key = (key or "").strip()
        if not key or pg != 1:
            return {"list": []}
        try:
            res = _api("/video/lists", {"type": "3", "page": 1, "limit": PAGE})
        except Exception:
            return {"list": []}
        data = (res or {}).get("data") or {}
        kw = key.lower()
        items = []
        for v in data.get("data") or []:
            hay = " ".join([
                str(v.get("mash") or ""),
                str(v.get("title") or ""),
                str(v.get("mash_title") or ""),
            ])
            for a in v.get("actor") or []:
                if isinstance(a, dict) and a.get("name"):
                    hay += " " + str(a["name"])
            if kw in hay.lower() or kw.replace("-", "") in hay.lower().replace("-", "").replace(" ", ""):
                items.append(_vod_item(v))
        return {"list": items}

    def playerContent(self, flag, id, vipFlags=None):
        ids = _norm_ids(id)
        raw = (ids[0] if ids else "").strip()
        raw = raw.split("$")[-1].strip()
        if not re.match(r"^\d+$", raw):
            return {"parse": 0, "playUrl": "", "url": "", "header": {}}
        try:
            res = _api("/video/getVideoUrl", {"vid": int(raw)})
        except Exception:
            return {"parse": 0, "playUrl": "", "url": "", "header": {}}
        if not isinstance(res, dict) or res.get("code") != 1:
            return {"parse": 0, "playUrl": "", "url": "", "header": {}}
        url = str(res.get("data") or "").strip()
        if not url.startswith("http"):
            return {"parse": 0, "playUrl": "", "url": "", "header": {}}
        return {"parse": 0, "playUrl": url, "url": url, "header": _play_header()}

    def localProxy(self, param=None):
        try:
            p = param
            if isinstance(p, str):
                try:
                    p = json.loads(p)
                except Exception:
                    p = dict(urllib.parse.parse_qsl(p))
            if not isinstance(p, dict):
                p = {}
            target = p.get("url") or p.get("u") or ""
            if isinstance(target, list):
                target = target[0] if target else ""
            target = urllib.parse.unquote(str(target or "").strip())
            if not target.startswith("http"):
                return [404, "text/plain", b"bad url", {}]
            parsed = urllib.parse.urlparse(target)
            headers = {"User-Agent": UA, "Referer": "%s://%s/" % (parsed.scheme, parsed.netloc)}
            req = urllib.request.Request(target, headers=headers)
            last_err = None
            for _ in range(3):
                try:
                    with urllib.request.urlopen(req, timeout=20) as resp:
                        ctype = resp.headers.get("Content-Type") or "application/octet-stream"
                        return [resp.status, ctype, resp.read(), {}]
                except urllib.error.HTTPError as e:
                    try:
                        body = e.read()
                    except Exception:
                        body = b""
                    return [e.code, e.headers.get("Content-Type") or "text/plain", body, {}]
                except Exception as e:
                    last_err = e
                    time.sleep(0.5)
            raise last_err
        except Exception:
            return [502, "text/plain", b"proxy error", {}]

    def isVideoFormat(self, url):
        url = (url or "").lower()
        return any(k in url for k in (".m3u8", ".mp4", ".m4s", ".ts"))

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return {}
