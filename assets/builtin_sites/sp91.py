try:
    from base.spider import BaseSpider
except Exception:
    class BaseSpider:
        pass

import http.client
import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request

try:
    import requests
except Exception:
    requests = None


BASE = "https://91spx.com"
UA = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36"
PAGE = 24

CATS = [
    ("gczp", "国产自拍"),
    ("gccm", "国产传媒"),
    ("gtsj", "经典三级"),
    ("kbtj", "捆绑调教"),
    ("awlq", "暗网猎奇"),
    ("zjmw", "醉酒迷玩"),
    ("hwyz", "户外野战"),
    ("thjx", "按摩探花"),
    ("cos", "Cosplay"),
    ("jdjk", "酒店监控"),
    ("zscp", "真实厕拍"),
    ("jtcd", "街头抄底"),
    ("aihl", "AI换脸"),
    ("aimj", "AI漫剧"),
    ("aicrdj", "AI成人短剧"),
    ("rbav", "日本AV"),
    ("fklw", "疯狂老外"),
    ("91yc", "91原创"),
    ("hjll", "海角乱伦"),
    ("whhl", "网红黑料"),
    ("fcb", "反差婊"),
    ("gyds", "街头搭讪"),
    ("hdm", "H动漫"),
]
CAT_IDS = set(slug for slug, _ in CATS)

BLOCK_WORDS = ("loli", "lolicon", "幼女", "小学生", "初中生", "未成年", "儿童", "幼齿", "萝莉")


def _blocked(text):
    t = str(text or "").lower()
    return any(w in t for w in BLOCK_WORDS)


def _http_get(url, timeout=35, headers=None):
    h = {"User-Agent": UA, "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8"}
    if headers:
        h.update(headers)
    last = None
    for _ in range(3):
        try:
            if requests is not None:
                r = requests.get(url, headers=h, timeout=timeout)
                if r.status_code == 200:
                    return r.text
                last = ValueError("HTTP %s" % r.status_code)
            else:
                req = urllib.request.Request(url, headers=h)
                with urllib.request.urlopen(req, timeout=timeout) as resp:
                    try:
                        return resp.read().decode("utf-8", "ignore")
                    except http.client.IncompleteRead as ie:
                        text = (ie.partial or b"").decode("utf-8", "ignore")
                        if text.strip():
                            return text
                        raise
        except urllib.error.HTTPError as e:
            try:
                text = e.read().decode("utf-8", "ignore")
            except http.client.IncompleteRead as ie:
                text = (ie.partial or b"").decode("utf-8", "ignore")
            if text.strip():
                return text
            last = e
            time.sleep(0.6)
        except Exception as e:
            last = e
            time.sleep(0.6)
    if last is not None:
        raise last
    return ""


def _http_post_json(url, payload, timeout=35, headers=None):
    body = json.dumps(payload).encode("utf-8")
    h = {"User-Agent": UA, "Content-Type": "application/json", "Accept": "application/json", "Origin": BASE}
    if headers:
        h.update(headers)
    last = None
    for _ in range(3):
        try:
            if requests is not None:
                r = requests.post(url, data=body, headers=h, timeout=timeout)
                if r.status_code == 200:
                    return r.json()
                last = ValueError("HTTP %s" % r.status_code)
            else:
                req = urllib.request.Request(url, data=body, headers=h, method="POST")
                with urllib.request.urlopen(req, timeout=timeout) as resp:
                    try:
                        raw = resp.read()
                    except http.client.IncompleteRead as ie:
                        raw = ie.partial or b""
                    return json.loads(raw.decode("utf-8", "ignore"))
        except urllib.error.HTTPError as e:
            try:
                raw = e.read()
            except http.client.IncompleteRead as ie:
                raw = ie.partial or b""
            try:
                return json.loads(raw.decode("utf-8", "ignore"))
            except Exception:
                last = e
                time.sleep(0.6)
        except Exception as e:
            last = e
            time.sleep(0.6)
    if last is not None:
        raise last
    return {}


def _norm_pg(pg):
    try:
        n = int(pg)
    except Exception:
        n = 1
    return n if n >= 1 else 1


def _dur_text(iso):
    if not iso:
        return ""
    m = re.match(r"PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?", str(iso))
    if not m:
        return str(iso)
    h = int(m.group(1) or 0)
    mi = int(m.group(2) or 0)
    s = int(m.group(3) or 0)
    if h:
        return "%d:%02d:%02d" % (h, mi, s)
    return "%02d:%02d" % (mi, s)


def _cover(vid):
    return BASE + "/videos/webp/" + str(vid) + ".webp"


def _vid_from_url(u):
    m = re.search(r"/videos/(\d+)/", str(u or ""))
    return m.group(1) if m else ""


