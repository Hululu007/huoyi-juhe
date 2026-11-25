import base64
import json
import re
import urllib.error
import urllib.parse
import urllib.request

try:
    from base.spider import BaseSpider
except Exception:
    try:
        from base import BaseSpider
    except Exception:
        class BaseSpider:
            pass


SITE = {"host": "https://toptv15.cyou", "name": "柠果", "mode": "html", "classes": [], "type_url": "/index.php/vod/type/id/{tid}/page/{pg}.html", "search_url": ""}


class Spider(BaseSpider):
    def __init__(self):
        self.host = SITE["host"]
        self.name = SITE["name"]
        self.mode = SITE["mode"]
        self.classes = [dict(c) for c in SITE["classes"]]
        self.type_url = SITE["type_url"]
        self.search_url = SITE["search_url"]
        self.ua = (
            "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 "
            "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
        )

    def getName(self):
        return self.name

    def getDependence(self):
        return []

    def init(self, extend=""):
        ext = {}
        try:
            ext = json.loads(extend) if extend else {}
        except Exception:
            ext = {}
        if isinstance(ext, dict):
            if ext.get("host"):
                self.host = str(ext["host"]).rstrip("/")
            if ext.get("name"):
                self.name = str(ext["name"])
            if ext.get("mode"):
                self.mode = str(ext["mode"])
            if isinstance(ext.get("classes"), list):
                self.classes = [
                    {
                        "type_id": str(c.get("type_id", "")),
                        "type_name": str(c.get("type_name", "")),
                    }
                    for c in ext["classes"]
                    if isinstance(c, dict) and c.get("type_id") != ""
                ]
            if ext.get("type_url"):
                self.type_url = str(ext["type_url"])
            if ext.get("search_url"):
                self.search_url = str(ext["search_url"])
        return None

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
            "Accept": "text/html,application/json,*/*",
            "Accept-Encoding": "gzip",
            "Connection": "close",
        }
        import http.client
        import zlib

        best = ""
        last = None
        for _ in range(3):
            raw = b""
            try:
                req = urllib.request.Request(url, headers=headers)
                with urllib.request.urlopen(req, timeout=25) as r:
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
            if "</html>" in text or text.strip().startswith("{"):
                return text
        if best:
            return best
        if last:
            raise last
        return best

    def _abs(self, url):
        if not url:
            return ""
        url = str(url).strip()
        if url.startswith("//"):
            url = "https:" + url
        elif url.startswith("/"):
            url = self.host + url
        return url

    def _clean(self, text):
        text = (text or "").replace("&nbsp;", " ").replace("&amp;", "&")
        text = text.replace("&#39;", "'").replace("&quot;", '"').replace("&lt;", "<").replace("&gt;", ">")
        text = re.sub(r"<[^>]+>", "", text)
        text = re.sub(r"\s+", " ", text)
        return text.strip()

    def _pg(self, pg):
        try:
            pg = int(pg)
        except Exception:
            pg = 1
        return pg if pg >= 1 else 1

    # ------------------------------------------------------------- api mode
    def _api(self, params):
        q = urllib.parse.urlencode(params)
        url = self.host + "/api.php/provide/vod/?" + q
        text = self._fetch(url)
        try:
            return json.loads(text)
        except Exception:
            return {}

    def _api_classes(self, data):
        out = []
        for c in data.get("class") or []:
            if not isinstance(c, dict):
                continue
            tid = str(c.get("type_id", ""))
            tname = str(c.get("type_name", "")).strip()
            if tid:
                out.append({"type_id": tid, "type_name": tname or tid})
        return out

    def _api_cards(self, rows):
        vods = []
        for v in rows or []:
            if not isinstance(v, dict):
                continue
            vods.append(
                {
                    "vod_id": str(v.get("vod_id", "")),
                    "vod_name": str(v.get("vod_name", "")),
                    "vod_pic": str(v.get("vod_pic", "")),
                    "vod_remarks": str(v.get("vod_remarks", "") or v.get("type_name", "")),
                }
            )
        return vods

    def _api_page(self, params, pg):
        params = dict(params)
        params["ac"] = "detail"
        params["pg"] = pg
        data = self._api(params)
        vods = self._api_cards(data.get("list"))
        try:
            pagecount = int(data.get("pagecount") or pg)
        except Exception:
            pagecount = pg
        try:
            total = int(data.get("total") or len(vods))
        except Exception:
            total = len(vods)
        return {
            "list": vods,
            "page": pg,
            "pagecount": pagecount,
            "limit": max(len(vods), 1),
            "total": total,
        }

    def _home_api(self):
        result = {"class": list(self.classes), "list": []}
        try:
            data = self._api({"ac": "detail", "pg": 1})
            result["list"] = self._api_cards(data.get("list"))[:30]
            if not result["class"]:
                result["class"] = self._api_classes(data)
        except Exception:
            pass
        if not result["class"]:
            try:
                data = self._api({"ac": "list", "pg": 1})
                result["class"] = self._api_classes(data)
                if not result["list"]:
                    result["list"] = self._api_cards(data.get("list"))[:30]
            except Exception:
                pass
        return result

    def _detail_api(self, vid):
        data = self._api({"ac": "detail", "ids": vid})
        rows = data.get("list") or []
        if not rows:
            return {"list": []}
        v = rows[0]
        vod = {
            "vod_id": str(v.get("vod_id", vid)),
            "vod_name": str(v.get("vod_name", "")),
            "vod_pic": str(v.get("vod_pic", "")),
            "vod_year": str(v.get("vod_year", "")),
            "vod_area": str(v.get("vod_area", "")),
            "vod_remarks": str(v.get("vod_remarks", "")),
            "vod_actor": str(v.get("vod_actor", "")),
            "vod_director": str(v.get("vod_director", "")),
            "vod_content": self._clean(str(v.get("vod_content", ""))),
            "vod_play_from": str(v.get("vod_play_from", "")),
            "vod_play_url": str(v.get("vod_play_url", "")),
        }
        return {"list": [vod]}

    # ------------------------------------------------------------ html mode
    def _nav_classes(self, html):
        out = []
        seen = set()
        pat = re.compile(
            r'href="([^"]*(?:index\.php/vod/type/id/|vodtype/|vodshow/|vod/type/id/|/type/)[^"]*)"[^>]*>([^<]{1,20})<',
            re.I,
        )
        for href, name in pat.findall(html or ""):
            name = self._clean(name)
            m = re.search(r"(?:id/|vodtype/|vodshow/|/type/)(\d+)", href)
            if not m or not name:
                continue
            tid = m.group(1)
            if tid in seen:
                continue
            seen.add(tid)
            out.append({"type_id": tid, "type_name": name})
        if not out:
            pat2 = re.compile(r'href="([^"]*(?:vodtype/|vodshow/|/type/|index\.php/vod/type/id/)[^"]*)"[^>]*>(.*?)</a>', re.I | re.S)
            for href, inner in pat2.findall(html or ""):
                name = self._clean(inner)
                m = re.search(r"(?:id/|vodtype/|vodshow/|/type/)(\d+)", href)
                if not m or not name or len(name) > 20:
                    continue
                tid = m.group(1)
                if tid in seen:
                    continue
                seen.add(tid)
                out.append({"type_id": tid, "type_name": name})
        return out

    def _type_url_for(self, tid, pg):
        if self.type_url:
            return self.host + self.type_url.replace("{tid}", str(tid)).replace("{pg}", str(pg))
        return self.host + "/index.php/vod/type/id/%s-%s.html" % (tid, pg) if pg > 1 else self.host + "/index.php/vod/type/id/%s.html" % tid

    def _cards(self, html):
        vods = []
        seen = set()
        blocks = re.findall(r"<li[^>]*>(.*?)</li>", html or "", re.S | re.I)
        blocks += re.findall(r"<a[^>]*href=\"[^\"]+\"[^>]*>.*?</a>", html or "", re.S | re.I)
        detail_pat = re.compile(
            r'href="([^"]*(?:index\.php/vod/detail/id/\d+|voddetail/|vod/detail/|/vod/\d+\.html|detail/id/\d+)[^"]*)"',
            re.I,
        )
        for block in blocks:
            m = detail_pat.search(block)
            if not m:
                continue
            href = m.group(1)
            if href in seen:
                continue
            tm = re.search(r'title="([^"]+)"', block)
            if not tm:
                tm = re.search(r'alt="([^"]+)"', block)
            if not tm:
                tm = re.search(r"<h[234][^>]*>(?:<a[^>]*>)?([^<]{1,80})<", block)
            if not tm:
                tm = re.search(r">([^<>]{2,80})</a>", block)
            if not tm:
                continue
            name = self._clean(tm.group(1))
            if not name:
                continue
            pm = re.search(r'data-original="([^"]+)"', block)
            if not pm:
                pm = re.search(r'data-src="([^"]+)"', block)
            if not pm:
                pm = re.search(r'<img[^>]+src="([^"]+)"', block)
            pic = self._abs(pm.group(1)) if pm else ""
            if "load.gif" in pic or "placeholder" in pic or "noimg" in pic:
                pic = ""
            rm = re.search(r'(?:pic-text|pic_text|remarks|note)[^>]*>([^<]+)<', block)
            seen.add(href)
            vods.append(
                {
                    "vod_id": href,
                    "vod_name": name,
                    "vod_pic": pic,
                    "vod_remarks": self._clean(rm.group(1)) if rm else "",
                }
            )
        if not vods:
            vods = self._cards_vodplay(html)
        return vods

    def _cards_vodplay(self, html):
        vods = []
        seen = set()
        for m in re.finditer(r'href="([^"]*vodplay/\d+-\d+-\d+(?:\.html|/?))"', html or ""):
            href = m.group(1)
            if href in seen:
                continue
            seen.add(href)
            win = html[max(0, m.start() - 300): m.start() + 2600]
            tm = re.search(r'class="title"[^>]*>\s*<a[^>]*>([^<]{2,120})</a>', win)
            if not tm:
                tm = re.search(r'<a[^>]+href="' + re.escape(href) + r'"[^>]*>([^<]{2,120})</a>', win)
            if not tm:
                tm = re.search(r'href="' + re.escape(href) + r'"[^>]*\stitle="([^"]{2,120})"', win)
            if not tm:
                tm = re.search(r'class="desc"[^>]*>([^<]{2,120})<', win)
            if not tm:
                tm = re.search(r'class="title"[^>]*title="([^"]{2,120})"', win)
            if not tm:
                continue
            name = self._clean(tm.group(1))
            if not name:
                continue
            pic = ""
            for pm in re.finditer(r'data-src="([^"]+)"', win):
                cand = pm.group(1)
                if "lazyload" in cand or "placeholder" in cand or "load.gif" in cand:
                    continue
                pic = self._abs(cand)
                break
            if not pic:
                pm = re.search(r'<img[^>]+src="([^"]+)"', win)
                if pm and "lazyload" not in pm.group(1) and "placeholder" not in pm.group(1):
                    pic = self._abs(pm.group(1))
            vods.append(
                {
                    "vod_id": self._abs(href),
                    "vod_name": name,
                    "vod_pic": pic,
                    "vod_remarks": "",
                }
            )
        return vods

    def _pagecount(self, html, cur):
        nums = []
        for x in re.findall(r"[-/](\d+)\.html", html or ""):
            try:
                nums.append(int(x))
            except Exception:
                pass
        return max([cur] + nums) if nums else cur

    def _home_html(self):
        result = {"class": list(self.classes), "list": []}
        try:
            html = self._fetch(self.host + "/")
            if not result["class"]:
                result["class"] = self._nav_classes(html)
            result["list"] = self._cards(html)[:30]
        except Exception:
            pass
        return result

    def _detail_html(self, vid):
        url = vid if str(vid).startswith("http") else self._abs(str(vid))
        html = self._fetch(url)
        tm = re.search(r"<h1[^>]*>(.*?)</h1>", html, re.S | re.I)
        title = ""
        if tm:
            title = self._clean(re.sub(r"<span[^>]*>.*?</span>", "", tm.group(1), flags=re.S))
            if title in ("在线播放", "播放", "在线观看", "影片播放", "视频播放", "详情", "播放器"):
                title = ""
        if not title:
            tm = re.search(r'property="og:title" content="([^"]+)"', html)
            title = self._clean(tm.group(1)) if tm else ""
        pm = re.search(r'property="og:image" content="([^"]+)"', html)
        if not pm:
            pm = re.search(r'data-original="([^"]+)"', html)
        pic = self._abs(pm.group(1)) if pm else ""
        if not pic:
            for pm2 in re.finditer(r'data-src="([^"]+)"', html):
                cand = pm2.group(1)
                if "lazyload" in cand or "placeholder" in cand or "load.gif" in cand:
                    continue
                pic = self._abs(cand)
                break
        dm = re.search(r'property="og:description" content="([^"]+)"', html)
        desc = self._clean(dm.group(1)) if dm else ""
        if not desc:
            dm = re.search(r"(?:剧情简介|简介)[：:\s]*(?:</[^>]+>\s*)*([^<]{10,})", html)
            desc = self._clean(dm.group(1)) if dm else ""
        flat = re.sub(r"<script.*?</script>", "", html, flags=re.S | re.I)
        flat = re.sub(r"<style.*?</style>", "", flat, flags=re.S | re.I)
        info = self._clean(flat)
        actor = ""
        am = re.search(r"主演[：:]\s*([^导年地类状集]{1,80})", info)
        if am:
            actor = am.group(1).strip()
        director = ""
        dm2 = re.search(r"导演[：:]\s*([^\s]{1,30})", info)
        if dm2:
            director = dm2.group(1).strip()
        year = ""
        ym = re.search(r"(?:年份|年代)[：:]\s*(19\d{2}|20\d{2})", info)
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
        blocks = re.findall(
            r"<ul[^>]*class=\"[^\"]*(?:playlist|play-list|play_list|content__list)[^\"]*\"[^>]*>(.*?)</ul>",
            html,
            re.S | re.I,
        )
        if not blocks:
            blocks = [
                b
                for b in re.findall(r"<ul[^>]*>(.*?)</ul>", html, re.S | re.I)
                if re.search(r"vod/play|vodplay|/play/", b)
            ]
        heads = re.findall(
            r"<h[23][^>]*>([^<]{1,30})</h[23]>\s*<ul[^>]*class=\"[^\"]*(?:playlist|play-list|play_list)",
            html,
            re.S | re.I,
        )
        for idx, block in enumerate(blocks):
            eps = []
            seen = set()
            for href, name in re.findall(r'href="([^"]+)"[^>]*>([^<]*)</a>', block):
                href = href.strip()
                if not href or href.startswith("javascript") or href in seen:
                    continue
                if not re.search(r"vod/play|vodplay|/play/", href):
                    continue
                if any(d in href for d in ("pan.quark.cn", "pan.baidu.com", "alipan", "115.com", "cloud.189.cn")):
                    continue
                seen.add(href)
                nm = self._clean(name) or ("第%d集" % (len(eps) + 1))
                eps.append(nm + "$" + self._abs(href))
            if not eps:
                continue
            nm = self._clean(heads[idx]) if idx < len(heads) else ""
            play_from.append(nm if nm else ("线路%d" % (idx + 1)))
            play_urls.append("#".join(eps))
        if not play_urls:
            eps = []
            seen_eps = set()
            idm = re.search(r"(?:vodplay/|detail/id/|play/id/)(\d+)", str(vid))
            myid = idm.group(1) if idm else ""
            for href in re.findall(r'href="([^"]*(?:vod/play/|vodplay/|/play/)[^"]*)"', html):
                href = href.strip()
                if not href or href.startswith("javascript") or href in seen_eps:
                    continue
                if myid and not re.search(r"(?:vodplay/|detail/id/|play/id/)" + myid + r"(?:[-/.])", href):
                    continue
                if any(d in href for d in ("pan.quark.cn", "pan.baidu.com", "alipan", "115.com", "cloud.189.cn")):
                    continue
                seen_eps.add(href)
                eps.append(("第%d集" % (len(eps) + 1)) + "$" + self._abs(href))
            if eps:
                play_from = ["正片"]
                play_urls = ["#".join(eps)]
        if not play_urls:
            pobj = self._player_obj(html)
            vdata = pobj.get("vod_data") if isinstance(pobj.get("vod_data"), dict) else {}
            if vdata.get("vod_name") and not title:
                title = self._clean(str(vdata.get("vod_name")))
            if not actor and vdata.get("vod_actor"):
                actor = str(vdata.get("vod_actor"))
            if not director and vdata.get("vod_director"):
                director = str(vdata.get("vod_director"))
            if pobj:
                play_from = [str(pobj.get("from") or "正片")]
                play_urls = ["正片$" + url]
            else:
                play_from = ["正片"]
                play_urls = ["正片$" + url]
        if not title:
            tm2 = re.search(r"<title>([^<]+)</title>", html, re.I)
            if tm2:
                t = self._clean(tm2.group(1))
                t = re.sub(r"\s*[|｜].*$", "", t)
                t = re.sub(r"(HD)?(在线播放|在线观看).*$", "", t).strip()
                title = t or str(vid)
        title = re.sub(r"^资源名称[:：]\s*", "", title)
        vod = {
            "vod_id": str(vid),
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

    # -------------------------------------------------------------- protocol
    def homeContent(self, filter=False):
        if self.mode == "api":
            return self._home_api()
        return self._home_html()

    def homeVideoContent(self):
        home = self.homeContent()
        return {"list": home.get("list", [])}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = self._pg(pg)
        if self.mode == "api":
            try:
                return self._api_page({"t": tid}, pg)
            except Exception:
                return {"list": [], "page": pg, "pagecount": pg, "limit": 1, "total": 0}
        try:
            url = self._type_url_for(tid, pg)
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
            vid = str(ids[0])
        else:
            vid = str(ids)
        if self.mode == "api":
            return self._detail_api(vid)
        return self._detail_html(vid)

    def searchContent(self, key, quick=False, pg=1):
        pg = self._pg(pg)
        if self.mode == "api":
            try:
                return self._api_page({"wd": str(key)}, pg)
            except Exception:
                return {"list": [], "page": pg, "pagecount": pg, "limit": 1, "total": 0}
        vods = []
        try:
            if self.search_url:
                url = self.host + self.search_url.replace("{wd}", urllib.parse.quote(str(key))).replace("{pg}", str(pg))
            else:
                url = self.host + "/index.php/vod/search.html?wd=" + urllib.parse.quote(str(key))
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

    def _decode_player_url(self, data):
        u = str(data.get("url") or "")
        if not u:
            return ""
        enc = data.get("encrypt")
        try:
            enc = int(enc)
        except Exception:
            enc = 0
        if enc == 1:
            u = urllib.parse.unquote(u)
        elif enc == 2:
            try:
                pad = "=" * (-len(u) % 4)
                u = base64.b64decode(u + pad).decode("utf-8", "ignore")
            except Exception:
                pass
        return u.replace("\\/", "/")

    def _player_obj(self, html):
        if not html:
            return {}
        for m in re.finditer(r"player_\w+\s*=\s*", html):
            start = html.find("{", m.end())
            if start < 0:
                continue
            depth = 0
            instr = False
            esc = False
            end = -1
            for i in range(start, len(html)):
                c = html[i]
                if instr:
                    if esc:
                        esc = False
                    elif c == "\\":
                        esc = True
                    elif c == '"':
                        instr = False
                else:
                    if c == '"':
                        instr = True
                    elif c == "{":
                        depth += 1
                    elif c == "}":
                        depth -= 1
                        if depth == 0:
                            end = i + 1
                            break
            if end < 0:
                continue
            try:
                data = json.loads(html[start:end])
            except Exception:
                continue
            if isinstance(data, dict) and data.get("url"):
                return data
        return {}

    def _extract_stream(self, html):
        if not html:
            return ""
        data = self._player_obj(html)
        if data:
            u = self._decode_player_url(data)
            if u and (".m3u8" in u or ".mp4" in u or u.startswith("http")):
                return u
        for m in re.finditer(r"player_\w+\s*=\s*(\{.*?\})\s*;?\s*</script>", html, re.S):
            try:
                data = json.loads(m.group(1))
            except Exception:
                continue
            u = self._decode_player_url(data)
            if u and (".m3u8" in u or ".mp4" in u or u.startswith("http")):
                return u
        m = re.search(r'var\s+now\s*=\s*"([^"]+)"', html)
        if m and m.group(1).startswith("http"):
            return m.group(1)
        flat = html.replace("\\/", "/").replace("&amp;", "&")
        for pat in (r"(https?://[^\s\"'<>]+\.m3u8[^\s\"'<>]*)", r"(https?://[^\s\"'<>]+\.mp4[^\s\"'<>]*)"):
            for m in re.finditer(pat, flat):
                if "#" not in m.group(1):
                    return m.group(1)
        return ""

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or "").strip()
        page = raw if raw.startswith("http") else self._abs(raw)
        url = ""
        if ".m3u8" in raw or ".mp4" in raw:
            url = raw
        else:
            try:
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
            req = urllib.request.Request(
                target,
                headers={
                    "User-Agent": self.ua,
                    "Referer": "%s://%s/" % (o.scheme, o.netloc),
                },
            )
            with urllib.request.urlopen(req, timeout=20) as r:
                return [r.status, r.headers.get("Content-Type") or "application/octet-stream", r.read(), {}]
        except Exception:
            return [502, "text/plain", b"proxy error", {}]
