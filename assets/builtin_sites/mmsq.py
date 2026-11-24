import base64
import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request

try:
    from base.spider import BaseSpider
except Exception:
    class BaseSpider:
        pass

try:
    from Crypto.Cipher import AES as _CryptoAES
except Exception:
    try:
        from Cryptodome.Cipher import AES as _CryptoAES
    except Exception:
        _CryptoAES = None


BASE = "https://67ka4ky.xyz"
UA = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36"
AES_KEY = b"625222f9149e961d"
AES_IV = b"5efdtf6060e2o330"

FLAG_WORDS = ["萝莉", "幼女", "幼齿", "小学生", "初中生", "未成年", "思春期", "loli", "ロリ"]
EXCLUDE_NOVEL_IDS = {57045}

VIDEO_CATES = [
    (16, "欧美精品"), (31, "成人动漫"), (32, "国产专区"), (34, "中文字幕"),
    (35, "人气女优"), (37, "不雅视频"), (38, "亚洲无码"), (39, "韩三级"),
    (40, "热剧成人版"), (41, "抖音妹合集"), (42, "猫咪自拍"),
]
NOVEL_CATES = [
    (7, "都市激情"), (8, "人妻交换"), (12, "校园春色"), (13, "家庭乱伦"),
    (14, "性爱技巧"), (32, "情色笑话"), (33, "武侠经典"), (34, "另类小说"),
]
AUDIO_CATES = [
    (8, "都市激情"), (9, "家庭乱伦"), (10, "另类小说"), (11, "青春校园"),
    (12, "情色笑话"), (13, "人妻乱伦"), (14, "性爱技巧"), (15, "玄幻奇幻"),
]


def _gf_mul(a, b):
    r = 0
    for _ in range(8):
        if b & 1:
            r ^= a
        hi = a & 0x80
        a = (a << 1) & 0xFF
        if hi:
            a ^= 0x1B
        b >>= 1
    return r


def _gf_inv(a):
    if a == 0:
        return 0
    r = 1
    for _ in range(254):
        r = _gf_mul(r, a)
    return r


def _rotl(x, n):
    return ((x << n) | (x >> (8 - n))) & 0xFF


def _make_sboxes():
    sbox = []
    inv = []
    for i in range(256):
        x = _gf_inv(i)
        s = x ^ _rotl(x, 1) ^ _rotl(x, 2) ^ _rotl(x, 3) ^ _rotl(x, 4) ^ 0x63
        s &= 0xFF
        sbox.append(s)
    for i in range(256):
        inv.append(sbox.index(i))
    return sbox, inv


_SBOX, _INV_SBOX = _make_sboxes()
_RCON = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36]


