import gzip
import html as html_mod
import http.cookiejar
import json
import re
import ssl
import time
import urllib.parse
import urllib.request

try:
    from base.spider import BaseSpider
except Exception:
    class BaseSpider:
        pass

UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
TIMEOUT = 25
RETRY = 3

DOMAINS = [
    "https://www.missav123.nl",
    "https://www.thisav.my",
    "https://missav.ws",
]
PRIMARY = DOMAINS[0]

PLAY_REFERER = "https://missav.ws/"
PLAY_ORIGIN = "https://missav.ws"

ROUTES = {
    "chinese-subtitle": "/dm278/cn/chinese-subtitle",
    "new": "/dm539/cn/new",
    "release": "/dm635/cn/release",
    "uncensored-leak": "/dm817/cn/uncensored-leak",
    "actresses": "/cn/actresses",
    "actresses/ranking": "/cn/actresses/ranking",
    "genres": "/cn/genres",
    "makers": "/cn/makers",
    "genres/VR": "/cn/genres/VR",
    "today-hot": "/dm301/cn/today-hot",
    "weekly-hot": "/dm170/cn/weekly-hot",
    "monthly-hot": "/dm273/cn/monthly-hot",
    "siro": "/dm36/cn/siro",
    "luxu": "/dm34/cn/luxu",
    "gana": "/dm35/cn/gana",
    "maan": "/dm1004/cn/maan",
    "scute": "/dm38/cn/scute",
    "ara": "/dm34/cn/ara",
    "fc2": "/dm597/cn/fc2",
    "heyzo": "/dm2020563/cn/heyzo",
    "tokyohot": "/dm42/cn/tokyohot",
    "1pondo": "/dm4551182/cn/1pondo",
    "caribbeancom": "/dm6840813/cn/caribbeancom",
    "caribbeancompr": "/dm78420/cn/caribbeancompr",
    "10musume": "/dm6238706/cn/10musume",
    "pacopacomama": "/dm3240472/cn/pacopacomama",
    "gachinco": "/dm150/cn/gachinco",
    "xxxav": "/dm42/cn/xxxav",
    "marriedslash": "/dm37/cn/marriedslash",
    "naughty4610": "/dm33/cn/naughty4610",
    "naughty0930": "/dm37/cn/naughty0930",
    "madou": "/dm63/cn/madou",
    "twav": "/dm31/cn/twav",
    "furuke": "/dm15/cn/furuke",
}

CATS = [
    {"type_id": "chinese-subtitle", "type_name": "中文字幕"},
    {"type_id": "new", "type_name": "最近更新"},
    {"type_id": "release", "type_name": "新作上市"},
    {"type_id": "uncensored-leak", "type_name": "无码流出"},
    {"type_id": "actresses", "type_name": "女优一览"},
    {"type_id": "actresses/ranking", "type_name": "女优排行"},
    {"type_id": "genres", "type_name": "类型"},
    {"type_id": "makers", "type_name": "发行商"},
    {"type_id": "genres/VR", "type_name": "VR"},
    {"type_id": "today-hot", "type_name": "今日热门"},
    {"type_id": "weekly-hot", "type_name": "本周热门"},
    {"type_id": "monthly-hot", "type_name": "本月热门"},
    {"type_id": "siro", "type_name": "SIRO"},
    {"type_id": "luxu", "type_name": "LUXU"},
    {"type_id": "gana", "type_name": "GANA"},
    {"type_id": "maan", "type_name": "PRESTIGE PREMIUM"},
    {"type_id": "scute", "type_name": "S-CUTE"},
    {"type_id": "ara", "type_name": "ARA"},
    {"type_id": "fc2", "type_name": "FC2"},
    {"type_id": "heyzo", "type_name": "HEYZO"},
    {"type_id": "tokyohot", "type_name": "东京热"},
    {"type_id": "1pondo", "type_name": "一本道"},
    {"type_id": "caribbeancom", "type_name": "Caribbeancom"},
    {"type_id": "caribbeancompr", "type_name": "Caribbeancompr"},
    {"type_id": "10musume", "type_name": "10musume"},
    {"type_id": "pacopacomama", "type_name": "pacopacomama"},
    {"type_id": "gachinco", "type_name": "Gachinco"},
    {"type_id": "xxxav", "type_name": "XXX-AV"},
    {"type_id": "marriedslash", "type_name": "人妻斩"},
    {"type_id": "naughty4610", "type_name": "顽皮4610"},
    {"type_id": "naughty0930", "type_name": "顽皮0930"},
    {"type_id": "madou", "type_name": "麻豆传媒"},
    {"type_id": "twav", "type_name": "TWAV"},
    {"type_id": "furuke", "type_name": "Furuke"},
]

