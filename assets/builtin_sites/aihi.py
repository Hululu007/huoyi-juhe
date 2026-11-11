import re
import json
import urllib.request
import urllib.parse
import urllib.error

try:
    from base.spider import BaseSpider
except Exception:
    class BaseSpider:
        def init(self, extend=""):
            pass


class Spider(BaseSpider):
    def __init__(self):
        self.host = "https://aihi.cc"
        self.ua = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                   "AppleWebKit/537.36 (KHTML, like Gecko) "
                   "Chrome/124.0.0.0 Safari/537.36")
        self.classes = [
            {"type_name": "AI成人短剧", "type_id": "1"},
            {"type_name": "AI成人漫剧", "type_id": "2"},
            {"type_name": "AI换脸", "type_id": "3"},
            {"type_name": "AI魔改", "type_id": "4"},
        ]

    def init(self, extend=""):
        try:
            ext = json.loads(extend) if extend else {}
        except Exception:
            ext = {}
        if isinstance(ext, dict) and ext.get("host"):
            self.host = str(ext["host"]).rstrip("/")

    def getName(self):
        return "AIHI"

    def getDependence(self):
        return []

    def destroy(self):
        return None

    def action(self, action=None):
        return {}

    def isVideoFormat(self, url):
        return ".m3u8" in url or ".mp4" in url

    def manualVideoCheck(self):
        return False

    def homeContent(self, filter=False):
        result = {"class": self.classes}
        try:
            html = self._fetch(self.host + "/home/")
            result["list"] = self._cards(html)[:30]
        except Exception:
            result["list"] = []
        return result

    def homeVideoContent(self):
        try:
            html = self._fetch(self.host + "/home/")
            return {"list": self._cards(html)[:30]}
        except Exception:
            return {"list": []}

    def _fetch(self, url):
        headers = {
            "User-Agent": self.ua,
            "Referer": self.host + "/",
            "Accept": "text/html,application/xhtml+xml,*/*",
            "Accept-Encoding": "gzip",
            "Connection": "close",
        }
        import zlib
        import http.client
        best = ""
        last = None
        for _ in range(3):
            raw = b""
            try:
                req = urllib.request.Request(url, headers=headers)
                with urllib.request.urlopen(req, timeout=20) as r:
                    while True:
                        try:
                            chunk = r.read(65536)
                        except http.client.IncompleteRead as e:
                            raw += e.partial or b""
                            break
                        if not chunk:
                            break
                        raw += chunk
            except Exception as e:
                last = e
            try:
                if raw[:2] == b"\x1f\x8b":
                    text = zlib.decompressobj(16 + zlib.MAX_WBITS).decompress(raw).decode("utf-8", "ignore")
                else:
                    text = raw.decode("utf-8", "ignore")
            except Exception as e:
                last = e
                text = ""
            if len(text) > len(best):
                best = text
            if "</html>" in text:
                return text
        if last:
            raise last
        return best

    def _abs(self, url):
        if not url:
            return ""
        if url.startswith("//"):
            url = "https:" + url
        elif url.startswith("/"):
            url = self.host + url
        return re.sub(r"(?<!:)//+", "/", url)

    def _cards(self, html):
        vods = []
        seen = set()
        matches = list(re.finditer(r'href="/voddetail/(\d+)/"', html))
        for idx, m in enumerate(matches):
            vid = "voddetail/" + m.group(1)
            if vid in seen:
                continue
            end = matches[idx + 1].start() if idx + 1 < len(matches) else m.start() + 2000
            window = html[m.start():min(end, m.start() + 2000)]
            am = re.search(r'<img[^>]+alt="([^"]+)"', window)
            if not am:
                am = re.search(r'title="([^"]+)"', window)
            if not am:
                continue
            seen.add(vid)
            im = re.search(r'<img[^>]+src="([^"]+)"', window)
            rm = re.search(r'(更新至[^<]{0,20}集|完结|连载中)', window)
            vods.append({
                "vod_id": vid,
                "vod_name": am.group(1).strip(),
                "vod_pic": self._abs(im.group(1)) if im else "",
                "vod_remarks": rm.group(1).strip() if rm else "",
            })
        return vods

    def _page_url(self, tid, page):
        page = int(page) if str(page).isdigit() else 1
        if page <= 1:
            return self.host + "/vodtype/" + str(tid) + "/"
        return self.host + "/vodtype/" + str(tid) + "-" + str(page) + "/"

    def _pagecount(self, html, cur):
        nums = [int(x) for x in re.findall(r'/vodtype/\d+-(\d+)/', html)]
        if nums:
            return max(max(nums), cur)
        return cur

    def categoryContent(self, tid, pg, filter, extend):
        pg = int(pg) if str(pg).isdigit() else 1
        try:
            html = self._fetch(self._page_url(tid, pg))
            vods = self._cards(html)
            total = self._pagecount(html, pg)
        except Exception:
            vods, total = [], pg
        return {
            "list": vods,
            "page": pg,
            "pagecount": total,
            "limit": max(len(vods), 1),
            "total": total * max(len(vods), 1),
        }

    def detailContent(self, ids):
        if isinstance(ids, (list, tuple)):
            vid = str(ids[0]).strip("/")
        else:
            vid = str(ids).strip("/")
        url = self.host + "/" + vid + "/"
        html = self._fetch(url)
        tm = re.search(r"<h1[^>]*>([^<]+)</h1>", html)
        title = tm.group(1).strip() if tm else vid
        pm = re.search(r'property="og:image" content="([^"]+)"', html)
        pic = pm.group(1) if pm else ""
        dm = re.search(r'meta name="description" content="([^"]+)"', html)
        desc = dm.group(1).strip() if dm else ""
        eps = []
        seen = set()
        for href, name in re.findall(r'href="(/vodplay/\d+-1-\d+/)"[^>]*>([^<]+)</a>', html):
            if href in seen:
                continue
            seen.add(href)
            nm = re.search(r"-(\d+)/?$", href)
            label = ("第%s集" % nm.group(1)) if nm else name.strip()
            eps.append(label + "$" + self.host + href)
        if not eps:
            eps.append("正片$" + url)
        vod = {
            "vod_id": vid,
            "vod_name": title,
            "vod_pic": self._abs(pic),
            "vod_year": "",
            "vod_area": "",
            "vod_remarks": "",
            "vod_actor": "",
            "vod_director": "",
            "vod_content": desc,
            "vod_play_from": "AIHI",
            "vod_play_url": "#".join(eps),
        }
        return {"list": [vod]}

    def searchContent(self, key, quick, pg="1"):
        pg = int(pg) if str(pg).isdigit() else 1
        vods = []
        try:
            url = self.host + "/vodsearch/-------------.html?wd=" + urllib.parse.quote(str(key))
            html = self._fetch(url)
            vods = self._cards(html)
        except Exception:
            vods = []
        return {
            "list": vods,
            "page": pg,
            "pagecount": pg,
            "limit": max(len(vods), 1),
            "total": len(vods),
        }

    def playerContent(self, flag, id, vipFlags):
        url = ""
        page = ""
        try:
            if ".m3u8" in str(id):
                url = str(id)
            else:
                page = str(id) if str(id).startswith("http") else self.host + "/" + str(id).strip("/") + "/"
                html = self._fetch(page)
                m = re.search(r'"url":"(\d+)\|(\d+)"', html)
                if m:
                    api = self.host + "/huangguo.php?ac=play&id=" + m.group(1) + "&ep=" + m.group(2)
                    req = urllib.request.Request(api, headers={
                        "User-Agent": self.ua,
                        "Referer": page,
                        "X-Requested-With": "XMLHttpRequest",
                    })
                    with urllib.request.urlopen(req, timeout=20) as r:
                        data = json.loads(r.read().decode("utf-8", "ignore"))
                    if data.get("code") == 1 and data.get("url"):
                        url = self.host + data["url"]
        except Exception:
            url = ""
        return {
            "parse": 0,
            "playUrl": "",
            "url": url,
            "header": {
                "User-Agent": self.ua,
                "Referer": page or (self.host + "/"),
            },
        }

    def localProxy(self, param=None):
        import urllib.parse as _up
        import urllib.request as _ur
        try:
            p = param
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
                "User-Agent": self.ua,
                "Referer": "%s://%s/" % (_o.scheme, _o.netloc)})
            with _ur.urlopen(_req, timeout=20) as _r:
                return [_r.status, _r.headers.get("Content-Type") or "application/octet-stream", _r.read(), {}]
        except Exception:
            return [502, "text/plain", b"proxy error", {}]
