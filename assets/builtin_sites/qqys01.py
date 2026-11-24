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


HOST = "https://www.qqys01.com"
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
NAME = "千千影视"

CATS = [
    ("1", "电影"),
    ("2", "连续剧"),
    ("3", "综艺"),
    ("4", "动漫"),
]

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
    parts = re.split(r'<a[^>]*class="module-poster-item[^>]*>', html)
    hrefs = re.findall(r'<a[^>]*class="module-poster-item[^>]*>', html)
    for idx, block in enumerate(parts[1:]):
        tag = hrefs[idx]
        hm = re.search(r'href="/voddetail(\d+)\.html"', tag)
        if not hm:
            continue
        vid = hm.group(1)
        if vid in seen:
            continue
        tm = re.search(r'title="([^"]+)"', tag)
        seg = block[:1500]
        pm = re.search(r'data-original="([^"]+)"', seg)
        nm = re.search(r'module-item-note">([^<]+)<', seg)
        title = _txt(tm.group(1)) if tm else ""
        if not title:
            nm2 = re.search(r'module-poster-item-title">([^<]+)<', seg)
            title = _txt(nm2.group(1)) if nm2 else ""
        if not title:
            continue
        seen.add(vid)
        out.append({
            "vod_id": vid,
            "vod_name": title,
            "vod_pic": _abs(pm.group(1)) if pm else "",
            "vod_remarks": _txt(nm.group(1)) if nm else "",
        })
    parts = re.split(r'<div class="module-card-item module-item">', html)
    for block in parts[1:]:
        seg = block[:2500]
        hm = re.search(r'href="/voddetail(\d+)\.html"', seg)
        if not hm:
            continue
        vid = hm.group(1)
        if vid in seen:
            continue
        tm = re.search(r'module-card-item-title">[\s\S]*?<a[^>]*>([\s\S]*?)</a>', seg)
        title = _txt(tm.group(1)) if tm else ""
        if not title:
            am = re.search(r'alt="([^"]+)"', seg)
            title = _txt(am.group(1)) if am else ""
        if not title:
            continue
        pm = re.search(r'data-original="([^"]+)"', seg)
        nm = re.search(r'module-item-note">([^<]+)<', seg)
        seen.add(vid)
        out.append({
            "vod_id": vid,
            "vod_name": title,
            "vod_pic": _abs(pm.group(1)) if pm else "",
            "vod_remarks": _txt(nm.group(1)) if nm else "",
        })
    return out


def _pagecount(html, cur, tid):
    nums = [int(x) for x in re.findall(r"/vodshow/" + re.escape(str(tid)) + r"--------(\d+)---\.html", html or "")]
    if nums:
        return max(max(nums), cur)
    return cur


def _label(html, names):
    for name in names:
        m = re.search(name + r"[：:]\s*([\s\S]{0,300}?)</div>", html)
        if m:
            links = re.findall(r"<a[^>]*>([^<]+)</a>", m.group(1))
            if links:
                return " / ".join(_txt(x) for x in links if _txt(x))
            return _txt(m.group(1))
    return ""


def _parse_detail(html, vid):
    title = ""
    m = re.search(r"<h1[^>]*>([\s\S]*?)</h1>", html or "", re.S)
    if m:
        title = _txt(m.group(1))
    if not title:
        m = re.search(r"<title[^>]*>([^<]+)</title>", html or "")
        if m:
            title = _txt(m.group(1)).split("-")[0].strip()
    pic = ""
    pm = re.search(r'data-original="([^"]+)"', html or "")
    if pm:
        pic = _abs(pm.group(1))
    desc = ""
    dm = re.search(r'<meta name="description" content="([^"]+)"', html or "")
    if dm:
        desc = _txt(dm.group(1))
    tab_names = [_txt(x) for x in re.findall(r'data-dropdown-value="([^"]+)"', html or "")]
    panels = re.split(r'<div class="module-play-list-content', html or "")
    play_from = []
    play_url = []
    for idx, panel in enumerate(panels[1:]):
        seg = panel[:20000]
        eps = []
        seen = set()
        for m in re.finditer(r'href="(/vodplay/(\d+)-(\d+)-(\d+)\.html)"[^>]*>([\s\S]*?)</a>', seg):
            key = (m.group(3), m.group(4))
            if key in seen:
                continue
            seen.add(key)
            label = _txt(m.group(5)) or ("第" + m.group(4) + "集")
            eps.append(label + "$" + HOST + m.group(1))
        if not eps:
            continue
        name = tab_names[idx] if idx < len(tab_names) else ("线路" + str(idx + 1))
        play_from.append(name)
        play_url.append("#".join(eps))
    if not play_url:
        play_from = ["在线播放"]
        play_url = ["正片$" + HOST + "/vodplay/" + vid + "-1-1.html"]
    return {
        "vod_id": vid,
        "vod_name": title or vid,
        "vod_pic": pic,
        "vod_actor": _label(html or "", ["主演", "演员"]),
        "vod_director": _label(html or "", ["导演"]),
        "vod_remarks": "",
        "vod_year": "",
        "vod_area": "",
        "vod_content": desc,
        "type_name": "",
        "vod_play_from": "$$$".join(play_from),
        "vod_play_url": "$$$".join(play_url),
    }


def _extract_stream(html):
    if not html:
        return ""
    m = re.search(r"player_data\s*=\s*(\{.*?\})\s*[,;]?", html, re.S)
    if m:
        try:
            d = json.loads(m.group(1))
            raw = str(d.get("url") or "")
            enc = d.get("encrypt")
            if raw:
                if enc == 2 or enc == "2":
                    try:
                        raw = base64.b64decode(raw).decode("utf-8", "ignore")
                    except Exception:
                        pass
                    raw = urllib.parse.unquote(raw)
                elif enc == 1 or enc == "1":
                    raw = urllib.parse.unquote(raw)
                if raw.startswith("http"):
                    return raw
        except Exception:
            pass
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
        url = HOST + "/vodshow/" + tid + "--------" + str(pg) + "---.html"
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
        html = _http_get(HOST + "/voddetail" + vid + ".html", referer=HOST + "/")
        if not html:
            return {"list": []}
        return {"list": [_parse_detail(html, vid)]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        url = HOST + "/vodsearch.html?wd=" + urllib.parse.quote(str(key))
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
        page = raw if raw.startswith("http") else HOST + raw
        if "/vodplay/" not in page:
            m = re.search(r"(\d+)", raw)
            if m:
                page = HOST + "/vodplay/" + m.group(1) + "-1-1.html"
        url = ""
        try:
            html = _http_get(page, referer=HOST + "/")
            url = _extract_stream(html)
        except Exception:
            url = ""
        return {
            "parse": 0,
            "playUrl": url,
            "url": url,
            "header": {"User-Agent": UA, "Referer": page},
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
