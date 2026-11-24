try:
    from base.spider import BaseSpider
except Exception:
    try:
        from base import BaseSpider
    except Exception:
        class BaseSpider:
            pass


import gzip
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


BASE = "https://avdbapi.com"
API = BASE + "/api.php/provide/vod/"
POSTER = "https://upload18.cc/v/{code}/poster.jpg"
KEY = "avdb"
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"
FALLBACK_CATS = [
    ("1", "Censored"),
    ("2", "Uncensored"),
    ("3", "Uncensored Leaked"),
    ("4", "Amateur"),
    ("5", "Chinese AV"),
    ("6", "Hentai"),
    ("7", "English subtitle"),
]
M3U8_RE = re.compile(r'"m3u8"\s*:\s*"((?:[^"\\]|\\.)*)"')
M3U8_URL_RE = re.compile(r"https://helvid\.com/m/[A-Za-z0-9_\-/?&=%.;]+")


def _ctx():
    return ssl._create_unverified_context()


def _http_get(url, referer="", timeout=20):
    headers = {
        "User-Agent": UA,
        "Accept": "application/json,text/html,*/*",
        "Accept-Language": "en-US,en;q=0.9",
        "Referer": referer or BASE + "/",
    }
    for attempt in range(3):
        if _HAS_REQ:
            try:
                resp = requests.get(url, headers=headers, timeout=timeout, verify=False)
                if resp.status_code in (200, 206):
                    resp.encoding = resp.apparent_encoding or "utf-8"
                    return resp.text
            except Exception:
                pass
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=timeout, context=_ctx()) as resp:
                raw = resp.read()
                if raw[:2] == b"\x1f\x8b":
                    raw = gzip.decompress(raw)
                enc = resp.headers.get_content_charset() or "utf-8"
                return raw.decode(enc, errors="replace")
        except urllib.error.HTTPError as e:
            try:
                raw = e.read()
                if raw[:2] == b"\x1f\x8b":
                    raw = gzip.decompress(raw)
                return raw.decode("utf-8", errors="replace")
            except Exception:
                return ""
        except (http.client.IncompleteRead, Exception):
            if attempt < 2:
                time.sleep(0.5)
    return ""


def _api(params):
    qs = urllib.parse.urlencode(params)
    try:
        return json.loads(_http_get(API + "?" + qs, referer=BASE + "/"))
    except Exception:
        return {}


def _norm_id(ids):
    if isinstance(ids, (list, tuple)):
        return str(ids[0]) if ids else ""
    return str(ids or "").strip()


def _norm_pg(pg):
    try:
        return max(1, int(pg))
    except Exception:
        return 1


def _join_text(value):
    if isinstance(value, list):
        parts = [str(v).strip() for v in value]
        return ", ".join([p for p in parts if p and p.lower() != "updating"])
    return str(value or "").strip()


def _poster_of(record):
    code = str(record.get("movie_code") or "").strip()
    if not code:
        return ""
    return POSTER.replace("{code}", urllib.parse.quote(code, safe="-_.()"))


def _card(record):
    vid = str(record.get("id") or "").strip()
    name = str(record.get("name") or "").strip()
    if not vid or not name:
        return None
    remarks = str(record.get("type_name") or "").strip()
    code = str(record.get("movie_code") or "").strip()
    if code and code not in name:
        remarks = (code + " " + remarks).strip()
    return {
        "vod_id": vid,
        "vod_name": name,
        "vod_pic": _poster_of(record),
        "vod_remarks": remarks,
    }


def _cards(data):
    out = []
    for record in (data.get("list") or []):
        card = _card(record)
        if card:
            out.append(card)
    return out


def _pagecount(data):
    try:
        return int(data.get("pagecount") or 0)
    except Exception:
        return 0


def _total(data):
    try:
        return int(data.get("total") or 0)
    except Exception:
        return 0


def _classes(data):
    out = []
    for item in (data.get("class") or []):
        tid = str(item.get("type_id") or "").strip()
        name = str(item.get("type_name") or "").strip()
        if tid and name:
            out.append((tid, name))
    return out or list(FALLBACK_CATS)


def _embed_url(record):
    episodes = record.get("episodes") or {}
    server = episodes.get("server_data") or {}
    for episode in server.values():
        if isinstance(episode, dict):
            link = str(episode.get("link_embed") or "").strip()
            if link.startswith("http"):
                return link
    return ""


