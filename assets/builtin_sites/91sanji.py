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
        self.host = "https://91sanji.com"
        self.ua = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                   "AppleWebKit/537.36 (KHTML, like Gecko) "
                   "Chrome/124.0.0.0 Safari/537.36")
        self.classes = [
            {"type_name": "三级片电影", "type_id": "category"},
            {"type_name": "国产三级片", "type_id": "category/chinese-sex-movies"},
            {"type_name": "香港三级片", "type_id": "category/hong-kong-sex-movies"},
            {"type_name": "日本三级片", "type_id": "category/japanese-sex-movies"},
            {"type_name": "韩国三级片", "type_id": "category/korean-sex-movies"},
            {"type_name": "欧美三级片", "type_id": "category/western-sex-movies"},
            {"type_name": "东南亚三级片", "type_id": "category/southeast-asian-sex-movies"},
            {"type_name": "AI成人电影", "type_id": "ai"},
            {"type_name": "AI成人短剧", "type_id": "ai/drama"},
            {"type_name": "AI漫剧", "type_id": "ai/comic"},
            {"type_name": "明星", "type_id": "idx:star"},
            {"type_name": "国产明星", "type_id": "idx:star/chinese-stars"},
            {"type_name": "香港明星", "type_id": "idx:star/hong-kong-stars"},
            {"type_name": "日本明星", "type_id": "idx:star/japanese-stars"},
            {"type_name": "韩国明星", "type_id": "idx:star/korean-stars"},
            {"type_name": "欧美明星", "type_id": "idx:star/western-stars"},
            {"type_name": "东南亚明星", "type_id": "idx:star/southeast-asian-stars"},
            {"type_name": "AI明星", "type_id": "idx:star/ai"},
            {"type_name": "热门榜单", "type_id": "idx:ranking"},
            {"type_name": "视频热播榜", "type_id": "ranking/videos"},
            {"type_name": "AI热播榜", "type_id": "ranking/ai"},
            {"type_name": "标签热看榜", "type_id": "idx:ranking/tags"},
            {"type_name": "明星热播榜", "type_id": "idx:ranking/stars"},
        ]
        self.ranking_entries = [
            {"vod_id": "ranking/videos", "vod_name": "视频热播榜", "vod_pic": "",
             "vod_remarks": "榜单", "vod_tag": "folder"},
            {"vod_id": "ranking/ai", "vod_name": "AI热播榜", "vod_pic": "",
             "vod_remarks": "榜单", "vod_tag": "folder"},
            {"vod_id": "idx:ranking/tags", "vod_name": "标签热看榜", "vod_pic": "",
             "vod_remarks": "榜单", "vod_tag": "folder"},
            {"vod_id": "idx:ranking/stars", "vod_name": "明星热播榜", "vod_pic": "",
             "vod_remarks": "榜单", "vod_tag": "folder"},
        ]

    def init(self, extend=""):
        try:
            ext = json.loads(extend) if extend else {}
        except Exception:
            ext = {}
        if isinstance(ext, dict) and ext.get("host"):
            self.host = str(ext["host"]).rstrip("/")

    def getName(self):
        return "91三级"

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
            html = self._fetch(self.host + "/")
            result["list"] = self._any_cards(self._body(html))[:40]
        except Exception:
            result["list"] = []
        return result

    def homeVideoContent(self):
        try:
            html = self._fetch(self.host + "/")
            return {"list": self._any_cards(self._body(html))[:40]}
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
        for _ in range(6):
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
        if len(best) > 8000:
            return best
        if last:
            raise last
        return best

    def _pic(self, url):
        if not url:
            return ""
        if url.startswith("//"):
            url = "https:" + url
        elif url.startswith("/"):
            url = self.host + url
        if "pic.drleao.cn" in url:
            m = re.search(r"pic\.drleao\.cn/(.*?)\?", url)
            if m:
                url = self.host + "/og/cover/" + m.group(1)
            else:
                url = self.host + "/og/cover/cover.jpg"
        return url

    def _star_pic(self, url):
        if not url or "pic.drleao.cn" in url:
            return ""
        return self._pic(url)

    def _body(self, html):
        start = html.find("</header>")
        if start > 0:
            html = html[start:]
        end = html.find("<footer")
        if end > 0:
            html = html[:end]
        return html

    def _page_url(self, path, page):
        page = int(page) if str(page).isdigit() else 1
        base = self.host + "/" + path.strip("/") + "/"
        if page <= 1:
            return base
        if path in ("category", "ai", "star") or path.startswith("tag/"):
            return base + "page/%d/" % page
        if path in ("ai/drama", "ai/comic"):
            return base + "%d/" % page
        return base

    def _pagecount(self, html, path, cur):
        nums = []
        if path in ("category", "ai", "star") or path.startswith("tag/"):
            nums = [int(x) for x in re.findall(r"/page/(\d+)/", html)]
        elif path in ("ai/drama", "ai/comic"):
            nums = [int(x) for x in re.findall(r"/" + re.escape(path) + r"/(\d+)/", html)]
        if nums:
            return max(max(nums), cur)
        return cur

    def _video_cards(self, html):
        vods = []
        seen = set()
        for block in html.split('<article class="video-card">')[1:]:
            m = re.search(r'href="/video/(\d+)/"', block)
            if not m:
                continue
            vid = "video/" + m.group(1)
            if vid in seen:
                continue
            tm = re.search(r'class="video-card__title"[^>]*>([^<]+)</a>', block)
            if not tm:
                continue
            seen.add(vid)
            im = re.search(r'data-enc-src="([^"]+)"', block) or re.search(r'<img[^>]+src="([^"]+)"', block)
            dm = re.search(r'class="duration">([^<]+)<', block)
            vods.append({
                "vod_id": vid,
                "vod_name": tm.group(1).strip(),
                "vod_pic": self._pic(im.group(1)) if im else "",
                "vod_remarks": dm.group(1).strip() if dm else "",
            })
        return vods

    def _drama_cards(self, html):
        vods = []
        seen = set()
        for block in html.split('<a class="drama-card"')[1:]:
            m = re.search(r'href="/video/(\d+)/"', block)
            if not m:
                continue
            vid = "video/" + m.group(1)
            if vid in seen:
                continue
            im = re.search(r'data-enc-src="([^"]+)"', block)
            am = re.search(r'<img[^>]+alt="([^"]+)"', block)
            if not am:
                continue
            seen.add(vid)
            text = re.sub(r"<[^>]+>", " ", block[:900])
            text = re.sub(r"\s+", " ", text).strip()
            remarks = ""
            rm = re.search(r"(完结|连载中?|更新至)[^A-Za-z0-9]{0,4}(\d+\s*集)?", text)
            if rm:
                remarks = rm.group(0).strip()
            vods.append({
                "vod_id": vid,
                "vod_name": am.group(1).strip(),
                "vod_pic": self._pic(im.group(1)) if im else "",
                "vod_remarks": remarks,
            })
        return vods

    def _rank_videos(self, html):
        vods = []
        seen = set()
        for m in re.finditer(r'<a class="rank-title" href="/video/(\d+)/">([^<]+)</a>', html):
            vid = "video/" + m.group(1)
            if vid in seen:
                continue
            seen.add(vid)
            window = html[max(0, m.start() - 1000):m.start()]
            im = re.findall(r'data-enc-src="([^"]+)"', window)
            vods.append({
                "vod_id": vid,
                "vod_name": m.group(2).strip(),
                "vod_pic": self._pic(im[-1]) if im else "",
                "vod_remarks": "热播榜",
            })
        return vods

    def _rank_ai_cards(self, html):
        vods = []
        seen = set()
        for block in html.split('<a class="rank-ai-card"')[1:]:
            m = re.search(r'href="/video/(\d+)/"', block)
            if not m:
                continue
            vid = "video/" + m.group(1)
            if vid in seen:
                continue
            am = re.search(r'<img[^>]+alt="([^"]+)"', block)
            if not am:
                continue
            seen.add(vid)
            im = re.search(r'data-enc-src="([^"]+)"', block)
            vods.append({
                "vod_id": vid,
                "vod_name": am.group(1).strip(),
                "vod_pic": self._pic(im.group(1)) if im else "",
                "vod_remarks": "AI热播榜",
            })
        return vods

    def _any_cards(self, html):
        vods = self._video_cards(html)
        seen = {v["vod_id"] for v in vods}
        for v in self._drama_cards(html):
            if v["vod_id"] not in seen:
                seen.add(v["vod_id"])
                vods.append(v)
        return vods

    def _video_list(self, path, page):
        html = self._body(self._fetch(self._page_url(path, page)))
        if path == "ranking/ai":
            vods = self._rank_ai_cards(html)
        elif 'class="video-card"' in html:
            vods = self._video_cards(html)
        elif 'class="drama-card"' in html:
            vods = self._drama_cards(html)
        else:
            vods = self._rank_videos(html)
        return vods, self._pagecount(html, path, page)

    def _star_folders(self, path, page):
        html = self._body(self._fetch(self._page_url(path, page)))
        vods = []
        seen = set()
        for block in html.split('<a class="star-card"')[1:]:
            m = re.search(r'href="(/star/[A-Za-z0-9\-]+/)"', block)
            if not m:
                continue
            sid = m.group(1).strip("/")
            if sid in seen or sid in ("star/chinese-stars", "star/hong-kong-stars",
                                      "star/japanese-stars", "star/korean-stars",
                                      "star/western-stars", "star/southeast-asian-stars",
                                      "star/ai"):
                continue
            seen.add(sid)
            nm = re.search(r"<h2[^>]*>([^<]+)</h2>", block)
            if not nm:
                continue
            im = re.search(r'data-enc-src="([^"]+)"', block)
            pic = im.group(1) if im else ""
            sm = re.search(r"<span>([^<]*影片[^<]*)</span>", block)
            vods.append({
                "vod_id": sid,
                "vod_name": nm.group(1).strip(),
                "vod_pic": self._star_pic(pic),
                "vod_remarks": sm.group(1).strip() if sm else "明星",
                "vod_tag": "folder",
            })
        if not vods:
            for m in re.finditer(r'<a class="rank-title" href="/star/([A-Za-z0-9\-]+)/">([^<]+)</a>', html):
                sid = "star/" + m.group(1)
                if sid in seen:
                    continue
                seen.add(sid)
                window = html[max(0, m.start() - 700):m.start()]
                im = re.findall(r'data-enc-src="([^"]+)"', window)
                tail = html[m.end():m.end() + 200]
                sm = re.search(r"(\d+\s*部影片)", tail)
                vods.append({
                    "vod_id": sid,
                    "vod_name": m.group(2).strip(),
                    "vod_pic": self._star_pic(im[-1]) if im else "",
                    "vod_remarks": sm.group(1) if sm else "明星热播榜",
                    "vod_tag": "folder",
                })
        return vods, self._pagecount(html, path, page)

    def _tag_folders(self, page):
        html = self._body(self._fetch(self.host + "/ranking/tags/"))
        vods = []
        seen = set()
        for m in re.finditer(r'href="/tag/([A-Za-z0-9\-]+|[^"/]+)/"[^>]*>([^<]{1,30})</a>', html):
            slug = m.group(1)
            name = m.group(2).strip()
            tid = "tag/" + slug
            if tid in seen or not name:
                continue
            seen.add(tid)
            vods.append({
                "vod_id": tid,
                "vod_name": name,
                "vod_pic": "",
                "vod_remarks": "标签",
                "vod_tag": "folder",
            })
        return vods, 1

    def _star_works(self, path, page):
        html = self._body(self._fetch(self.host + "/" + path.strip("/") + "/"))
        idx = html.find("参演作品")
        scope = html[idx:] if idx > 0 else html
        for cut in ("相关推荐", "热门明星", "<footer"):
            j = scope.find(cut)
            if j > 0:
                scope = scope[:j]
        return self._video_cards(scope), 1

    def categoryContent(self, tid, pg, filter, extend):
        pg = int(pg) if str(pg).isdigit() else 1
        try:
            if tid == "idx:ranking":
                vods, total = list(self.ranking_entries), 1
            elif tid == "idx:ranking/tags":
                vods, total = self._tag_folders(pg)
            elif tid.startswith("idx:"):
                vods, total = self._star_folders(tid[4:], pg)
            elif tid.startswith("star/"):
                vods, total = self._star_works(tid, pg)
            else:
                vods, total = self._video_list(tid, pg)
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
        info = {}
        for dt, dd in re.findall(r"<dt>([^<]+)</dt><dd>(.*?)</dd>", html, re.S):
            info[dt.strip()] = re.sub(r"<[^>]+>", "", dd).strip()
        dm = re.search(r'"description":"((?:[^"\\]|\\.)*)"', html)
        desc = ""
        if dm:
            desc = re.sub(r"\\u([0-9a-fA-F]{4})",
                          lambda m: chr(int(m.group(1), 16)),
                          dm.group(1)).replace('\\"', '"').strip()
        lines = []
        em = re.search(r'class="ep-grid">(.*?)</div>', html, re.S)
        if em:
            for href, name in re.findall(r'href="(/video/\d+/episode/\d+/)"[^>]*>([^<]+)</a>', em.group(1)):
                lines.append(name.strip() + "$" + self.host + href)
        if not lines:
            lines.append("正片$" + url)
        vod = {
            "vod_id": vid,
            "vod_name": title,
            "vod_pic": self._pic(pic),
            "vod_year": info.get("年份", ""),
            "vod_area": info.get("地区", ""),
            "vod_remarks": info.get("类型", "") or info.get("片长", ""),
            "vod_actor": info.get("主演", ""),
            "vod_director": info.get("导演", ""),
            "vod_content": desc,
            "vod_play_from": "91三级",
            "vod_play_url": "#".join(lines),
        }
        return {"list": [vod]}

    def searchContent(self, key, quick, pg="1"):
        pg = int(pg) if str(pg).isdigit() else 1
        vods = []
        try:
            url = self.host + "/search/" + urllib.parse.quote(str(key)) + "/"
            html = self._body(self._fetch(url))
            vods = self._any_cards(html)
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
        try:
            if ".m3u8" in str(id):
                url = str(id)
            else:
                if str(id).startswith("http"):
                    page = str(id)
                else:
                    page = self.host + "/" + str(id).strip("/") + "/"
                html = self._fetch(page)
                m = re.search(r'"videoSrc":"(https?://[^"]+?\.m3u8[^"]*)"', html)
                if not m:
                    m = re.search(r'"contentUrl":"(https?://[^"]+?\.m3u8[^"]*)"', html)
                if m:
                    url = m.group(1).replace("\\u0026", "&").replace("\\/", "/")
        except Exception:
            url = ""
        return {
            "parse": 0,
            "playUrl": "",
            "url": url,
            "header": {
                "User-Agent": self.ua,
                "Referer": self.host + "/",
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
