# -*- coding: utf-8 -*-
import base64
import gzip
import html as htmlmod
import json
import re
import sys
import time
import urllib.parse
import urllib.request



try:
    sys.path.append("..")
    from base.spider import BaseSpider
except Exception:
    class BaseSpider:
        pass

SITE = {
    "name": "AiPorn",
    "domains": ["https://www.aipornx.cc", "https://aipornx.cc"],
    "headers": {"Referer": "https://www.aipornx.cc/"},
}

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36")
TIMEOUT = 15
RETRY = 3



CLASSES = [
    {"type_id": "home", "type_name": "首页"},
    {"type_id": "latest", "type_name": "最新更新"},
    {"type_id": "/aidj/anthurium/", "type_name": "AI成人短剧"},
    {"type_id": "/aidj/camelia/", "type_name": "AI成人漫剧"},
    {"type_id": "/aidj/daisy/", "type_name": "AI换脸"},
    {"type_id": "/aidj/frangipani/", "type_name": "AI魔改"},
    {"type_id": "tags_index", "type_name": "标签选剧"},
]


TAGS_SNAPSHOT = ["现代", "都市", "奇幻", "大男主", "系统", "后宫"]


def _dec(raw):
    for enc in ("utf-8", "gb18030"):
        try:
            return raw.decode(enc)
        except Exception:
            continue
    return raw.decode("utf-8", "ignore")


def _headers():
    h = {"User-Agent": UA}
    h.update(SITE["headers"])
    return h


def _get_u3(url, extra=None):

    import os
    import urllib3
    proxy = os.environ.get("https_proxy") or os.environ.get("HTTPS_PROXY") or\
        os.environ.get("http_proxy") or os.environ.get("HTTP_PROXY")
    if proxy:
        pool = urllib3.ProxyManager(proxy, timeout=TIMEOUT)
    else:
        pool = urllib3.PoolManager(timeout=TIMEOUT)
    h = _headers()
    if extra:
        h.update(extra)
    r = pool.request("GET", url, headers=h, redirect=True)
    if r.status >= 400:
        raise IOError("http %s" % r.status)
    return _dec(r.data)


def _get_urllib(url, extra=None):
    req = urllib.request.Request(url)
    for k, v in _headers().items():
        req.add_header(k, v)
    if extra:
        for k, v in extra.items():
            req.add_header(k, v)
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        raw = r.read()
    if raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    return _dec(raw)


def http_get(url, extra=None):
    if not url.startswith("http"):
        url = SITE["domains"][0].rstrip("/") + url
    for attempt in range(RETRY):
        try:
            return _get_u3(url, extra)
        except ImportError:
            break
        except Exception:
            time.sleep(0.4 * (attempt + 1))
    for attempt in range(RETRY):
        try:
            return _get_urllib(url, extra)
        except Exception:
            time.sleep(0.5 * (attempt + 1))
    return ""


def txt_of(s):
    s = re.sub(r"(?is)<(script|style)[^>]*>.*?</\1>", " ", s or "")
    s = re.sub(r"(?s)<[^>]+>", " ", s)
    return re.sub(r"\s+", " ", htmlmod.unescape(s)).strip()


def parse_cards(html):
    out = []
    seen = set()
    for m in re.finditer(r'<article class="vod-card">(.*?)</article>', html or "", re.S):
        blk = m.group(1)
        lm = re.search(r'<a class="vod-pic" href="(/detail/\d+/)\s*"', blk)
        if not lm:
            continue
        path = lm.group(1)
        if path in seen:
            continue
        seen.add(path)
        im = re.search(r'<img[^>]+src="([^"]+)"', blk)
        pic = im.group(1) if im else ""
        if pic.startswith("https://media.hgpicimg.cc//"):
            pic = pic.replace("https://media.hgpicimg.cc//", "https://media.hgpicimg.cc/")
        nm = re.search(r'<div class="vod-name"><a[^>]*>([^<]+)</a>', blk)
        if not nm:
            nm = re.search(r'<img[^>]+alt="([^"]+)"', blk)
        rm = re.search(r'class="vod-remarks">([^<]+)<', blk)
        out.append({
            "vod_id": path,
            "vod_name": txt_of(nm.group(1)) if nm else path,
            "vod_pic": pic,
            "vod_remarks": txt_of(rm.group(1)) if rm else "",
        })
    return out