def _decode_m3u8(raw):
    value = raw
    for _ in range(3):
        try:
            decoded = json.loads('"' + value + '"')
        except Exception:
            break
        if decoded == value:
            break
        value = decoded
    return value.replace("\\/", "/").replace("\\u0026", "&").replace("&amp;", "&")


def _extract_m3u8(html):
    if not html:
        return ""
    m = M3U8_RE.search(html)
    if m:
        url = _decode_m3u8(m.group(1))
        if url.startswith("http"):
            return url
    m = M3U8_URL_RE.search(html)
    if m:
        return _decode_m3u8(m.group(0))
    return ""


class Spider(BaseSpider):
    def getName(self):
        return "AVDB"

    def getDependence(self):
        return []

    def init(self, extend=""):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=""):
        data = _api({"ac": "list", "pg": 1})
        cats = _classes(data)
        items = _cards(data)
        if not items:
            data = _api({"ac": "list", "pg": 1})
            items = _cards(data)
        return {
            "class": [{"type_id": tid, "type_name": name} for tid, name in cats],
            "list": items,
        }

    def homeVideoContent(self):
        data = _api({"ac": "list", "pg": 1})
        return {
            "list": _cards(data),
            "page": 1,
            "pagecount": _pagecount(data),
            "total": _total(data),
        }

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        tid = _norm_id(tid)
        params = {"ac": "list", "pg": pg}
        if tid:
            params["t"] = tid
        data = _api(params)
        return {
            "list": _cards(data),
            "page": pg,
            "pagecount": _pagecount(data),
            "total": _total(data),
        }

    def detailContent(self, ids):
        vid = _norm_id(ids)
        if not vid:
            return {"list": []}
        data = _api({"ac": "detail", "ids": vid})
        records = data.get("list") or []
        if not records:
            return {"list": []}
        record = records[0]
        name = str(record.get("name") or "").strip()
        if not name:
            return {"list": []}
        embed = _embed_url(record)
        play_url = ""
        if embed:
            play_url = "Full$" + KEY + ":" + embed
        remarks = str(record.get("quality") or "").strip()
        runtime = str(record.get("time") or "").strip()
        if runtime:
            remarks = (remarks + " " + runtime).strip()
        tags = _join_text(record.get("category"))
        return {"list": [{
            "vod_id": vid,
            "vod_name": name,
            "vod_pic": str(record.get("poster_url") or "") or _poster_of(record),
            "vod_actor": _join_text(record.get("actor")),
            "vod_director": _join_text(record.get("director")),
            "vod_remarks": remarks,
            "vod_year": str(record.get("year") or "").strip(),
            "vod_area": _join_text(record.get("country")),
            "vod_content": str(record.get("description") or "").strip(),
            "type_name": str(record.get("type_name") or "").strip(),
            "vod_tag": tags,
            "vod_play_from": "VIP #1",
            "vod_play_url": play_url,
            "stills": [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        data = _api({"ac": "list", "wd": key or "", "pg": pg})
        return {
            "list": _cards(data),
            "page": pg,
            "pagecount": _pagecount(data),
            "total": _total(data),
        }

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        prefix = KEY + ":"
        if raw.startswith(prefix):
            raw = raw[len(prefix):]
        header = {"User-Agent": UA, "Referer": BASE + "/"}
        stream = ""
        if raw.startswith("http"):
            header["Referer"] = raw
            html = _http_get(raw, referer=BASE + "/")
            stream = _extract_m3u8(html)
        return {"parse": 0, "playUrl": stream, "url": stream, "header": header}

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
            headers = {
                "User-Agent": UA,
                "Referer": "%s://%s/" % (parsed.scheme, parsed.netloc),
            }
            if _HAS_REQ:
                try:
                    resp = requests.get(target, headers=headers, timeout=20, verify=False)
                    ctype = resp.headers.get("Content-Type") or "application/octet-stream"
                    return [resp.status_code, ctype, resp.content, {}]
                except Exception:
                    pass
            req = urllib.request.Request(target, headers=headers)
            last_err = None
            for _ in range(3):
                try:
                    with urllib.request.urlopen(req, timeout=20, context=_ctx()) as resp:
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
        return None
