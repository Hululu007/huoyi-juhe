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


HOST = "https://www.qinav.com"
SITE_SEG = "5"
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
NAME = "Qinav"

CATS = [
    ("1", "亚洲情色"),
    ("2", "国产主播"),
    ("3", "国产自拍"),
    ("4", "无码专区"),
    ("5", "欧美性爱"),
    ("6", "熟女人妻"),
    ("7", "强奸乱伦"),
    ("8", "巨乳美乳"),
    ("9", "中文字幕"),
    ("10", "制服诱惑"),
    ("11", "女同性恋"),
    ("12", "卡通动画"),
    ("13", "视频伦理"),
    ("15", "重口色情"),
    ("33", "福利姬"),
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


def _headers(referer=None):
    hdr = {
        "User-Agent": UA,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "zh-CN,zh;q=0.9",
        "Accept-Encoding": "gzip, deflate",
        "Connection": "close",
    }
    if referer:
        hdr["Referer"] = referer
    return hdr


def _http_get(url, referer=None, timeout=25):
    hdr = _headers(referer)
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


def _http_post(url, data, referer=None, timeout=25):
    body = urllib.parse.urlencode(data).encode("utf-8")
    hdr = _headers(referer)
    hdr["Content-Type"] = "application/x-www-form-urlencoded"
    best = ""
    for _ in range(3):
        if _HAS_REQ:
            try:
                r = requests.post(url, data=body, headers=hdr, timeout=timeout)
                if r.status_code == 200 and r.content:
                    txt = _decode(r.content)
                    if len(txt) > len(best):
                        best = txt
                    if "</html>" in txt or len(txt) > 5000:
                        return txt
            except Exception:
                pass
        try:
            req = urllib.request.Request(url, data=body, headers=hdr, method="POST")
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
            if "</html>" in txt or len(txt) > 5000:
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
    anchors = list(re.finditer(r'<a[^>]*href="/video/(\d+)\.html"[^>]*>', html))
    for idx, m in enumerate(anchors):
        vid = m.group(1)
        if vid in seen:
            continue
        end = anchors[idx + 1].start() if idx + 1 < len(anchors) else m.start() + 1500
        seg = html[m.start():min(end, m.start() + 1500)]
        tm = re.search(r'<li class="title">([\s\S]*?)</li>', seg)
        if not tm:
            continue
        title = _txt(tm.group(1))
        if not title or _is_flagged(title):
            continue
        pm = re.search(r'\bimg="([^"]+)"', seg)
        nm = re.search(r'<span class="note">([^<]*)</span>', seg)
        seen.add(vid)
        out.append({
            "vod_id": vid,
            "vod_name": title,
            "vod_pic": _abs(pm.group(1)) if pm else "",
            "vod_remarks": _txt(nm.group(1)) if nm else "",
        })
    return out


def _pagecount(html, cur, tid):
    nums = [int(x) for x in re.findall(r"/site/" + SITE_SEG + r"/" + re.escape(str(tid)) + r"-(\d+)\.html", html or "")]
    if nums:
        return max(max(nums), cur)
    return cur


def _parse_detail(html, vid):
    title = ""
    m = re.search(r"<title[^>]*>([^<]+)</title>", html or "")
    if m:
        title = _txt(m.group(1)).split(" - Qinav")[0].strip()
    pic = ""
    pm = re.search(r'\bimg="(https?://[^"]+)"', html or "")
    if pm:
        pic = pm.group(1)
    desc = ""
    dm = re.search(r'<div class="des">([\s\S]*?)</div>', html or "")
    if dm:
        desc = _txt(dm.group(1))
    return {
        "vod_id": vid,
        "vod_name": title or vid,
        "vod_pic": pic,
        "vod_actor": "",
        "vod_director": "",
        "vod_remarks": "",
        "vod_year": "",
        "vod_area": "",
        "vod_content": desc,
        "type_name": "",
        "vod_play_from": "在线播放",
        "vod_play_url": "正片$" + HOST + "/embed/" + vid + ".html",
    }


def _extract_stream(html):
    if not html:
        return ""
    m = re.search(r"url\s*=\s*'([^']+)'", html)
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
        url = HOST + "/site/" + SITE_SEG + "/" + tid + "-" + str(pg) + ".html"
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
        html = _http_get(HOST + "/video/" + vid + ".html", referer=HOST + "/")
        if not html:
            return {"list": []}
        return {"list": [_parse_detail(html, vid)]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        url = HOST + "/?module=tags&action=keyword"
        try:
            html = _http_post(url, {"keyword": str(key)}, referer=HOST + "/")
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
        page = ""
        if "/embed/" in raw:
            page = raw if raw.startswith("http") else HOST + raw
        else:
            m = re.search(r"(\d+)", raw)
            if raw.startswith("http") and "/video/" in raw:
                page = raw
            elif m:
                page = HOST + "/embed/" + m.group(1) + ".html"
        url = ""
        try:
            html = _http_get(page, referer=HOST + "/") if page else ""
            if "/embed/" not in page:
                im = re.search(r'<iframe[^>]+src="([^"]+)"', html or "")
                if im:
                    page = _abs(im.group(1))
                    html = _http_get(page, referer=HOST + "/")
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
