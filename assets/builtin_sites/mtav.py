try:
    from base.spider import BaseSpider
except Exception:
    try:
        from base import BaseSpider
    except Exception:
        class BaseSpider:
            pass


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


HOST = "https://mtav.art"
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
NAME = "蜜桃视频"

CATS = [
    ("1", "视频一区"),
    ("2", "视频二区"),
    ("3", "视频三区"),
]

FLAG_WORDS = ["loli", "lolita", "幼女", "幼齿", "萝莉", "儿童", "初中生", "小学生", "未成年"]

_CTX = ssl.create_default_context()
_CTX.check_hostname = False
_CTX.verify_mode = ssl.CERT_NONE


def _decode(raw):
    if raw[:2] == b"\x1f\x8b":
        try:
            raw = gzip.decompress(raw)
        except Exception:
            pass
    for cs in ("utf-8", "gbk", "gb18030"):
        try:
            return raw.decode(cs)
        except Exception:
            continue
    return raw.decode("utf-8", "replace")


def _http_get(url, referer=None, timeout=25):
    hdr = {
        "User-Agent": UA,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "zh-CN,zh;q=0.9",
        "Accept-Encoding": "gzip, deflate",
        "Connection": "close",
    }
    if referer:
        hdr["Referer"] = referer
    best = ""
    for _ in range(3):
        if _HAS_REQ:
            try:
                r = requests.get(url, headers=hdr, timeout=timeout)
                if r.status_code == 200 and r.content:
                    txt = _decode(r.content)
                    if len(txt) > len(best):
                        best = txt
                    if "</html>" in txt:
                        return txt
            except Exception:
                pass
        try:
            req = urllib.request.Request(url, headers=hdr)
            with urllib.request.urlopen(req, timeout=timeout, context=_CTX) as resp:
                raw = b""
                try:
                    while True:
                        chunk = resp.read(65536)
                        if not chunk:
                            break
                        raw += chunk
                except http.client.IncompleteRead as e:
                    raw += e.partial or b""
            txt = _decode(raw)
            if len(txt) > len(best):
                best = txt
            if "</html>" in txt:
                return txt
        except urllib.error.HTTPError as e:
            try:
                txt = _decode(e.read())
            except Exception:
                txt = ""
            if len(txt) > len(best):
                best = txt
        except Exception:
            pass
        time.sleep(1)
    return best


def _txt(s):
    if not s:
        return ""
    s = re.sub(r"<[^>]+>", " ", s)
    s = _html.unescape(s)
    return re.sub(r"\s+", " ", s).strip()


def _is_flagged(name):
    low = str(name or "").lower()
    return any(w.lower() in low for w in FLAG_WORDS)


def _abs(url):
    if not url:
        return ""
    url = url.strip()
    if url.startswith("//"):
        return "https:" + url
    if url.startswith("/"):
        return HOST + url
    if url.startswith("http"):
        return url
    return HOST + "/" + url.lstrip("/")


def _norm_pg(pg):
    try:
        pg = int(pg)
    except Exception:
        pg = 1
    return pg if pg >= 1 else 1


def _norm_id(ids):
    if isinstance(ids, (list, tuple)):
        ids = ids[0] if ids else ""
    return str(ids or "").strip()


def _cards(html):
    out = []
    seen = set()
    if not html:
        return out
    parts = re.split(r'<div class="item">', html)
    for block in parts[1:]:
        seg = block[:2500]
        hm = re.search(r'href="/vod/play/id/(\d+)/', seg)
        if not hm:
            continue
        vid = hm.group(1)
        if vid in seen:
            continue
        im = re.search(r'<img[^>]+>', seg)
        title = ""
        pic = ""
        if im:
            am = re.search(r'alt="([^"]+)"', im.group(0))
            sm = re.search(r'src="([^"]+)"', im.group(0))
            if am:
                title = _txt(am.group(1))
            if sm:
                pic = _abs(sm.group(1))
        if not title:
            tm = re.search(r'class="title">([\s\S]*?)</', seg)
            if tm:
                title = _txt(tm.group(1))
        if not title or _is_flagged(title):
            continue
        seen.add(vid)
        rm = re.search(r'<span class="[^"]*time[^"]*">([^<]+)<', seg)
        out.append({
            "vod_id": vid,
            "vod_name": title,
            "vod_pic": pic,
            "vod_remarks": _txt(rm.group(1)) if rm else "",
        })
    return out


def _pagecount(html, cur, tid):
    nums = [int(x) for x in re.findall(r"/vod/show/id/" + re.escape(str(tid)) + r"/page/(\d+)/", html or "")]
    if nums:
        return max(max(nums), cur)
    return cur