INDEX_TIDS = {"actresses", "actresses/ranking", "genres", "makers"}
INDEX_PREFIX = {"actresses": "actresses", "actresses/ranking": "actresses",
                "genres": "genres", "makers": "makers"}

RESERVED = {"release", "new", "actresses", "genres", "makers", "search",
            "chinese-subtitle", "uncensored-leak", "login", "register",
            "history", "playlists", "tags", "dm", "vip", "saved",
            "today-hot", "weekly-hot", "monthly-hot", "ranking"}

# Path segments that are navigation, not videos: every category slug plus
# RESERVED. Uncensored makers use code shapes the old "-\d" filter
# rejected: date codes (070226_001), letter+digits (n1854, gachi1083),
# hyphen+letters (h4610-ki250316, twav-d001, c0930-gol0182).
_NON_VIDEO = RESERVED | set(ROUTES) | {c["type_id"].split("/")[-1] for c in CATS}


def _is_video_code(code):
    if not code or code in _NON_VIDEO:
        return False
    if re.search(r"-[a-z0-9]", code):
        return True
    if re.match(r"^\d+_\d+$", code):
        return True
    if re.match(r"^[a-z]+\d+$", code):
        return True
    return False

PLACEHOLDER_HINTS = ("data:image", "placeholder", "lazy", "loading", "blank",
                     "spinner", "1x1", "pixel", ".svg", "noimage", "no-image",
                     "default.jpg", "grey", "gray")


def _dec(raw):
    for enc in ("utf-8", "gb18030"):
        try:
            return raw.decode(enc)
        except Exception:
            continue
    return raw.decode("utf-8", "ignore")


def txt_of(s):
    s = re.sub(r"(?is)<(script|style)[^>]*>.*?</\1>", " ", s or "")
    s = re.sub(r"(?s)<[^>]+>", " ", s)
    return re.sub(r"\s+", " ", html_mod.unescape(s)).strip()


def pick_image(body):
    cands = []
    for m in re.finditer(r"<img[^>]*>", body or "", re.I):
        tag = m.group(0)
        for attr in ("data-src", "data-original", "data-lazy-src", "data-url", "src"):
            mm = re.search(attr + r"\s*=\s*[\"']([^\"']+)[\"']", tag, re.I)
            if mm:
                cands.append((0 if attr.startswith("data-") else 1, mm.group(1).strip()))
                break
    good = []
    for prio, url in cands:
        low = url.lower()
        if not url or url.startswith("data:"):
            continue
        if any(h in low for h in PLACEHOLDER_HINTS):
            continue
        if url.startswith("//"):
            url = "https:" + url
        elif url.startswith("/"):
            url = PRIMARY + url
        if not url.startswith("http"):
            continue
        good.append((prio, url))
    if not good:
        return ""
    good.sort()
    return good[0][1]


def fmt_duration(seconds):
    try:
        total = int(seconds)
    except Exception:
        return ""
    if total <= 0:
        return ""
    h, rem = divmod(total, 3600)
    m, s = divmod(rem, 60)
    if h:
        return "%d:%02d:%02d" % (h, m, s)
    return "%d:%02d" % (m, s)


