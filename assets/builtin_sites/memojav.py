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


BASE = "https://memojav.org"
KEY = "memojav"
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"
CATS = [
    ("video", "New Videos"),
    ("best", "Best Videos"),
    ("actress", "Actress"),
    ("studio", "Studio"),
    ("series", "Series"),
    ("categories", "Categories"),
    ("label", "Label"),
    ("director", "Director"),
]
INDEX_KIND = {
    "actress": "actress",
    "studio": "studio",
    "series": "series",
    "category": "categories",
    "label": "label",
    "director": "director",
}
CARD_RE = re.compile(r'<a href="/video/([^"]+)" class="video-item">(.*?)</a>', re.S)
CARD_IMG_RE = re.compile(r'<img[^>]*class="video-poster"[^>]*src="([^"]+)"', re.S)
CARD_META_RE = re.compile(r'<div class="video-metadata">(.*?)</div>', re.S)
CARD_TITLE_RE = re.compile(r'<div class="video-title[^"]*">(.*?)</div>', re.S)
INDEX_CARD_RE = re.compile(r'<a href="/(actress|studio)/([^"]+)">(.*?)</a>', re.S)
INDEX_IMG_RE = re.compile(r'<img[^>]*src="([^"]+)"', re.S)
INDEX_NAME_RE = re.compile(r'<span[^>]*title="([^"]+)"', re.S)
TAG_LINK_RE = re.compile(r'<a[^>]*href="/(categories|series|label|director)/([^"]+)"[^>]*>([^<]+)</a>', re.S)
PAGE_RE = re.compile(r'href="page-(\d+)"')
H1_RE = re.compile(r'<h1[^>]*id="title"[^>]*>(.*?)</h1>', re.S)
H1_ANY_RE = re.compile(r"<h1[^>]*>(.*?)</h1>", re.S)
TITLE_TAG_RE = re.compile(r"<title[^>]*>(.*?)</title>", re.S)
DESC_RE = re.compile(r'<p[^>]*id="title-description"[^>]*>(.*?)</p>', re.S)
META_DESC_RE = re.compile(r'<meta[^>]*name="description"[^>]*content="([^"]*)"', re.S)
OG_IMAGE_RE = re.compile(r'<meta[^>]*property="og:image"[^>]*content="([^"]*)"', re.S)
DETAIL_BLOCK_RE = re.compile(r'<div class="details-block"><h2[^>]*>([^<]+)</h2><p[^>]*>(.*?)</p></div>', re.S)
TABLE_ROW_RE = re.compile(r'<tr><th[^>]*>([^<]+)</th><td[^>]*>(.*?)</td></tr>', re.S)
STILL_RE = re.compile(r'<img[^>]*id="preview-img"[^>]*src="([^"]+)"', re.S)
TAG_STRIP_RE = re.compile(r"<[^>]+>")


def _ctx():
    return ssl._create_unverified_context()


def _unescape(text):
    text = _html.unescape(text or "")
    return re.sub(r"\s+", " ", text).strip()