def _pagecount(html, pg):
    nums = [int(n) for n in re.findall(r'/page/(\d+)/', html or "")]
    nums += [int(n) for n in re.findall(r'class="[^"]*current[^"]*"[^>]*>\s*(\d+)', html or "")]

    for n in re.findall(r'-{10}(\d+)-', html or ""):
        nums.append(int(n))
    pc = max(nums) if nums else int(pg)
    return max(pc, int(pg))


def _listing(html, pg, limit=30):
    return {"page": int(pg), "pagecount": _pagecount(html, pg),
            "limit": limit, "total": _pagecount(html, pg) * limit,
            "list": parse_cards(html)}


class Spider(BaseSpider):
    def getName(self):
        return SITE["name"]

    def init(self, extend=""):
        self.ext = {}
        if extend:
            try:
                self.ext = json.loads(extend) if isinstance(extend, str) else dict(extend)
            except Exception:
                self.ext = {}
        host = (self.ext or {}).get("host")
        if host:
            SITE["domains"] = [str(host).rstrip("/")]

    def _host(self):
        return SITE["domains"][0].rstrip("/")


    def homeContent(self, filter=False):
        html = http_get(self._host() + "/home/")
        return {"class": CLASSES, "list": parse_cards(html)}

    def homeVideoContent(self):
        html = http_get(self._host() + "/home/")
        return {"list": parse_cards(html)}


    def categoryContent(self, tid, pg, filter, extend):
        pg = int(pg or 1)
        if tid == "home":
            html = http_get(self._host() + "/home/")
            lst = parse_cards(html)
            return {"page": 1, "pagecount": 1, "limit": len(lst) or 30,
                    "total": len(lst), "list": lst}
        if tid == "tags_index":
            return {"page": 1, "pagecount": 1, "limit": 20, "total": 6,
                    "list": self._tags_index()}
        if tid == "latest":
            if pg > 1:
                url = "%s/search/----------%d---/" % (self._host(), pg)
            else:
                url = self._host() + "/search/-------------/"
            return _listing(http_get(url), pg)
        if tid.startswith("tag:"):
            tag = tid[4:]
            q = urllib.parse.quote(tag)
            if pg > 1:
                url = "%s/search/----------%d--%s-/" % (self._host(), pg, q)
            else:
                url = "%s/search/------------%s-/" % (self._host(), q)
            return _listing(http_get(url), pg)

        path = tid if tid.startswith("/") else "/" + tid
        url = self._host() + path
        if pg > 1:
            url = url.rstrip("/") + "/page/%d/" % pg
        return _listing(http_get(url), pg)

    def _tags_index(self):
        tags = []
        html = http_get(self._host() + "/home/")
        if html:
            seen = set()
            for m in re.finditer(r'href="/search/-+%E[^"]+"[^>]*>#([^<]+)</a>', html):
                t = txt_of(m.group(1))
                if t and t not in seen:
                    seen.add(t)
                    tags.append(t)
        if not tags:
            tags = TAGS_SNAPSHOT
        return [{
            "vod_id": "tag:" + t,
            "vod_name": t,
            "vod_pic": "",
            "vod_remarks": "",
            "vod_tag": "folder",
        } for t in tags]


    def detailContent(self, ids):
        vid = ids[0] if ids else ""
        path = vid if vid.startswith("/") else "/" + vid.strip("/") + "/"
        html = http_get(self._host() + path)
        if not html:
            return {"list": []}
        vod = {"vod_id": path, "vod_name": "", "vod_pic": "", "vod_content": "",
               "vod_actor": "", "vod_director": "", "vod_area": "",
               "vod_lang": "", "vod_year": "", "vod_remarks": "", "type_name": ""}
        om = re.search(r'property="og:title" content="([^"]+)"', html)
        vod["vod_name"] = txt_of(om.group(1)) if om else ""
        if not vod["vod_name"]:
            hm = re.search(r'<div class="detail-info"><h1>([^<]+)</h1>', html)
            vod["vod_name"] = txt_of(hm.group(1)) if hm else path
        im = re.search(r'property="og:image" content="([^"]+)"', html)
        if im:
            vod["vod_pic"] = im.group(1).replace("https://media.hgpicimg.cc//",
                                                 "https://media.hgpicimg.cc/")
        dm = re.search(r'property="og:description" content="([^"]+)"', html)
        if dm:
            vod["vod_content"] = txt_of(dm.group(1))
        tags = []
        for m in re.finditer(r'class="detail-tag"[^>]*>#([^<]+)</a>', html):
            t = txt_of(m.group(1))
            if t and t not in tags:
                tags.append(t)
        vod["type_name"] = ", ".join(tags)

        eps = {}
        for m in re.finditer(r'<a class="ep[^"]*"[^>]*href="(/play/[\d\-]+/)"[^>]*>([^<]+)</a>',
                             html):
            eps[m.group(1)] = txt_of(m.group(2))
        if not eps:
            for m in re.finditer(r'href="(/play/[\d\-]+/)"[^>]*>(第[^<]*集)</a>', html):
                eps[m.group(1)] = txt_of(m.group(2))
        def _epno(p):
            mm = re.search(r'-(\d+)/$', p)
            return int(mm.group(1)) if mm else 0
        items = sorted(eps.items(), key=lambda kv: _epno(kv[0]))
        if items:
            vod["vod_play_from"] = "黄果"
            vod["vod_play_url"] = "#".join(
                "%s$%s%s" % (name, self._host(), p) for p, name in items)
            vod["vod_remarks"] = "更新至%d集" % len(items)
        return {"list": [vod]}


    def playerContent(self, flag, id, vipFlags):
        if id.startswith("http"):
            play_path = urllib.parse.urlparse(id).path
        elif id.startswith("/"):
            play_path = id
        else:
            play_path = "/" + id.strip("/") + "/"
        page_url = self._host() + play_path
        real = ""
        proxy = ""
        try:
            html = http_get(page_url)
            pd = re.search(r'player_data=(\{.*?\})</script>', html or "", re.S)
            if pd:
                data = json.loads(pd.group(1))
                raw = str(data.get("url") or "")
                parts = raw.split("|")
                if len(parts) >= 2:
                    api = "%s/huangguo.php?ac=play&id=%s&ep=%s&_=%d" % (
                        self._host(), urllib.parse.quote(parts[0]),
                        urllib.parse.quote(parts[1]), int(time.time() * 1000))
                    js = http_get(api, {"X-Requested-With": "XMLHttpRequest"})
                    d = json.loads(js) if js else {}
                    u = str(d.get("url") or "")
                    if d.get("code") == 1 and u.startswith("/huangguo.php?ac=media"):
                        proxy = self._host() + u
                    elif d.get("code") == 1 and u.startswith("/hgmedia.php?e="):
                        proxy = self._host() + u
                        token = u.split("e=", 1)[1]
                        pad = "=" * (-len(token) % 4)
                        try:
                            dec = base64.b64decode(token + pad).decode("utf-8", "ignore")
                            if dec.startswith("http") and ".m3u8" in dec:
                                real = dec
                        except Exception:
                            real = ""
        except Exception:
            real = ""
        url = real or proxy
        if url:
            return {"parse": 0, "playUrl": "", "url": url,
                    "header": {"Referer": self._host() + "/", "User-Agent": UA}}
        return {"parse": 1, "playUrl": "", "url": page_url,
                "header": {"Referer": self._host() + "/", "User-Agent": UA}}


    def searchContent(self, key, quick, pg="1"):
        pg = int(pg or 1)
        kw = urllib.parse.quote(str(key))
        if pg > 1:
            url = "%s/search/%s----------%d---/" % (self._host(), kw, pg)
        else:
            url = "%s/search/-------------/?wd=%s" % (self._host(), kw)
        return _listing(http_get(url), pg)

    def localProxy(self, params=None):


        import urllib.parse as _up
        import urllib.request as _ur
        try:
            p = params
            if isinstance(p, str):
                try:
                    p = json.loads(p)
                except Exception:
                    p = dict(_up.parse_qsl(p))
            if not isinstance(p, dict):
                p = {}
            target = p.get("url") or p.get("u") or ""
            if isinstance(target, list):
                target = target[0] if target else ""
            target = _up.unquote(str(target or "").strip())
            if not target.startswith("http"):
                return [404, "text/plain", b"bad url", {}]
            _o = _up.urlparse(target)
            _req = _ur.Request(target, headers={
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36",
                "Referer": "%s://%s/" % (_o.scheme, _o.netloc)})
            with _ur.urlopen(_req, timeout=20) as _r:
                return [_r.status, _r.headers.get("Content-Type") or "application/octet-stream", _r.read(), {}]
        except Exception:
            return [502, "text/plain", b"proxy error", {}]



    def getDependence(self):
        return []

    def destroy(self):
        return None

    def isVideoFormat(self, url=None):
        u = str(url or "").lower()
        return (".m3u8" in u) or (".mp4" in u) or (".flv" in u)

    def manualVideoCheck(self):
        return False

    def action(self, action=None):
        return {}