class Spider(BaseSpider):
    ext = {}
    cookie = ""
    base = PRIMARY

    def __init__(self):
        try:
            super(Spider, self).__init__()
        except Exception:
            pass
        self.ctx = ssl.create_default_context()
        self.ctx.check_hostname = False
        self.ctx.verify_mode = ssl.CERT_NONE
        self.cj = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self.cj),
            urllib.request.HTTPSHandler(context=self.ctx))

    def getName(self):
        return "MissAV"

    def getDependence(self):
        return []

    def isVideoFormat(self, url):
        return bool(url) and ".m3u8" in str(url).lower()

    def manualVideoCheck(self):
        return False

    def destroy(self):
        return

    def init(self, extend=""):
        try:
            self.ext = json.loads(extend) if extend else {}
        except Exception:
            self.ext = {}
        if isinstance(self.ext, dict):
            self.cookie = str(self.ext.get("cookie") or "")
            dom = str(self.ext.get("domain") or "")
            if dom.startswith("http"):
                self.base = dom.rstrip("/")
                if self.base not in DOMAINS:
                    DOMAINS.insert(0, self.base)

    def _candidates(self, url):
        m = re.match(r"(https?://[^/]+)(/.*)", url or "")
        if not m:
            return [url]
        path = m.group(2)
        out = []
        for d in DOMAINS:
            p = path
            if "missav.ws" in d:
                p = re.sub(r"^/dm\d+", "", path)
            cand = d.rstrip("/") + p
            if cand not in out:
                out.append(cand)
        return out

    def http_get(self, url, referer=None):
        ref = referer or (PRIMARY + "/")
        cur = url
        for _hop in range(4):
            text = self._http_get_once(cur, ref)
            if not text:
                return ""
            m = re.search(
                r"<meta[^>]+http-equiv=[\"']?refresh[\"']?[^>]*>",
                text, re.I)
            if not m:
                return text
            u = re.search(r"url=['\"]?([^'\"\s>]+)", m.group(0), re.I)
            if not u:
                return text
            nxt = u.group(1)
            if not nxt.startswith("http"):
                nxt = urllib.parse.urljoin(cur, nxt)
            if nxt == cur:
                return text
            cur = nxt
        return ""

    def _http_get_once(self, url, ref):
        for u in self._candidates(url):
            for attempt in range(RETRY):
                try:
                    req = urllib.request.Request(u)
                    req.add_header("User-Agent", UA)
                    req.add_header("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
                    req.add_header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.6")
                    req.add_header("Accept-Encoding", "gzip, deflate")
                    req.add_header("Referer", ref)
                    if self.cookie:
                        req.add_header("Cookie", self.cookie)
                    with self.opener.open(req, timeout=TIMEOUT) as r:
                        raw = r.read()
                        if raw[:2] == b"\x1f\x8b":
                            raw = gzip.decompress(raw)
                        text = _dec(raw)
                        if re.search(
                                r"<meta[^>]+http-equiv=[\"']?refresh[\"']?[^>]*>",
                                text, re.I):
                            return text
                        if len(text) < 2000:
                            raise ValueError("body too small")
                        if "just a moment" in text.lower() and len(text) < 12000:
                            raise ValueError("cloudflare challenge")
                        return text
                except Exception:
                    time.sleep(0.4 * (attempt + 1))
        return ""

    def _unpack(self, packed_js):
        m = re.search(
            r"}\s*\(\s*['\"](.*?)['\"]\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*['\"](.*?)['\"]\s*\.split\(['\"]\|['\"]\)",
            packed_js, re.S)
        if not m:
            return ""
        p, a, c = m.group(1), int(m.group(2)), int(m.group(3))
        k = m.group(4).split("|")

        def base36(n):
            chars = "0123456789abcdefghijklmnopqrstuvwxyz"
            if n == 0:
                return "0"
            res = ""
            while n > 0:
                n, r = divmod(n, 36)
                res = chars[r] + res
            return res

        d = {base36(i): (k[i] if i < len(k) and k[i] else base36(i)) for i in range(c)}
        return re.sub(r"\b\w+\b", lambda m2: d.get(m2.group(0), m2.group(0)), p)

    def _extract_surrit_uuid(self, text):
        m = re.search(
            r"hls\.loadSource\(['\"]https?://[^/]+/([a-f0-9-]{36})/playlist\.m3u8['\"]\)",
            text or "")
        if m:
            return m.group(1)
        m = re.search(r"urls:\s*\[\s*['\"]([^'\"]+)['\"]", text or "")
        if m and "sample" not in m.group(1):
            u = re.search(r"([a-f0-9-]{36})", m.group(1))
            if u:
                return u.group(1)
        uuids = re.findall(
            r"([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})",
            text or "")
        for u in uuids:
            return u
        return ""

    def extract_m3u8(self, page_html):
        text = page_html or ""
        pack = re.search(
            r"(eval\s*\(\s*function\s*\(\s*p\s*,\s*a\s*,\s*c\s*.*?\.split\(['\"]\|['\"]\).*?\)\s*\))",
            text, re.I | re.S)
        if pack:
            unpacked = self._unpack(pack.group(1))
            links = list(dict.fromkeys(
                re.findall(r"https?://[^\s'\"<>\\;]+\.m3u8", unpacked.replace("\\/", "/"))))
            for want in ("1080p", "720p"):
                for link in links:
                    if want in link.lower():
                        return link
            if links:
                return links[0]
        m = re.search(r"'m3u8(.*?)video", text, re.S)
        if m:
            parts = m.group(1).split("|")[::-1]
            if len(parts) >= 9 and parts[2] and parts[3]:
                return "%s://%s.%s/%s-%s-%s-%s-%s/playlist.m3u8" % (
                    parts[1], parts[2], parts[3], parts[4], parts[5],
                    parts[6], parts[7], parts[8])
        uuid = self._extract_surrit_uuid(text)
        if uuid:
            return "https://surrit.com/%s/playlist.m3u8" % uuid
        m = re.search(r"https?://[^\s\"']+\.m3u8[^\s\"']*", text)
        if m:
            return m.group(0)
        return ""

    def parse_list(self, page_html):
        cards = {}
        order = []
        pat = re.compile(
            r"<a[^>]+href=[\"']?(https?://[^\"'\s>]+/cn/([a-z0-9][a-z0-9\-_]*))[\"']?[^>]*>(.*?)</a>",
            re.S | re.I)
        for m in pat.finditer(page_html or ""):
            code, body = m.group(2).lower(), m.group(3)
            if not _is_video_code(code):
                continue
            url = PRIMARY + "/cn/" + code
            if code not in cards:
                cards[code] = {"vod_id": url, "vod_name": "", "vod_pic": "",
                               "vod_remarks": ""}
                order.append(code)
            card = cards[code]
            pic = pick_image(body)
            if pic and not card["vod_pic"]:
                card["vod_pic"] = pic
            dur = re.search(r"\b(\d{1,2}:\d{2}(?::\d{2})?)\b", body or "")
            if dur and not card["vod_remarks"]:
                card["vod_remarks"] = dur.group(1)
            cands = []
            cands.extend(re.findall(r"alt=[\"']([^\"']+)[\"']", body, re.I))
            cands.extend(re.findall(r"title=[\"']([^\"']+)[\"']", body, re.I))
            cands.append(txt_of(body))
            title = ""
            for t in cands:
                t = (t or "").strip()
                if not t:
                    continue
                if re.match(r"^\d{1,2}:\d{2}(?::\d{2})?$", t):
                    continue
                if t.lower() == code:
                    continue
                if len(t) > len(title):
                    title = t
            if len(title) > len(card["vod_name"]):
                card["vod_name"] = title
        out = []
        for code in order:
            card = cards[code]
            if not card["vod_name"]:
                card["vod_name"] = code.upper()
            card["vod_name"] = card["vod_name"][:120]
            out.append(card)
        return out

    def parse_index(self, page_html, prefix):
        page_html = page_html or ""
        pat = re.compile(
            r"<a[^>]+href=[\"']?(https?://[^\"'\s>]+/(?:dm\d+/)?cn/" + prefix +
            r"/([^\"'\s>/]+))[\"']?[^>]*>(.*?)</a>", re.S | re.I)
        out, seen = [], set()
        for m in pat.finditer(page_html):
            slug, body = m.group(2), m.group(3)
            if slug in seen or slug.lower() == "ranking":
                continue
            seen.add(slug)
            name = urllib.parse.unquote(slug)
            text = txt_of(body)
            disp = name
            mm = re.match(r"(.+?)\s*\d[\d,]*\s*条影片", text)
            if mm and len(mm.group(1)) <= len(name) + 4:
                disp = mm.group(1).strip() or name
            remarks = ""
            cm = re.search(r"([\d,]+)\s*条影片", text)
            if cm:
                remarks = cm.group(1) + " 部"
            ym = re.search(r"\b(19|20)\d{2}\b", text)
            if prefix == "actresses" and ym:
                remarks = (remarks + " · " if remarks else "") + ym.group(0) + " 出道"
            pic = pick_image(body)
            out.append({"vod_id": m.group(1), "vod_name": disp,
                        "vod_pic": pic, "vod_remarks": remarks,
                        "vod_tag": "folder"})
        return out

    def homeContent(self, filter=""):
        if getattr(self, "_home_cache", None):
            items = self._home_cache
        else:
            items = self.parse_list(self.http_get(PRIMARY + ROUTES["release"]))
            self._home_cache = items
        return {"class": CATS, "list": items, "filters": {}}

    def homeVideoContent(self):
        if getattr(self, "_home_cache", None):
            return {"list": self._home_cache}
        page_html = self.http_get(PRIMARY + ROUTES["release"])
        return {"list": self.parse_list(page_html)}

    def categoryContent(self, tid, pg, filter, extend):
        pg = str(pg or "1")
        tid = str(tid or "")
        # Index pages first: "actresses/ranking" also matches the drill
        # pattern below ("actresses/<slug>"), and must not be treated
        # as an actress folder (parse_list on it yields 0 videos).
        if tid in INDEX_TIDS:
            url = "%s%s?page=%s" % (PRIMARY, ROUTES[tid], pg)
            items = self.parse_index(self.http_get(url), INDEX_PREFIX[tid])
            return {"list": items, "page": int(pg),
                    "pagecount": 9999 if items else int(pg),
                    "limit": len(items) or 24, "total": 999999}
        drill = ""
        if tid.startswith("http") and re.search(r"/cn/(actresses|genres|makers)/", tid):
            drill = tid
        elif tid.startswith("/cn/") and re.match(r"^/cn/(actresses|genres|makers)/[^/]+$", tid):
            drill = PRIMARY + tid
        elif re.match(r"^(actresses|genres|makers)/[^/]+$", tid):
            drill = PRIMARY + "/cn/" + tid
        if drill:
            sep = "&" if "?" in drill else "?"
            items = self.parse_list(self.http_get("%s%spage=%s" % (drill, sep, pg)))
            return {"list": items, "page": int(pg),
                    "pagecount": 9999 if items else int(pg),
                    "limit": len(items) or 12, "total": 999999}
        sub = ""
        if isinstance(extend, dict):
            sub = str(extend.get("sub") or "")
        if sub:
            url = sub if sub.startswith("http") else PRIMARY + sub
            sep = "&" if "?" in url else "?"
            items = self.parse_list(self.http_get("%s%spage=%s" % (url, sep, pg)))
            return {"list": items, "page": int(pg),
                    "pagecount": 9999 if items else int(pg),
                    "limit": len(items) or 12, "total": 999999}
        route = ROUTES.get(tid, ROUTES["new"])
        url = "%s%s?page=%s" % (PRIMARY, route, pg)
        items = self.parse_list(self.http_get(url))
        return {"list": items, "page": int(pg),
                "pagecount": 9999 if items else int(pg),
                "limit": len(items) or 12, "total": 999999}

    def detailContent(self, ids):
        vid = ids[0] if isinstance(ids, list) else ids
        vid = str(vid or "").strip()
        if vid.startswith("http"):
            url = vid
        elif vid.startswith("/"):
            url = PRIMARY + vid
        else:
            url = PRIMARY + "/cn/" + vid.strip("/").lower()
        mm = re.search(r"/cn/(actresses|genres|makers)/([^/?#]+)$", url)
        if mm:
            page_html = self.http_get(url)
            works = self.parse_list(page_html)
            name = urllib.parse.unquote(mm.group(2))
            eps = ["%s$%s" % (w["vod_name"], w["vod_id"]) for w in works]
            vod = {"vod_id": url, "vod_name": name,
                   "vod_pic": works[0]["vod_pic"] if works else "",
                   "vod_content": "共 %d 部作品(第一页)" % len(works),
                   "vod_play_from": "MissAV",
                   "vod_play_url": "#".join(eps) if eps else ("网页播放$" + url)}
            return {"list": [vod]}
        page_html = self.http_get(url)
        title = ""
        m = re.search(r'property="og:title"\s+content="([^"]+)"', page_html or "")
        if m:
            title = html_mod.unescape(m.group(1)).strip()
            title = re.sub(r"\s*-\s*MissAV.*$", "", title).strip()
        if not title:
            m = re.search(r"<h1[^>]*>(.*?)</h1>", page_html or "", re.S)
            if m:
                title = txt_of(m.group(1))
        code = url.rstrip("/").split("/")[-1]
        actor = ""
        parts = [p.strip() for p in (title or "").split(" - ") if p.strip()]
        if len(parts) >= 2:
            actor = parts[-1]
        pic = ""
        m = re.search(r'property="og:image"\s+content="([^"]+)"', page_html or "")
        if m:
            pic = m.group(1)
        tags = ""
        m = re.search(r'name="keywords"\s+content="([^"]+)"', page_html or "")
        if m:
            tags = html_mod.unescape(m.group(1)).strip()
        if not actor and tags:
            actor = tags.split(",")[0].strip()
        year = ""
        m = re.search(r'property="og:video:release_date"\s+content="([^"]+)"', page_html or "")
        if m:
            year = m.group(1)[:4]
        if not year:
            m = re.search(r"\b(19|20)\d{2}\b", tags or "")
            if m:
                year = m.group(0)
        remarks = ""
        m = re.search(r'property="og:video:duration"\s+content="([^"]+)"', page_html or "")
        if m:
            remarks = fmt_duration(m.group(1))
        play = self.extract_m3u8(page_html)
        play_url = ("正片$" + play) if play else ("网页播放$" + url)
        vod = {"vod_id": url,
               "vod_name": title or code.upper(),
               "vod_pic": pic,
               "vod_actor": actor,
               "vod_year": year,
               "vod_content": tags,
               "vod_remarks": remarks,
               "vod_play_from": "MissAV",
               "vod_play_url": play_url}
        return {"list": [vod]}

    def searchContent(self, key, quick=False, pg="1"):
        pg = str(pg or "1")
        url = "%s/dm247/cn/search/%s?page=%s" % (
            PRIMARY, urllib.parse.quote(str(key).strip().lower()), pg)
        items = self.parse_list(self.http_get(url))
        return {"list": items, "page": int(pg),
                "pagecount": 9999 if items else int(pg),
                "limit": len(items) or 12, "total": 999999}

    def playerContent(self, flag, id, vipFlags):
        url = str(id or "").strip()
        parse = 0
        if url and ".m3u8" not in url.lower():
            found = self.extract_m3u8(self.http_get(url))
            if found:
                url = found
            else:
                parse = 1
        head = {"User-Agent": UA,
                "Referer": PLAY_REFERER,
                "Origin": PLAY_ORIGIN,
                "Accept": "*/*",
                "Connection": "keep-alive"}
        return {"parse": parse, "url": url, "header": head}

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
                "Referer": "%s://%s/" % (o.scheme, o.netloc)})
            with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
                return [r.status, r.headers.get("Content-Type") or "application/octet-stream",
                        r.read(), {}]
        except Exception:
            return [502, "text/plain", b"proxy error", {}]

    def action(self, action=None):
        return {}
