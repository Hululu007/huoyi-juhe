import hashlib
import json
import secrets
import time
import urllib.error
import urllib.parse
import urllib.request

try:
    from base.spider import BaseSpider
except Exception:
    try:
        from spider import BaseSpider
    except Exception:
        class BaseSpider:
            pass


class Spider(BaseSpider):
    def getName(self):
        return "多多影视"

    def getDependence(self):
        return []

    def init(self, extend=""):
        self._base = "https://duoduosdf12223234334.top"
        self._client = "8f3d2a1c7b6e5d4c9a0b1f2e3d4c5b6a"
        self._sign = "ddtvf65f3a83d6d9ad6f"
        self._finger = "WF-2c064bc5b3400788f31b848849bc3a60f835423ba2dfe69d7ea93974c216e4f2"
        self._sk = "WEB-50a8e9c84a1dc05669a692ded99a2dac46527229e607a7be15db88dbc59059d1"
        self._ua = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36"
        self._cats = [("1", "电影"), ("2", "剧集"), ("3", "动漫"), ("4", "综艺")]
        self._cat_names = {"1": "电影", "2": "剧集", "3": "动漫", "4": "综艺"}

    def destroy(self):
        pass

    def _headers(self):
        return {
            "User-Agent": self._ua,
            "Accept": "application/json",
            "X-Client": self._client,
            "web-sign": self._sign,
        }

    def _fetch(self, url, data=None, headers=None, timeout=30, retries=2):
        last = None
        for _ in range(retries + 1):
            try:
                req = urllib.request.Request(url, data=data, headers=headers or self._headers(), method="POST" if data is not None else "GET")
                with urllib.request.urlopen(req, timeout=timeout) as r:
                    return r.read()
            except Exception as e:
                last = e
                time.sleep(1)
        raise last

    def _api(self, path):
        raw = self._fetch(self._base + path)
        return json.loads(raw.decode("utf-8", "replace"))

    def _card(self, v):
        return {
            "vod_id": str(v.get("vod_id", "")),
            "vod_name": v.get("vod_name", ""),
            "vod_pic": v.get("vod_pic", ""),
            "vod_remarks": v.get("vod_remarks", "") or "",
        }

    def homeContent(self, filter=False):
        cats = []
        try:
            d = self._api("/api.php/web/index/home")
            for c in (d.get("data") or {}).get("categories", []):
                tid = str(c.get("type_id", ""))
                name = c.get("type_name", "")
                if tid and name:
                    cats.append({"type_id": tid, "type_name": name})
                    self._cat_names[tid] = name
        except Exception:
            cats = []
        if not cats:
            cats = [{"type_id": tid, "type_name": name} for tid, name in self._cats]
        return {"class": cats, "filters": {}}

    def homeVideoContent(self):
        videos = []
        try:
            d = self._api("/api.php/web/index/home")
            for v in (d.get("data") or {}).get("recommend", []):
                videos.append(self._card(v))
        except Exception:
            videos = []
        return {"list": videos}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        if extend is None:
            extend = {}
        pg = int(pg or 1)
        name = self._cat_names.get(str(tid), str(tid))
        q = urllib.parse.urlencode({"type_name": name, "page": pg, "sort": "hits"})
        d = self._api("/api.php/web/filter/vod?" + q)
        items = d.get("data") or []
        videos = [self._card(v) for v in items]
        pagecount = pg + 1 if len(items) >= 18 else pg
        return {"list": videos, "page": pg, "pagecount": pagecount, "limit": 24, "total": 999999}

    def detailContent(self, ids):
        if isinstance(ids, (list, tuple)):
            vid = str(ids[0])
        else:
            vid = str(ids)
        d = self._api("/api.php/web/vod/get_detail?vod_id=" + urllib.parse.quote(vid))
        data = d.get("data") or []
        if not data:
            return {"list": []}
        v = data[0]
        show = {}
        for p in d.get("vodplayer") or []:
            frm = str(p.get("from", ""))
            if frm:
                show[frm] = p.get("show", "") or frm
        froms = (v.get("vod_play_from") or "").split("$$$")
        groups = (v.get("vod_play_url") or "").split("$$$")
        play_from = []
        play_url = []
        for i, frm in enumerate(froms):
            if i >= len(groups):
                break
            frm = frm.strip()
            if not frm:
                continue
            eps = []
            for part in groups[i].split("#"):
                if "$" not in part:
                    continue
                ep_name, token = part.split("$", 1)
                token = token.strip()
                if not token:
                    continue
                eps.append("%s$%s|%s" % (ep_name.strip() or "正片", frm, token))
            if eps:
                play_from.append(show.get(frm, frm))
                play_url.append("#".join(eps))
        vod = {
            "vod_id": str(v.get("vod_id", vid)),
            "vod_name": v.get("vod_name", ""),
            "vod_pic": v.get("vod_pic", ""),
            "type_name": v.get("type_name", ""),
            "vod_year": str(v.get("vod_year", "") or ""),
            "vod_area": v.get("vod_area", "") or "",
            "vod_remarks": v.get("vod_remarks", "") or "",
            "vod_actor": v.get("vod_actor", "") or "",
            "vod_director": v.get("vod_director", "") or "",
            "vod_content": (v.get("vod_content", "") or "").replace("<p>", "").replace("</p>", "").strip(),
            "vod_play_from": "$$$".join(play_from),
            "vod_play_url": "$$$".join(play_url),
        }
        return {"list": [vod]}

    def searchContent(self, key, quick=False, pg=1):
        pg = int(pg or 1)
        q = urllib.parse.urlencode({"wd": key, "page": pg})
        d = self._api("/api.php/web/search/index?" + q)
        items = d.get("data") or []
        videos = [self._card(v) for v in items]
        pagecount = pg + 1 if len(items) >= 15 else pg
        return {"list": videos, "page": pg, "pagecount": pagecount, "limit": 20, "total": 999999}

    def _varint(self, n):
        out = b""
        while True:
            b = n & 0x7F
            n >>= 7
            if n:
                out += bytes([b | 0x80])
            else:
                out += bytes([b])
                break
        return out

    def _pb_field(self, n, data):
        return self._varint((n << 3) | 2) + self._varint(len(data)) + data

    def _pb_var(self, n, v):
        return self._varint((n << 3) | 0) + self._varint(v)

    def _pb_parse(self, d):
        i = 0
        out = {}
        while i < len(d):
            x = 0
            s = 0
            while True:
                b = d[i]
                i += 1
                x |= (b & 0x7F) << s
                if not b & 0x80:
                    break
                s += 7
            fn = x >> 3
            wt = x & 7
            if wt == 2:
                ln = 0
                s = 0
                while True:
                    b = d[i]
                    i += 1
                    ln |= (b & 0x7F) << s
                    if not b & 0x80:
                        break
                    s += 7
                out[fn] = d[i:i + ln]
                i += ln
            elif wt == 0:
                val = 0
                s = 0
                while True:
                    b = d[i]
                    i += 1
                    val |= (b & 0x7F) << s
                    if not b & 0x80:
                        break
                    s += 7
                out[fn] = val
            else:
                break
        return out

    def _decode(self, token, frm):
        nonce = secrets.token_hex(16)
        ts = int(time.time() * 1000)
        canon = "finger=%s&id=com.web.player&nonce=%s&sk=%s&time=%d&v=1" % (self._finger, nonce, self._sk, ts)
        sign = hashlib.sha256(canon.encode()).hexdigest().upper()
        body = (
            self._pb_field(1, token.encode())
            + self._pb_field(2, frm.encode())
            + self._pb_var(3, ts)
            + self._pb_field(4, nonce.encode())
            + self._pb_field(5, sign.encode())
            + self._pb_field(6, b"com.web.player")
            + self._pb_var(7, 1)
        )
        headers = {
            "User-Agent": self._ua,
            "X-Client": self._client,
            "web-sign": self._sign,
            "Content-Type": "application/x-protobuf",
            "Accept": "application/x-protobuf",
        }
        raw = self._fetch(self._base + "/api.php/web/decode/url", data=body, headers=headers, timeout=40)
        out = self._pb_parse(raw)
        if out.get(1) != 1:
            raise RuntimeError("decode failed code=%r" % (out.get(1),))
        return out[3].decode("utf-8", "replace")

    def playerContent(self, flag, id, vipFlags=None):
        if vipFlags is None:
            vipFlags = []
        frm = ""
        token = id
        if "|" in id:
            frm, token = id.split("|", 1)
        if not frm:
            frm = flag or ""
        url = ""
        last = None
        for _ in range(3):
            try:
                url = self._decode(token, frm)
                break
            except Exception as e:
                last = e
                time.sleep(1)
        if not url:
            raise last
        return {
            "parse": 0,
            "url": url,
            "header": {"User-Agent": self._ua, "Referer": self._base + "/"},
        }

    def localProxy(self, param):
        if isinstance(param, dict):
            action = param.get("action", "")
            url = param.get("url", "")
        else:
            action = ""
            url = str(param or "")
        if action in ("", "proxy") and url:
            try:
                req = urllib.request.Request(url, headers={"User-Agent": self._ua})
                with urllib.request.urlopen(req, timeout=30) as r:
                    body = r.read()
                    ctype = r.headers.get_content_type() or "application/octet-stream"
                    return [200, ctype, body, {}]
            except Exception as e:
                return [500, "text/plain", str(e).encode(), {}]
        if action == "play":
            return self.playerContent(param.get("flag", ""), param.get("id", ""))
        return [200, "text/plain", b"", {}]

    def isVideoFormat(self, url):
        url = (url or "").lower().split("?")[0]
        return url.endswith((".m3u8", ".mp4", ".mkv", ".avi", ".mov", ".flv", ".ts", ".m4v", ".webm"))

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
