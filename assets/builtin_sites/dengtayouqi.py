import re
import base64
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
        self.host = "https://www.dengtayouqi.com"
        self.ua = ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
                   "AppleWebKit/605.1.15 (KHTML, like Gecko) "
                   "Version/17.0 Mobile/15E148 Safari/604.1")
        self.classes = [
            {"type_name": "电影", "type_id": "1"},
            {"type_name": "电视剧", "type_id": "2"},
            {"type_name": "综艺", "type_id": "3"},
            {"type_name": "动漫", "type_id": "4"},
            {"type_name": "短剧", "type_id": "26"},
        ]

    def getName(self):
        return "1234影视"

    def getDependence(self):
        return []

    def init(self, extend=""):
        try:
            ext = json.loads(extend) if extend else {}
        except Exception:
            ext = {}
        if isinstance(ext, dict) and ext.get("host"):
            self.host = str(ext["host"]).rstrip("/")

    def destroy(self):
        return None

    def action(self, action=None):
        return {}

    def isVideoFormat(self, url):
        low = str(url or "").lower()
        return ".m3u8" in low or ".mp4" in low

    def manualVideoCheck(self):
        return False

    def _fetch(self, url, referer=None):
        headers = {
            "User-Agent": self.ua,
            "Referer": referer or (self.host + "/"),
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
        if best:
            return best
        if last:
            raise last
        return best

    def _abs(self, url):
        if not url:
            return ""
        url = url.strip()
        if url.startswith("//"):
            url = "https:" + url
        elif url.startswith("/"):
            url = self.host + url
        return url

    def _clean(self, text):
        text = (text or "").replace("&nbsp;", " ").replace("&amp;", "&").replace("&#39;", "'").replace("&quot;", '"')
        text = re.sub(r"<[^>]+>", "", text)
        text = re.sub(r"\s+", " ", text)
        return text.strip()

    def _cards(self, html):
        vods = []
        seen = set()
        for block in re.findall(r"<li[^>]*>(.*?)</li>", html or "", re.S | re.I):
            m = re.search(r'href="([^"]*(?:voddetail|/vod/|vod/)[^"]*\.html)"', block)
            if not m:
                continue
            href = m.group(1)
            vid = href.strip("/").split("?")[0]
            if vid in seen:
                continue
            tm = re.search(r'title="([^"]+)"', block)
            if not tm:
                continue
            pm = re.search(r'data-original="([^"]+)"', block)
            if not pm:
                pm = re.search(r'<img[^>]+src="([^"]+)"', block)
            rm = re.search(r'pic-text[^>]*>([^<]+)<', block)
            pic = self._abs(pm.group(1)) if pm else ""
            if "load.gif" in pic or "placeholder" in pic:
                pic = ""
            if not pic:
                continue
            seen.add(vid)
            vods.append({
                "vod_id": vid,
                "vod_name": self._clean(tm.group(1)),
                "vod_pic": pic,
                "vod_remarks": self._clean(rm.group(1)) if rm else "",
            })
        return vods

    def homeContent(self, filter=False):
        result = {"class": self.classes}
        try:
            html = self._fetch(self.host + "/")
            result["list"] = self._cards(html)[:30]
        except Exception:
            result["list"] = []
        return result

    def homeVideoContent(self):
        try:
            html = self._fetch(self.host + "/")
            return {"list": self._cards(html)[:30]}
        except Exception:
            return {"list": []}

    def _pagecount(self, html, cur):
        nums = [int(x) for x in re.findall(r"/vodtype/\d+-(\d+)\.html", html or "")]
        if nums:
            return max(max(nums), cur)
        return cur

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = int(pg) if str(pg).isdigit() else 1
        try:
            url = self.host + "/vodtype/" + str(tid) + "-" + str(pg) + ".html"
            html = self._fetch(url)
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
        url = self.host + "/" + vid
        html = self._fetch(url)
        tm = re.search(r"<h1[^>]*>(.*?)</h1>", html, re.S | re.I)
        title = self._clean(re.sub(r"<span[^>]*>.*?</span>", "", tm.group(1), flags=re.S)) if tm else vid
        pm = re.search(r'property="og:image" content="([^"]+)"', html)
        if not pm:
            pm = re.search(r'data-original="([^"]+)"', html)
        pic = self._abs(pm.group(1)) if pm else ""
        dm = re.search(r"剧情简介</h3>.{0,400}?<p[^>]*>([^<]{10,})</p>", html, re.S | re.I)
        if not dm:
            dm = re.search(r"剧情简介[：:\s]*([^<]{10,})", html)
        if not dm:
                    dm = re.search(r'class="[^"]*detail-content[^"]*"[^>]*>(.*?)</', html, re.S | re.I)
        if not dm:
            dm = re.search(r'剧情简介[：:]\s*(.*?)</', html, re.S | re.I)
        desc = self._clean(dm.group(1)) if dm else ""
        info = ""
        im = re.search(r'class="[^"]*(?:stui|myui)-content__detail[^"]*"[^>]*>(.*?)</div>\s*</div>', html, re.S | re.I)
        if im:
            info = self._clean(im.group(1))
        if not info:
            _flat = re.sub(r"<script.*?</script>", "", html, flags=re.S | re.I)
            _flat = re.sub(r"<style.*?</style>", "", _flat, flags=re.S | re.I)
            _flat = re.sub(r"<head.*?</head>", "", _flat, flags=re.S | re.I)
            info = self._clean(_flat)
        actor = ""
        am = re.search(r"主演[：:]\s*([^导年地类状集]+)", info)
        if am:
            actor = am.group(1).strip()
        director = ""
        dm2 = re.search(r"导演[：:]\s*([^\s]{1,30})", info)
        if dm2:
            director = dm2.group(1).strip()
        year = ""
        ym = re.search(r"年份[：:]\s*(19\d{2}|20\d{2})", info)
        if not ym:
            ym = re.search(r"(19\d{2}|20\d{2})", info)
        if ym:
            year = ym.group(1)
        area = ""
        arm = re.search(r"地区[：:]\s*([^年主导类型状更\s/]{1,12})", info)
        if arm:
            area = arm.group(1).strip()
        play_from = []
        play_urls = []
        pairs = re.findall(
            r'<h3 class="title">(.*?)</h3>.*?<ul class="stui-content__playlist[^"]*"[^>]*>(.*?)</ul>',
            html, re.S | re.I)
        if not pairs:
            pairs = [("", b) for b in re.findall(
                r'<ul class="stui-content__playlist[^"]*"[^>]*>(.*?)</ul>', html, re.S | re.I)]
        for idx, (lname, block) in enumerate(pairs):
            eps = []
            seen = set()
            for href, name in re.findall(r'href="([^"]+)"[^>]*>([^<]+)</a>', block):
                href = href.strip()
                if any(d in href for d in ("pan.quark.cn", "pan.baidu.com", "pan.xunlei.com", "aliyundrive", "alipan", "115.com", "cloud.189.cn", "pan.189.cn", "drive.uc.cn", "caiyun.139.com", "pan.wo.cn")):
                    continue
                if not href or href.startswith("javascript") or href in seen or "heji" in href:
                    continue
                seen.add(href)
                nm = self._clean(name)
                if not nm:
                    continue
                eps.append(nm + "$" + self._abs(href))
            if not eps:
                continue
            nm = self._clean(lname)
            play_from.append(nm if nm else ("线路%d" % (idx + 1)))
            play_urls.append("#".join(eps))
        if not play_urls:
            play_from = ["线路1"]
            play_urls = ["正片$" + url]
        vod = {
            "vod_id": vid,
            "vod_name": title,
            "vod_pic": pic,
            "vod_year": year,
            "vod_area": area,
            "vod_remarks": "",
            "vod_actor": actor,
            "vod_director": director,
            "vod_content": desc,
            "vod_play_from": "$$$".join(play_from),
            "vod_play_url": "$$$".join(play_urls),
        }
        return {"list": [vod]}

    def searchContent(self, key, quick=False, pg=1):
        pg = int(pg) if str(pg).isdigit() else 1
        vods = []
        try:
            url = self.host + "/vodsearch/" + urllib.parse.quote(str(key)) + "----------1---.html"
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

    def _extract_stream(self, html):
        if not html:
            return ""
        m = re.search(r"var player_aaaa\s*=\s*(\{.*?\})", html, re.S)
        if m:
            try:
                data = json.loads(m.group(1))
                u = data.get("url") or ""
                if ".m3u8" in u or ".mp4" in u:
                    return u
            except Exception:
                pass
        m = re.search(r'var\s+now\s*=\s*"([^"]+)"', html)
        if m and m.group(1).startswith("http"):
            return m.group(1)
        for cand in re.findall(r'"url"\s*:\s*"([^"]+)"', html):
            cand = cand.replace("\\/", "/")
            if ".m3u8" in cand or ".mp4" in cand:
                return cand
        m = re.search(r"player_data\s*=\s*(\{.*?\})", html, re.S)
        if m:
            try:
                data = json.loads(m.group(1))
                u = data.get("url") or ""
                if ".m3u8" in u or ".mp4" in u:
                    return u
            except Exception:
                pass
        for src in re.findall(r'<iframe[^>]+src="([^"]+)"', html):
            q = src.split("?", 1)[1] if "?" in src else ""
            for pair in q.split("&"):
                if "=" not in pair:
                    continue
                k, v = pair.split("=", 1)
                if k in ("url", "u", "play", "src"):
                    try:
                        pad = "=" * (-len(v) % 4)
                        dec = base64.urlsafe_b64decode(v + pad).decode("utf-8", "ignore")
                    except Exception:
                        dec = ""
                    if dec.startswith("http") and (".m3u8" in dec or ".mp4" in dec):
                        return dec
        flat = html.replace("\\/", "/").replace("&amp;", "&")
        m = re.search(r"(https?://[^\s\"'<>]+\.m3u8[^\s\"'<>]*)", flat)
        if m:
            return m.group(1)
        m = re.search(r"(https?://[^\s\"'<>]+\.mp4[^\s\"'<>]*)", flat)
        if m:
            return m.group(1)
        m = re.search(r"<source[^>]+src=\"([^\"]+)\"", html)
        if m:
            return self._abs(m.group(1))
        m = re.search(r"url:\s*'([^']+)'", html)
        if m and (".m3u8" in m.group(1) or ".mp4" in m.group(1)):
            return m.group(1)
        return ""

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or "").strip()
        page = raw if raw.startswith("http") else self._abs(raw)
        url = ""
        try:
            if ".m3u8" in raw or ".mp4" in raw:
                url = raw
            else:
                html = self._fetch(page)
                url = self._extract_stream(html)
                if not url:
                    im = re.search(r'<iframe[^>]+src="([^"]+)"', html)
                    if im:
                        src = self._abs(im.group(1))
                        try:
                            html2 = self._fetch(src, referer=page)
                            url = self._extract_stream(html2)
                        except Exception:
                            url = ""
        except Exception:
            url = ""
        return {
            "parse": 0,
            "playUrl": "",
            "url": url,
            "header": {
                "User-Agent": self.ua,
                "Referer": page,
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