def _item_from_video_object(vo):
    vid = _vid_from_url(vo.get("@id") or vo.get("url") or "")
    if not vid:
        return None
    name = str(vo.get("name") or "").strip()
    if _blocked(name):
        return None
    author = vo.get("author") or {}
    actor = ""
    if isinstance(author, dict):
        actor = str(author.get("name") or "").strip()
    elif isinstance(author, str):
        actor = author.strip()
    return {
        "vod_id": vid,
        "vod_name": name,
        "vod_pic": _cover(vid),
        "vod_remarks": _dur_text(vo.get("duration")),
        "vod_content": str(vo.get("description") or "").strip(),
        "vod_actor": actor,
        "vod_tag": str(vo.get("keywords") or "").strip(),
        "vod_year": str(vo.get("uploadDate") or "")[:4],
    }


def _parse_jsonld_list(html):
    total = 0
    items = []
    for m in re.finditer(r'<script type="application/ld\+json">(.*?)</script>', html, re.S):
        try:
            data = json.loads(m.group(1))
        except Exception:
            continue
        nodes = []
        if isinstance(data, dict):
            nodes = data.get("@graph") or [data]
        elif isinstance(data, list):
            nodes = data
        for node in nodes:
            if not isinstance(node, dict):
                continue
            me = node.get("mainEntity") or {}
            if isinstance(me, dict) and me.get("@type") == "ItemList":
                try:
                    total = int(me.get("numberOfItems") or 0)
                except Exception:
                    total = 0
                for el in me.get("itemListElement") or []:
                    vo = (el or {}).get("item") or {}
                    if isinstance(vo, dict):
                        it = _item_from_video_object(vo)
                        if it:
                            items.append(it)
    return items, total


def _parse_html_cards(html):
    items = []
    seen = set()
    pat = re.compile(r'href="/videos/(\d+)/".{0,900}?alt="([^"]+)"', re.S)
    for m in pat.finditer(html):
        vid, name = m.group(1), m.group(2).strip()
        if vid in seen or not name:
            continue
        if _blocked(name):
            continue
        seen.add(vid)
        items.append({
            "vod_id": vid,
            "vod_name": name,
            "vod_pic": _cover(vid),
            "vod_remarks": "",
        })
    return items


def _parse_detail(html, vid):
    vo = None
    for m in re.finditer(r'<script type="application/ld\+json">(.*?)</script>', html, re.S):
        try:
            data = json.loads(m.group(1))
        except Exception:
            continue
        nodes = []
        if isinstance(data, dict):
            nodes = data.get("@graph") or [data]
        elif isinstance(data, list):
            nodes = data
        for node in nodes:
            if isinstance(node, dict) and node.get("@type") == "VideoObject":
                vo = node
                break
        if vo:
            break
    name = ""
    desc = ""
    dur = ""
    keywords = ""
    actor = ""
    year = ""
    if vo:
        name = str(vo.get("name") or "").strip()
        desc = str(vo.get("description") or "").strip()
        dur = _dur_text(vo.get("duration"))
        keywords = str(vo.get("keywords") or "").strip()
        year = str(vo.get("uploadDate") or "")[:4]
        author = vo.get("author") or {}
        if isinstance(author, dict):
            actor = str(author.get("name") or "").strip()
        elif isinstance(author, str):
            actor = author.strip()
    if not name:
        m = re.search(r"<title[^>]*>([^<]*)</title>", html)
        if m:
            name = re.sub(r"\s*\|.*$", "", m.group(1)).strip()
    cat_name = ""
    for m in re.finditer(r'<script type="application/ld\+json">(.*?)</script>', html, re.S):
        try:
            data = json.loads(m.group(1))
        except Exception:
            continue
        nodes = []
        if isinstance(data, dict):
            nodes = data.get("@graph") or [data]
        elif isinstance(data, list):
            nodes = data
        for node in nodes:
            if isinstance(node, dict) and node.get("@type") == "BreadcrumbList":
                crumbs = node.get("itemListElement") or []
                if len(crumbs) >= 2:
                    cat_name = str((crumbs[1] or {}).get("name") or "").strip()
        if cat_name:
            break
    if not cat_name:
        m = re.search(r"当前所属分类[：:]\s*([^<\s]+)", html)
        if m:
            cat_name = m.group(1).strip()
    return {
        "vod_id": str(vid),
        "vod_name": name,
        "vod_pic": _cover(vid),
        "vod_remarks": dur,
        "vod_content": desc,
        "vod_actor": actor,
        "vod_tag": keywords,
        "vod_year": year,
        "type_name": cat_name,
        "vod_play_from": "正片",
        "vod_play_url": "正片$" + str(vid),
    }