def _http_get(url, referer="", timeout=20):
    headers = {
        "User-Agent": UA,
        "Accept": "text/html,application/json,*/*",
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
            if e.code == 404:
                return ""
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


def _norm_id(ids):
    if isinstance(ids, (list, tuple)):
        return str(ids[0]) if ids else ""
    return str(ids or "").strip()


def _norm_pg(pg):
    try:
        return max(1, int(pg))
    except Exception:
        return 1


def _pagecount(html):
    pages = [int(n) for n in PAGE_RE.findall(html or "")]
    return max(pages) if pages else 1


def _list_url(path, pg):
    path = "/" + path.strip("/")
    if pg <= 1:
        return BASE + path + "/"
    return BASE + path + "/page-" + str(pg)


def _parse_cards(html):
    out = []
    seen = set()
    for m in CARD_RE.finditer(html or ""):
        code = urllib.parse.unquote(m.group(1)).strip()
        block = m.group(2)
        if not code or code in seen:
            continue
        title = ""
        tm = CARD_TITLE_RE.search(block)
        if tm:
            title = _unescape(tm.group(1))
        if not title:
            continue
        seen.add(code)
        pic = ""
        im = CARD_IMG_RE.search(block)
        if im:
            pic = im.group(1).strip()
        remarks = ""
        mm = CARD_META_RE.search(block)
        if mm:
            remarks = _unescape(mm.group(1))
        out.append({
            "vod_id": code,
            "vod_name": code + " " + title,
            "vod_pic": pic,
            "vod_remarks": remarks,
        })
    return out


def _parse_index_cards(html, kind):
    out = []
    seen = set()
    if kind in ("actress", "studio"):
        for m in INDEX_CARD_RE.finditer(html or ""):
            if m.group(1) != kind:
                continue
            slug = urllib.parse.unquote(m.group(2)).strip()
            block = m.group(3)
            if not slug or slug in seen:
                continue
            names = INDEX_NAME_RE.findall(block)
            name = _unescape(names[-1]) if names else slug
            pic = ""
            im = INDEX_IMG_RE.search(block)
            if im:
                pic = im.group(1).strip()
            seen.add(slug)
            out.append({
                "vod_id": kind + ":" + slug,
                "vod_name": name,
                "vod_pic": pic,
                "vod_remarks": "",
                "vod_tag": "folder",
            })
        return out
    segment = INDEX_KIND.get(kind, kind)
    for m in TAG_LINK_RE.finditer(html or ""):
        if m.group(1) != segment:
            continue
        slug = urllib.parse.unquote(m.group(2)).strip()
        name = _unescape(m.group(3))
        if not slug or slug in seen or not name:
            continue
        seen.add(slug)
        out.append({
            "vod_id": kind + ":" + slug,
            "vod_name": name,
            "vod_pic": "",
            "vod_remarks": "",
            "vod_tag": "folder",
        })
    return out


def _parse_detail(html, code):
    if not html or 'id="title"' not in html:
        return None
    title = ""
    hm = H1_RE.search(html)
    if hm:
        title = _unescape(hm.group(1))
    if not title:
        hm = H1_ANY_RE.search(html)
        if hm:
            title = _unescape(hm.group(1))
    if not title:
        tm = TITLE_TAG_RE.search(html)
        if tm:
            title = _unescape(tm.group(1)).replace(" - MemoJav", "").strip()
    if not title:
        return None
    cover = ""
    om = OG_IMAGE_RE.search(html)
    if om:
        cover = om.group(1).strip()
    synopsis = ""
    dm = DESC_RE.search(html)
    if dm:
        synopsis = _unescape(dm.group(1))
    actor = ""
    studio = ""
    md = META_DESC_RE.search(html)
    if md:
        meta = _unescape(md.group(1))
        am = re.search(r"Pornstar:\s*(.+?)\.\s*Studio:", meta)
        if am:
            actor = am.group(1).strip()
        sm = re.search(r"Studio:\s*(.+?)\s*$", meta)
        if sm:
            studio = sm.group(1).strip()
    blocks = {}
    for key, val in DETAIL_BLOCK_RE.findall(html):
        blocks[_unescape(key)] = _unescape(val)
    rows = {}
    for key, val in TABLE_ROW_RE.findall(html):
        rows[_unescape(key).rstrip(":")] = _unescape(val)
    year = ""
    release = blocks.get("Release Date", "")
    ym = re.search(r"(\d{4})", release)
    if ym:
        year = ym.group(1)
    director = rows.get("Director", "")
    if director in ("----", ""):
        director = ""
    remarks = blocks.get("Resolution", "")
    tags = []
    for m in TAG_LINK_RE.finditer(html):
        if m.group(1) == "categories":
            name = _unescape(m.group(3))
            if name and name not in tags:
                tags.append(name)
    stills = []
    sm = STILL_RE.search(html)
    if sm:
        stills.append(sm.group(1).strip())
    return {
        "vod_id": code,
        "vod_name": title,
        "vod_pic": cover,
        "vod_actor": actor,
        "vod_director": director,
        "vod_remarks": remarks,
        "vod_year": year,
        "vod_area": "",
        "vod_content": synopsis,
        "type_name": tags[0] if tags else "",
        "vod_tag": ", ".join(tags),
        "vod_play_from": "MemoJav",
        "vod_play_url": "Play$" + KEY + ":" + code,
        "stills": stills,
    }


def _video_sig():
    stamp = str(int(time.time() * 1000))
    sig = base64.b64encode(stamp.encode("ascii")).decode("ascii")
    sig = sig[len(sig) - 12:len(sig) - 12 + 10]
    sts = 1
    for i in range(10):
        sts += ord(sig[i]) * i * 1743
    return "&sig=" + sig + "&sts=" + str(sts)


def _video_info(code):
    url = BASE + "/hls/get_video_info.php?id=" + urllib.parse.quote(code) + _video_sig()
    body = _http_get(url, referer=BASE + "/embed/" + urllib.parse.quote(code))
    if not body:
        return {}
    text = body.split("for (;;);", 1)[-1].strip()
    try:
        return json.loads(text)
    except Exception:
        return {}


class Spider(BaseSpider):
    def getName(self):
        return "MemoJav"

    def getDependence(self):
        return []

    def init(self, extend=""):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=""):
        html = _http_get(_list_url("video", 1))
        return {
            "class": [{"type_id": tid, "type_name": name} for tid, name in CATS],
            "list": _parse_cards(html),
        }

    def homeVideoContent(self):
        html = _http_get(_list_url("video", 1))
        return {
            "list": _parse_cards(html),
            "page": 1,
            "pagecount": _pagecount(html),
            "total": 0,
        }

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        tid = _norm_id(tid)
        if tid in ("video", "best"):
            html = _http_get(_list_url(tid, pg))
            return {
                "list": _parse_cards(html),
                "page": pg,
                "pagecount": _pagecount(html),
                "total": 0,
            }
        if tid in ("actress", "studio", "series", "categories", "label", "director"):
            if tid != "actress" and pg > 1:
                return {"list": [], "page": pg, "pagecount": 1, "total": 0}
            html = _http_get(_list_url(tid, pg))
            kind = "category" if tid == "categories" else tid
            items = _parse_index_cards(html, kind)
            return {
                "list": items,
                "page": pg,
                "pagecount": _pagecount(html) if tid == "actress" else 1,
                "total": 0,
            }
        if ":" in tid:
            kind, slug = tid.split(":", 1)
            segment = INDEX_KIND.get(kind)
            if segment and slug:
                html = _http_get(_list_url(segment + "/" + slug, pg))
                return {
                    "list": _parse_cards(html),
                    "page": pg,
                    "pagecount": _pagecount(html),
                    "total": 0,
                }
        return {"list": [], "page": pg, "pagecount": 0, "total": 0}

    def detailContent(self, ids):
        code = _norm_id(ids)
        if not code:
            return {"list": []}
        if code.startswith("http"):
            code = code.rstrip("/").rsplit("/", 1)[-1]
        code = urllib.parse.unquote(code).strip()
        if not code:
            return {"list": []}
        html = _http_get(BASE + "/video/" + urllib.parse.quote(code))
        item = _parse_detail(html, code)
        if not item:
            return {"list": []}
        return {"list": [item]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        key = (key or "").strip()
        if not key or pg > 1:
            return {"list": [], "page": pg, "pagecount": 0, "total": 0}
        tried = []
        for cand in (key, key.upper(), key.replace(" ", "")):
            if cand in tried:
                continue
            tried.append(cand)
            html = _http_get(BASE + "/video/" + urllib.parse.quote(cand))
            item = _parse_detail(html, cand)
            if item:
                return {"list": [{
                    "vod_id": cand,
                    "vod_name": item["vod_name"],
                    "vod_pic": item["vod_pic"],
                    "vod_remarks": item["vod_remarks"],
                }], "page": 1, "pagecount": 1, "total": 1}
        return {"list": [], "page": 1, "pagecount": 0, "total": 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        prefix = KEY + ":"
        if raw.startswith(prefix):
            raw = raw[len(prefix):]
        code = urllib.parse.unquote(raw).strip()
        embed = BASE + "/embed/" + urllib.parse.quote(code)
        header = {"User-Agent": UA, "Referer": embed}
        stream = ""
        if code:
            info = _video_info(code)
            if info.get("success") and info.get("type") in ("hls", "mp4"):
                stream = urllib.parse.unquote(str(info.get("url") or "").strip())
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