def _expand_key(key):
    w = [list(key[i * 4:i * 4 + 4]) for i in range(4)]
    for i in range(4, 44):
        t = list(w[i - 1])
        if i % 4 == 0:
            t = [_SBOX[t[1]] ^ _RCON[i // 4 - 1], _SBOX[t[2]], _SBOX[t[3]], _SBOX[t[0]]]
        w.append([w[i - 4][j] ^ t[j] for j in range(4)])
    return w


def _add_rk(state, w, rnd):
    for c in range(4):
        for r in range(4):
            state[r + 4 * c] ^= w[rnd * 4 + c][r]


def _sub(state):
    for i in range(16):
        state[i] = _SBOX[state[i]]


def _inv_sub(state):
    for i in range(16):
        state[i] = _INV_SBOX[state[i]]


def _shift(state):
    s = list(state)
    for r in range(4):
        for c in range(4):
            state[r + 4 * c] = s[r + 4 * ((c + r) % 4)]


def _inv_shift(state):
    s = list(state)
    for r in range(4):
        for c in range(4):
            state[r + 4 * c] = s[r + 4 * ((c - r) % 4)]


def _mix(state):
    for c in range(4):
        o = 4 * c
        a0, a1, a2, a3 = state[o], state[o + 1], state[o + 2], state[o + 3]
        state[o] = _gf_mul(a0, 2) ^ _gf_mul(a1, 3) ^ a2 ^ a3
        state[o + 1] = a0 ^ _gf_mul(a1, 2) ^ _gf_mul(a2, 3) ^ a3
        state[o + 2] = a0 ^ a1 ^ _gf_mul(a2, 2) ^ _gf_mul(a3, 3)
        state[o + 3] = _gf_mul(a0, 3) ^ a1 ^ a2 ^ _gf_mul(a3, 2)


def _inv_mix(state):
    for c in range(4):
        o = 4 * c
        a0, a1, a2, a3 = state[o], state[o + 1], state[o + 2], state[o + 3]
        state[o] = _gf_mul(a0, 14) ^ _gf_mul(a1, 11) ^ _gf_mul(a2, 13) ^ _gf_mul(a3, 9)
        state[o + 1] = _gf_mul(a0, 9) ^ _gf_mul(a1, 14) ^ _gf_mul(a2, 11) ^ _gf_mul(a3, 13)
        state[o + 2] = _gf_mul(a0, 13) ^ _gf_mul(a1, 9) ^ _gf_mul(a2, 14) ^ _gf_mul(a3, 11)
        state[o + 3] = _gf_mul(a0, 11) ^ _gf_mul(a1, 13) ^ _gf_mul(a2, 9) ^ _gf_mul(a3, 14)


def _enc_block(block, w):
    state = list(block)
    _add_rk(state, w, 0)
    for rnd in range(1, 10):
        _sub(state)
        _shift(state)
        _mix(state)
        _add_rk(state, w, rnd)
    _sub(state)
    _shift(state)
    _add_rk(state, w, 10)
    return bytes(state)


def _dec_block(block, w):
    state = list(block)
    _add_rk(state, w, 10)
    for rnd in range(9, 0, -1):
        _inv_shift(state)
        _inv_sub(state)
        _add_rk(state, w, rnd)
        _inv_mix(state)
    _inv_shift(state)
    _inv_sub(state)
    _add_rk(state, w, 0)
    return bytes(state)


def _pad(data):
    n = 16 - (len(data) % 16)
    return data + bytes([n]) * n


def _unpad(data):
    if not data:
        return data
    n = data[-1]
    if 1 <= n <= 16 and data[-n:] == bytes([n]) * n:
        return data[:-n]
    return data


def _aes_cbc_encrypt(data, key, iv):
    if _CryptoAES is not None:
        return _CryptoAES.new(key, _CryptoAES.MODE_CBC, iv).encrypt(_pad(data))
    w = _expand_key(key)
    padded = _pad(data)
    out = bytearray()
    prev = iv
    for i in range(0, len(padded), 16):
        chunk = padded[i:i + 16]
        blk = bytes(chunk[j] ^ prev[j] for j in range(16))
        enc = _enc_block(blk, w)
        out += enc
        prev = enc
    return bytes(out)


def _aes_cbc_decrypt(data, key, iv):
    if _CryptoAES is not None:
        return _unpad(_CryptoAES.new(key, _CryptoAES.MODE_CBC, iv).decrypt(data))
    w = _expand_key(key)
    out = bytearray()
    prev = iv
    for i in range(0, len(data), 16):
        chunk = data[i:i + 16]
        dec = _dec_block(chunk, w)
        out += bytes(dec[j] ^ prev[j] for j in range(16))
        prev = chunk
    return _unpad(bytes(out))


def _http_post(url, body, headers=None, timeout=30):
    req = urllib.request.Request(url, data=body, headers=headers or {}, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.status, resp.read()


def _http_get(url, headers=None, timeout=30):
    req = urllib.request.Request(url, headers=headers or {}, method="GET")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.status, resp.read(), dict(resp.headers)


def _quote_url(url):
    try:
        return urllib.parse.quote(str(url or ""), safe=":/?#[]@!$&'()*+,;=%")
    except Exception:
        return url or ""


def _api(ep, params):
    for attempt in range(3):
        try:
            raw = json.dumps(params, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            enc = _aes_cbc_encrypt(raw, AES_KEY, AES_IV)
            body = urllib.parse.urlencode({"params": enc.hex().upper()}).encode("utf-8")
            status, resp = _http_post(BASE + "/" + ep, body, {
                "User-Agent": UA,
                "Content-Type": "application/x-www-form-urlencoded",
                "Referer": BASE + "/",
            })
            if status != 200:
                raise ValueError("http %s" % status)
            text = resp.decode("utf-8", "ignore").strip()
            if not text:
                raise ValueError("empty")
            dec = _aes_cbc_decrypt(bytes.fromhex(text), AES_KEY, AES_IV)
            return json.loads(dec.decode("utf-8", "ignore"))
        except Exception:
            if attempt < 2:
                time.sleep(1)
    return {}


def _data_list(res):
    if not isinstance(res, dict) or res.get("code") not in (1, "1"):
        return []
    data = res.get("data")
    if isinstance(data, list):
        return data
    if isinstance(data, dict) and isinstance(data.get("data"), list):
        return data["data"]
    return []


def _flagged(text):
    low = (text or "").lower()
    return any(w.lower() in low for w in FLAG_WORDS)


def _b64e(obj):
    raw = json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def _b64d(text):
    pad = "=" * (-len(text) % 4)
    return json.loads(base64.urlsafe_b64decode(text + pad).decode("utf-8"))


def _norm_ids(ids):
    if ids is None:
        return []
    if isinstance(ids, str):
        return [ids]
    try:
        return list(ids)
    except Exception:
        return [ids]


def _play_header():
    return {"User-Agent": UA, "Referer": BASE + "/"}


class Spider(BaseSpider):
    def getName(self):
        return "🔞猫咪社区"

    def getDependence(self):
        return []

    def init(self, extend=None):
        pass

    def destroy(self):
        pass

    def _classes(self):
        out = []
        for cid, name in VIDEO_CATES:
            out.append({"type_id": "video:%d" % cid, "type_name": "视频-" + name})
        out.append({"type_id": "comic:0", "type_name": "漫画-最新"})
        for cid, name in NOVEL_CATES:
            out.append({"type_id": "novel:%d" % cid, "type_name": "小说-" + name})
        for cid, name in AUDIO_CATES:
            out.append({"type_id": "audio:%d" % cid, "type_name": "有声-" + name})
        out.append({"type_id": "original:0", "type_name": "原创-最新"})
        return out

    def homeContent(self, filter=None):
        try:
            res = _api("api/video/index", {"page": 1})
            items = _data_list(res)[:12]
            videos = [self._video_card(it) for it in items]
            videos = [v for v in videos if v]
        except Exception:
            videos = []
        return {"class": self._classes(), "filters": {}, "list": videos}

    def homeVideoContent(self):
        return self.categoryContent("video:16", "1", False, {})

    def _video_card(self, it):
        name = (it.get("name") or "").strip()
        if not name or _flagged(name):
            return None
        return {
            "vod_id": "video:%s" % it.get("id"),
            "vod_name": name,
            "vod_pic": it.get("image") or "",
            "vod_remarks": "",
        }

    def _comic_card(self, it):
        name = (it.get("title") or "").strip()
        if not name or _flagged(name):
            return None
        return {
            "vod_id": "comic:%s" % it.get("id"),
            "vod_name": name,
            "vod_pic": it.get("thumb") or "",
            "vod_remarks": it.get("author") or "",
        }

    def _novel_card(self, it):
        try:
            nid = int(it.get("id"))
        except Exception:
            return None
        if nid in EXCLUDE_NOVEL_IDS:
            return None
        name = (it.get("title") or "").strip()
        if not name or _flagged(name):
            return None
        blob = _b64e({"i": nid, "t": name, "p": it.get("thumb") or "", "u": it.get("url") or ""})
        return {
            "vod_id": "novel:" + blob,
            "vod_name": name,
            "vod_pic": it.get("thumb") or "",
            "vod_remarks": "",
        }

    def _audio_card(self, it):
        name = (it.get("name") or "").strip()
        if not name or _flagged(name):
            return None
        blob = _b64e({"i": it.get("id"), "t": name, "p": _quote_url(it.get("thumb") or "")})
        return {
            "vod_id": "audio:" + blob,
            "vod_name": name,
            "vod_pic": _quote_url(it.get("thumb") or ""),
            "vod_remarks": "",
        }

    def _original_card(self, it):
        name = (it.get("title") or "").strip()
        if not name or _flagged(name):
            return None
        blob = _b64e({
            "i": it.get("id"), "t": name, "p": it.get("video_img") or "",
            "m": it.get("m3u8") or "", "v": it.get("video") or "",
        })
        return {
            "vod_id": "original:" + blob,
            "vod_name": name,
            "vod_pic": it.get("video_img") or "",
            "vod_remarks": "",
        }

    def categoryContent(self, tid, pg, filter=None, extend=None):
        try:
            page = int(pg)
        except Exception:
            page = 1
        if page < 1:
            page = 1
        tid = str(tid or "")
        section, _, cate = tid.partition(":")
        try:
            cate_id = int(cate)
        except Exception:
            cate_id = 0
        videos = []
        if section == "video":
            items = _data_list(_api("api/video/index", {"page": page, "cate_id": cate_id}))
            videos = [v for v in (self._video_card(it) for it in items) if v]
        elif section == "comic":
            items = _data_list(_api("api/comic/index", {"page": page}))
            videos = [v for v in (self._comic_card(it) for it in items) if v]
        elif section == "novel":
            items = _data_list(_api("api/v2/novels/index", {"page": page, "cate_id": cate_id}))
            videos = [v for v in (self._novel_card(it) for it in items) if v]
        elif section == "audio":
            items = _data_list(_api("api/book/index", {"page": page, "cate_id": cate_id}))
            videos = [v for v in (self._audio_card(it) for it in items) if v]
        elif section == "original":
            items = _data_list(_api("api/original/index", {"page": page}))
            videos = [v for v in (self._original_card(it) for it in items) if v]
        pagecount = page + 1 if videos else page
        return {"page": page, "pagecount": pagecount, "limit": 20, "total": 0, "list": videos}

    def detailContent(self, ids):
        ids = _norm_ids(ids)
        if not ids:
            return {"list": []}
        vid = str(ids[0])
        section, _, rest = vid.partition(":")
        if section == "video":
            return {"list": [self._detail_video(rest)]}
        if section == "comic":
            return {"list": [self._detail_comic(rest)]}
        if section == "novel":
            return {"list": [self._detail_novel(rest)]}
        if section == "audio":
            return {"list": [self._detail_audio(rest)]}
        if section == "original":
            return {"list": [self._detail_original(rest)]}
        return {"list": []}

    def _video_sources(self, data):
        items = data.get("video_item") or []
        if not items:
            items = data.get("videos") or []
        return items

    def _detail_video(self, vid):
        res = _api("api/video/detail", {"id": int(vid)})
        data = res.get("data") or {}
        videos = self._video_sources(data)
        eps = []
        for idx, _v in enumerate(videos):
            label = "播放" if len(videos) == 1 else "线路%d" % (idx + 1)
            eps.append("%s$mmsq:video:%s:%d" % (label, vid, idx))
        vod = {
            "vod_id": "video:" + str(vid),
            "vod_name": data.get("name") or "",
            "vod_pic": data.get("ximage") or "",
            "vod_content": data.get("description") or "",
            "vod_play_from": "猫咪社区",
            "vod_play_url": "#".join(eps),
        }
        return vod

    def _detail_comic(self, vid):
        res = _api("api/comic/detail", {"id": int(vid)})
        data = res.get("data") or {}
        eps = []
        for page in range(1, 11):
            items = _data_list(_api("api/comic/lists", {"id": int(vid), "page": page, "sort": 1}))
            if not items:
                break
            for it in items:
                name = (it.get("name") or "").strip()
                if not name or _flagged(name):
                    continue
                eps.append("%s$mmsq:comiclist:%s" % (name, it.get("id")))
            if len(items) < 20:
                break
        vod = {
            "vod_id": "comic:" + str(vid),
            "vod_name": data.get("title") or "",
            "vod_pic": data.get("thumb") or "",
            "vod_content": data.get("descriptions") or "",
            "vod_tag": "image",
            "vod_play_from": "猫咪社区",
            "vod_play_url": "#".join(eps),
        }
        return vod

    def _detail_novel(self, blob):
        try:
            info = _b64d(blob)
        except Exception:
            info = {}
        play = "阅读$mmsq:noveltext:" + _b64e({"t": info.get("t", ""), "u": info.get("u", "")})
        return {
            "vod_id": "novel:" + blob,
            "vod_name": info.get("t", ""),
            "vod_pic": info.get("p", ""),
            "vod_content": "",
            "vod_tag": "text",
            "vod_play_from": "猫咪社区",
            "vod_play_url": play,
        }

    def _detail_audio(self, blob):
        try:
            info = _b64d(blob)
        except Exception:
            info = {}
        res = _api("api/book/detail", {"id": info.get("i")})
        data = res.get("data") or {}
        chapters = data.get("data") or []
        eps = []
        for idx, ch in enumerate(chapters):
            name = (ch.get("title") or "").strip()
            if not name or _flagged(name):
                continue
            eps.append("%s$mmsq:audio:%s:%d" % (name, info.get("i"), idx))
        return {
            "vod_id": "audio:" + blob,
            "vod_name": info.get("t", ""),
            "vod_pic": info.get("p", ""),
            "vod_content": "",
            "vod_play_from": "猫咪社区",
            "vod_play_url": "#".join(eps),
        }

    def _detail_original(self, blob):
        try:
            info = _b64d(blob)
        except Exception:
            info = {}
        play = "播放$mmsq:original:" + blob
        return {
            "vod_id": "original:" + blob,
            "vod_name": info.get("t", ""),
            "vod_pic": info.get("p", ""),
            "vod_content": "",
            "vod_play_from": "猫咪社区",
            "vod_play_url": play,
        }

    def searchContent(self, key, quick=False, pg="1"):
        try:
            page = int(pg)
        except Exception:
            page = 1
        key = (key or "").strip()
        if not key:
            return {"list": []}
        videos = []
        res = _api("api/video/search", {"keyword": key, "page": page})
        videos += [v for v in (self._video_card(it) for it in _data_list(res)) if v]
        res = _api("api/comic/search", {"keyword": key, "page": page})
        videos += [v for v in (self._comic_card(it) for it in _data_list(res)) if v]
        res = _api("api/book/search", {"keyword": key, "page": page})
        videos += [v for v in (self._audio_card(it) for it in _data_list(res)) if v]
        return {"list": videos}

    def playerContent(self, flag, id, vipFlags=None):
        ids = _norm_ids(id)
        raw = str(ids[0]).strip() if ids else ""
        if raw.startswith("pics://") or raw.startswith("novel://"):
            return {"parse": 0, "playUrl": raw, "url": raw, "header": {}}
        if not raw.startswith("mmsq:"):
            return {"parse": 0, "playUrl": raw, "url": raw, "header": _play_header()}
        parts = raw.split(":")
        kind = parts[1] if len(parts) > 1 else ""
        if kind == "video":
            try:
                idx = int(parts[3])
            except Exception:
                idx = 0
            res = _api("api/video/detail", {"id": int(parts[2])})
            videos = self._video_sources(res.get("data") or {})
            url = ""
            if 0 <= idx < len(videos):
                url = videos[idx].get("file") or videos[idx].get("down") or ""
            return {"parse": 0, "playUrl": url, "url": url, "header": _play_header()}
        if kind == "comiclist":
            items = _data_list(_api("api/comic/watch", {"list_id": int(parts[2])}))
            imgs = []
            for it in items:
                img = it.get("image") or ""
                if img:
                    imgs.append(img)
            url = "pics://" + "&&".join(_quote_url(i) for i in imgs)
            return {"parse": 0, "playUrl": url, "url": url, "header": _play_header()}
        if kind == "noveltext":
            try:
                info = _b64d(parts[2])
            except Exception:
                info = {}
            text = ""
            for _try in range(3):
                res = _api("api/Novels/detail", {"txt_url": info.get("u", "")})
                if isinstance(res, dict) and res.get("code") in (1, "1") and isinstance(res.get("data"), str):
                    text = res["data"].lstrip("\ufeff")
                if text:
                    break
                time.sleep(1)
            title = info.get("t", "")
            if not title and text:
                for line in text.splitlines():
                    if line.strip():
                        title = line.strip()
                        break
            payload = json.dumps({"title": title, "content": text}, ensure_ascii=False)
            url = "novel://" + payload
            return {"parse": 0, "playUrl": url, "url": url, "header": {}}
        if kind == "audio":
            try:
                idx = int(parts[3])
            except Exception:
                idx = 0
            res = _api("api/book/detail", {"id": int(parts[2])})
            chapters = ((res.get("data") or {}).get("data")) or []
            url = ""
            if 0 <= idx < len(chapters):
                url = _quote_url(chapters[idx].get("content") or "")
            return {"parse": 0, "playUrl": url, "url": url, "header": _play_header()}
        if kind == "original":
            try:
                info = _b64d(parts[2])
            except Exception:
                info = {}
            url = info.get("m", "") or info.get("v", "")
            try:
                target = int(info.get("i"))
                for page in range(1, 4):
                    items = _data_list(_api("api/original/index", {"page": page}))
                    found = None
                    for it in items:
                        if it.get("id") == target:
                            found = it
                            break
                    if found:
                        url = found.get("m3u8") or found.get("video") or url
                        break
                    if not items:
                        break
            except Exception:
                pass
            return {"parse": 0, "playUrl": url, "url": url, "header": _play_header()}
        return {"parse": 0, "playUrl": "", "url": "", "header": _play_header()}

    def localProxy(self, param=None):
        try:
            p = param
            if isinstance(p, str):
                try:
                    p = json.loads(p)
                except Exception:
                    p = dict(urllib.parse.parse_qsl(p))
            if not isinstance(p, dict):
                return [404, "text/plain", "", {}]
            url = p.get("u") or p.get("url") or ""
            if not url:
                return [404, "text/plain", "", {}]
            headers = {"User-Agent": UA, "Referer": BASE + "/"}
            status, body, resp_headers = _http_get(url, headers, timeout=30)
            mime = "application/octet-stream"
            for k, v in resp_headers.items():
                if k.lower() == "content-type":
                    mime = v.split(";")[0].strip()
            if str(p.get("b64")) == "1":
                return [status, mime, base64.b64encode(body).decode("ascii"), {}, 1]
            return [status, mime, body, {}]
        except Exception:
            return [500, "text/plain", "", {}]

    def isVideoFormat(self, url):
        if not url:
            return False
        url = url.lower()
        return url.endswith(".m3u8") or url.endswith(".mp4") or url.endswith(".mp3")

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return {}