class Spider(BaseSpider):

    def getName(self):
        return "🔞91视频"

    def getDependence(self):
        return []

    def init(self, extend=None):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=False):
        return {
            "class": [{"type_id": slug, "type_name": name} for slug, name in CATS],
            "filters": {},
        }

    def homeVideoContent(self):
        try:
            html = _http_get(BASE + "/")
            items = _parse_html_cards(html)
        except Exception:
            items = []
        return {"list": items[:PAGE]}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        tid = str(tid or "")
        if tid not in CAT_IDS:
            return {"list": [], "page": pg, "pagecount": 1, "limit": PAGE, "total": 0}
        try:
            html = _http_get(BASE + "/videos/category/" + tid + "/?page=" + str(pg))
            items, total = _parse_jsonld_list(html)
            if not items:
                items = _parse_html_cards(html)
        except Exception:
            items, total = [], 0
        pagecount = max(1, (total + PAGE - 1) // PAGE) if total else (1 if items else 1)
        if total == 0 and items:
            pagecount = pg + 1
        return {"list": items, "page": pg, "pagecount": pagecount, "limit": PAGE, "total": total}

    def detailContent(self, ids):
        if isinstance(ids, str):
            ids = [ids]
        vid = str(ids[0]) if ids else ""
        if not vid:
            return {"list": []}
        try:
            html = _http_get(BASE + "/videos/" + vid + "/")
            if _blocked(re.search(r"<title[^>]*>([^<]*)</title>", html).group(1) if re.search(r"<title[^>]*>([^<]*)</title>", html) else ""):
                return {"list": []}
            return {"list": [_parse_detail(html, vid)]}
        except Exception:
            return {"list": []}

    def searchContent(self, key, quick=False, pg="1"):
        pg = _norm_pg(pg)
        key = str(key or "").strip()
        if not key:
            return {"list": [], "page": pg, "pagecount": 1, "limit": PAGE, "total": 0}
        url = BASE + "/videos/search/" + urllib.parse.quote(key) + "/" + str(pg) + "/"
        try:
            html = _http_get(url)
            if "没有找到" in html:
                return {"list": [], "page": pg, "pagecount": 1, "limit": PAGE, "total": 0}
            items, total = _parse_jsonld_list(html)
            if not items:
                items = _parse_html_cards(html)
        except Exception:
            items, total = [], 0
        pagecount = max(1, (total + PAGE - 1) // PAGE) if total else 1
        return {"list": items, "page": pg, "pagecount": pagecount, "limit": PAGE, "total": total}

    def playerContent(self, flag, id, vipFlags=None):
        vid = str(id or "").strip()
        if not vid:
            return {"parse": 0, "playUrl": "", "url": "", "header": {}}
        try:
            data = _http_post_json(
                BASE + "/videos/" + vid + "/playback", {},
                headers={"Referer": BASE + "/videos/" + vid + "/"},
            )
            streams = ((data or {}).get("data") or {}).get("streams") or {}
            url = str(streams.get("main") or "").strip()
        except Exception:
            url = ""
        return {
            "parse": 0,
            "playUrl": url,
            "url": url,
            "header": {"User-Agent": UA, "Referer": BASE + "/videos/" + vid + "/"},
        }

    def localProxy(self, param=None):
        try:
            p = param
            if isinstance(p, str):
                s = p.strip()
                if s.startswith("proxy://"):
                    s = s[len("proxy://"):]
                try:
                    p = json.loads(s)
                except Exception:
                    p = dict(urllib.parse.parse_qsl(s))
            if not isinstance(p, dict):
                p = {}
            target = p.get("u") or p.get("url") or ""
            if isinstance(target, list):
                target = target[0] if target else ""
            target = urllib.parse.unquote(str(target or "").strip())
            if not target.startswith("http"):
                return [404, "text/plain", b"bad url", {}]
            last = None
            for _ in range(3):
                try:
                    if requests is not None:
                        r = requests.get(target, headers={"User-Agent": UA, "Referer": BASE + "/"}, timeout=30)
                        if r.status_code in (200, 206):
                            body = r.content
                            ctype = r.headers.get("Content-Type", "application/octet-stream").split(";")[0].strip()
                            return [200, ctype, body, {}]
                        last = ValueError("HTTP %s" % r.status_code)
                    else:
                        req = urllib.request.Request(target, headers={"User-Agent": UA, "Referer": BASE + "/"})
                        with urllib.request.urlopen(req, timeout=30) as resp:
                            body = resp.read()
                            ctype = resp.headers.get_content_type()
                            return [200, ctype, body, {}]
                except Exception as e:
                    last = e
                    time.sleep(0.5)
            return [502, "text/plain", b"proxy error", {}]
        except Exception:
            return [502, "text/plain", b"proxy error", {}]

    def isVideoFormat(self, url):
        u = str(url or "").lower().split("?")[0].split("#")[0]
        return u.endswith(".m3u8") or u.endswith(".mp4") or u.endswith(".webm") or u.endswith(".ts") or u.endswith(".m4s") or u.endswith(".mov") or u.endswith(".flv")

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return {}