def _parse_detail(html, vid):
    title = ""
    m = re.search(r"<title[^>]*>([^<]+)</title>", html or "")
    if m:
        raw = _txt(m.group(1))
        raw = re.sub(r"^Playing\s+", "", raw)
        title = raw.split("-watch onlie")[0].split(" watcho")[0].strip()
    desc = ""
    dm = re.search(r'name="description" content="([^"]*)"', html or "")
    if dm:
        desc = _txt(dm.group(1))
    if not title and desc:
        title = desc.split(" watcho")[0].strip()
    return {
        "vod_id": vid,
        "vod_name": title or vid,
        "vod_pic": "",
        "vod_actor": "",
        "vod_director": "",
        "vod_remarks": "",
        "vod_year": "",
        "vod_area": "",
        "vod_content": desc,
        "type_name": "",
        "vod_play_from": "在线播放",
        "vod_play_url": "正片$" + HOST + "/vod/detail/id/" + vid + "/",
    }


def _extract_stream(html):
    if not html:
        return ""
    m = re.search(r"var uul\s*=\s*'([^']+)'", html)
    if m and m.group(1).startswith("http"):
        return m.group(1)
    m = re.search(r"https?://[^\s\"'<>]+\.m3u8[^\s\"'<>]*", html)
    if m:
        return m.group(0).rstrip(",")
    m = re.search(r"https?://[^\s\"'<>]+\.mp4[^\s\"'<>]*", html)
    if m:
        return m.group(0).rstrip(",")
    return ""


class Spider(BaseSpider):

    def getName(self):
        return NAME

    def getDependence(self):
        return []

    def init(self, extend=""):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=False):
        cats = [{"type_id": tid, "type_name": name} for tid, name in CATS]
        try:
            html = _http_get(HOST + "/", referer=HOST + "/")
            items = _cards(html)
        except Exception:
            items = []
        return {"class": cats, "list": items, "filters": {}}

    def homeVideoContent(self):
        try:
            html = _http_get(HOST + "/", referer=HOST + "/")
            return {"list": _cards(html)[:36]}
        except Exception:
            return {"list": []}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        tid = _norm_id(tid)
        url = HOST + "/vod/show/id/" + tid + "/page/" + str(pg) + "/"
        try:
            html = _http_get(url, referer=HOST + "/")
            items = _cards(html)
            total = _pagecount(html, pg, tid)
        except Exception:
            items, total = [], pg
        return {
            "list": items,
            "page": pg,
            "pagecount": total,
            "limit": max(len(items), 1),
            "total": total * max(len(items), 1),
        }

    def detailContent(self, ids):
        vid = _norm_id(ids)
        m = re.search(r"(\d+)", vid)
        if m:
            vid = m.group(1)
        html = _http_get(HOST + "/vod/detail/id/" + vid + "/", referer=HOST + "/")
        if not html:
            return {"list": []}
        return {"list": [_parse_detail(html, vid)]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        url = HOST + "/vod/search.html?wd=" + urllib.parse.quote(str(key))
        try:
            html = _http_get(url, referer=HOST + "/")
            items = _cards(html)
        except Exception:
            items = []
        return {
            "list": items,
            "page": pg,
            "pagecount": pg,
            "limit": max(len(items), 1),
            "total": len(items),
        }

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        if raw.startswith("http"):
            page = raw
        elif "/vod/" in raw:
            page = HOST + raw if raw.startswith("/") else HOST + "/" + raw
        else:
            m = re.search(r"(\d+)", raw)
            page = HOST + "/vod/detail/id/" + m.group(1) + "/" if m else ""
        url = ""
        try:
            html = _http_get(page, referer=HOST + "/") if page else ""
            url = _extract_stream(html)
        except Exception:
            url = ""
        return {
            "parse": 0,
            "playUrl": url,
            "url": url,
            "header": {"User-Agent": UA, "Referer": page or (HOST + "/")},
        }

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
            o = urllib.parse.urlparse(target)
            req = urllib.request.Request(target, headers={
                "User-Agent": UA,
                "Referer": "%s://%s/" % (o.scheme, o.netloc),
            })
            with urllib.request.urlopen(req, timeout=20, context=_CTX) as r:
                return [r.status, r.headers.get("Content-Type") or "application/octet-stream", r.read(), {}]
        except Exception:
            return [502, "text/plain", b"proxy error", {}]

    def isVideoFormat(self, url):
        u = str(url or "").lower()
        return ".m3u8" in u or ".mp4" in u

    def manualVideoCheck(self):
        return False

    def action(self, action=None, params=None):
        return {}
