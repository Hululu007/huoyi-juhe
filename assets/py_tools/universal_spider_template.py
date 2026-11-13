import base64
import json
import re
import ssl
import urllib.parse
import urllib.request

try:
    from base.spider import Spider as _BaseSpider
except Exception:
    _BaseSpider = object

BASES = @BASES@
SITE = BASES[0]
SITE_NAME = "@NAME@"
_GEN_TS = "@TS@"
_GEN_MODE = "@MODE@"
_CUR = [0]


def _base():
    return BASES[_CUR[0]].rstrip("/")
API_HINT = "@API@"
FORCE_MODE = "@FORCE@"
IMG_PROXY = "@IMGPROXY@"
UA = "Mozilla/5.0 (Linux; Android 11) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36"
TIMEOUT = 8

_ctx = ssl.create_default_context()
_ctx.check_hostname = False
_ctx.verify_mode = ssl.CERT_NONE
try:
    _ctx.set_ciphers(
        "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:"
        "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:"
        "ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:"
        "ECDHE-RSA-AES128-SHA:ECDHE-RSA-AES256-SHA:AES128-GCM-SHA256:AES256-GCM-SHA384")
except Exception:
    pass
try:
    _ctx.set_alpn_protocols(["http/1.1"])
except Exception:
    pass


def _abs(u):
    u = (u or "").strip()
    if not u:
        return ""
    if u.startswith("//"):
        return "https:" + u
    if u.startswith("http"):
        return u
    m = re.match(r"^[^/]+\.(?:com|net|org|tv|cc|io|cn|me|la|top|xyz|info|vip|pro)/",
                 u, re.I)
    if m and "/" in u:
        u = "/" + u[u.index("/") + 1:]
    if u.startswith("/"):
        return _base() + u
    return _base() + "/" + u.lstrip("/")


def _fetch(url, data=None, ref=None, retry=1, ua=None):
    last_err = None
    external = url.startswith("http") and not any(
        url.startswith(b.rstrip("/")) for b in BASES)
    tries = [0] if external else list(range(len(BASES)))
    for attempt in range(retry + 1):
        for i in tries:
            _CUR[0] = i
            u = url
            if not u.startswith("http"):
                u = _base() + u
            else:
                for j, ob in enumerate(BASES):
                    ob = ob.rstrip("/")
                    if j != i and u.startswith(ob):
                        u = _base() + u[len(ob):]
                        break
            headers = {
                "User-Agent": ua or UA,
                "Referer": ref or (_base() + "/"),
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
                "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
                "Upgrade-Insecure-Requests": "1",
                "Sec-Fetch-Dest": "document",
                "Sec-Fetch-Mode": "navigate",
                "Sec-Fetch-Site": "same-origin" if ref else "none",
                "Sec-Fetch-User": "?1",
            }
            req = urllib.request.Request(u, data=data, headers=headers)
            opener = urllib.request.build_opener(
                urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=_ctx))
            try:
                with opener.open(req, timeout=TIMEOUT) as r:
                    raw = r.read()
                    if (r.headers.get("Content-Encoding") or "") == "gzip":
                        import gzip as _gz
                        try:
                            raw = _gz.decompress(raw)
                        except Exception:
                            pass
                    charset = "utf-8"
                    ct = (r.headers.get("Content-Type") or "")
                    m = re.search(r"charset=([\w-]+)", ct, re.I)
                    if m:
                        charset = m.group(1)
                    if charset.lower() in ("gbk", "gb2312"):
                        charset = "gb18030"
                    return raw.decode(charset, errors="ignore")
            except Exception as e:
                last_err = e
                continue
    raise last_err if last_err else IOError("fetch failed")


def _json(url, params=None, ref=None):
    if params:
        qs = urllib.parse.urlencode(params)
        url = url + ("&" if "?" in url else "?") + qs
    try:
        return json.loads(_fetch(url, ref=ref).strip().lstrip("﻿"))
    except Exception:
        return None


def _txt(raw):
    t = re.sub(r"<script[\s\S]*?</script>", "", raw or "", flags=re.I)
    t = re.sub(r"<[^>]+>", " ", t)
    t = t.replace("&nbsp;", " ").replace("&amp;", "&").replace("&quot;", '"')
    return re.sub(r"\s+", " ", t).strip()


def _first(html, pats, group=1, flags=re.S | re.I):
    for p in pats:
        try:
            m = re.search(p, html, flags)
            if m:
                v = m.group(group).strip()
                if v:
                    return v
        except Exception:
            continue
    return ""


def _alls(html, pats, flags=re.S | re.I):
    for p in pats:
        try:
            out = re.findall(p, html, flags)
            if out:
                return out
        except Exception:
            continue
    return []


def _img(html):
    v = _first(html, [
        r'data-original="([^"]+)"',
        r'data-src="([^"]+)"',
        r'data-echo="([^"]+)"',
        r'data-lazy="([^"]+)"',
        r'<img[^>]+src="([^"]+)"',
        r'style="[^"]*background(?:-image)?\s*:\s*url\(([^)]+)\)',
        r'<meta[^>]+property="og:image"[^>]+content="([^"]+)"',
    ])
    if not v:
        v = _first(html, [
            r"data-original='([^']+)'", r"data-src='([^']+)'",
            r"<img[^>]+src='([^']+)'",
            r"style='[^']*background(?:-image)?\s*:\s*url\(([^)]+)\)'"])
    if not v or v.startswith("data:"):
        return ""
    v = v.strip("'\" ").replace("&amp;", "&").replace("&#38;", "&")\
        .replace("\\/", "/")
    tail = re.split(r"[?#]", v)[0].rstrip("/").split("/")[-1]
    if re.search(r"(?:lazy|placeholder|logo|loading|avatar|captcha|blank|spacer|"
                 r"default|nopic|noimage)", tail, re.I):
        return ""
    if re.search(r"/(?:statics?|template|css|js)/", v, re.I):
        return ""
    if not re.search(r"\.(?:jpe?g|png|webp|gif|bmp)(?:\?|$)", v, re.I):
        if not re.search(r"upload|/img|image|pic|photo|cover|poster|vodpic|"
                         r"gimg|img\.|\d{6,}", v, re.I):
            return ""
    return _abs(v)


_HREF_RE = re.compile(r"""href\s*=\s*(?:"([^"]*)"|'([^']*)')""", re.I)


def _hrefs(html):
    out = []
    for a, b in _HREF_RE.findall(html or ""):
        u = (a or b or "").strip()
        if u and not u.startswith(("#", "javascript:", "mailto:", "tel:")):
            out.append(u)
    return out


def _ext_dict(ext):
    if isinstance(ext, dict):
        return {str(k): str(v) for k, v in ext.items() if v}
    if isinstance(ext, str) and ext.strip():
        try:
            d = json.loads(ext)
            if isinstance(d, dict):
                return {str(k): str(v) for k, v in d.items() if v}
        except Exception:
            pass
    return {}


_FILTER_EXTRA = [
    {"key": "lang", "name": "语言",
     "value": [{"n": n, "v": "" if n == "全部" else n} for n in
               ["全部", "国语", "粤语", "英语", "日语", "韩语", "泰语", "法语", "德语", "其它"]]},
    {"key": "year", "name": "年份",
     "value": [{"n": n, "v": "" if n == "全部" else n} for n in
               ["全部", "2026", "2025", "2024", "2023", "2022", "2021", "2020",
                "2019", "2018", "2017", "2016", "2015", "2014", "2013", "2012", "更早"]]},
    {"key": "letter", "name": "字母",
     "value": [{"n": "全部", "v": ""}] +
              [{"n": c, "v": c} for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ"] +
              [{"n": "0-9", "v": "0-9"}]},
    {"key": "sort2", "name": "评分",
     "value": [{"n": n, "v": "" if n == "全部" else n} for n in
               ["全部", "9分以上", "8分以上", "7分以上", "6分以上"]]},
]


def _ext_kv(ext):
    d = _ext_dict(ext)
    if not isinstance(d, dict):
        return {}
    out = {}
    for k, v in d.items():
        if k in ("area", "lang", "year", "letter", "sort2", "class") and v:
            out[str(k)] = str(v)
    return out


def _next_unesc(h):
    for _ in range(4):
        nh = h.replace('\\"', '"').replace("\\'", "'").replace('\\/', '/')
        if nh == h:
            break
        h = nh
    return h


def _next_balanced(s, start):
    depth = 0
    instr = False
    esc = False
    for i in range(start, len(s)):
        c = s[i]
        if instr:
            if esc:
                esc = False
            elif c == '\\':
                esc = True
            elif c == '"':
                instr = False
        else:
            if c == '"':
                instr = True
            elif c == '{':
                depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0:
                    return s[start:i + 1]
    return ""


def _next_is_nextjs(html):
    return bool(html) and "/_next/static" in html and "/vod/play/" in html and "/detail/" in html

class JsonAPI(object):

    def __init__(self, api):
        self.api = api
        self.kind = "apple"

    def cats(self):
        d = _json(self.api, {"ac": "list"}) or {}
        return [(str(x.get("type_id", "")), str(x.get("type_name", "")).strip())
                for x in (d.get("class") or []) if x.get("type_id") is not None]

    def list(self, tid=None, pg=1, wd=None, ext=None):
        params = {"ac": "detail", "pg": pg}
        if tid:
            params["t"] = tid
        if wd:
            params["wd"] = wd
        d = _ext_kv(ext)
        for k in ("area", "lang", "year", "class", "letter"):
            if d.get(k):
                params[k] = d[k]
        dd = _json(self.api, params)
        if dd is None:
            params["ac"] = "videolist"
            dd = _json(self.api, params)
        if not dd:
            return [], 1
        items = []
        for v in dd.get("list") or []:
            items.append({
                "id": str(v.get("vod_id", v.get("id", ""))),
                "name": str(v.get("vod_name", v.get("name", ""))).strip(),
                "pic": _abs(str(v.get("vod_pic", v.get("pic", "")) or "")),
                "remark": str(v.get("vod_remarks", "") or ""),
            })
        try:
            pc = int(dd.get("pagecount") or dd.get("total_page") or 1)
        except Exception:
            pc = 1
        return items, max(1, pc)

    def detail(self, vid):
        d = _json(self.api, {"ac": "detail", "ids": vid})
        if not d or not d.get("list"):
            return None
        v = d["list"][0]
        flags = [f.strip() for f in str(v.get("vod_play_from", "")).split("$$$") if f.strip()]
        pu = str(v.get("vod_play_url", "") or "")
        shows, urls = [], []
        for i, flag in enumerate(flags):
            try:
                block = pu.split("$$$")[i]
            except IndexError:
                block = ""
            eps = []
            for ep in block.split("#"):
                if "$" in ep:
                    a, b = ep.split("$", 1)
                    if b.strip():
                        eps.append([a.strip() or "播放", b.strip()])
            if eps:
                shows.append(flag)
                urls.append(eps)
        return {
            "id": vid,
            "name": str(v.get("vod_name", "")).strip(),
            "pic": _abs(str(v.get("vod_pic", "") or "")),
            "typename": str(v.get("vod_class", "") or ""),
            "year": str(v.get("vod_year", "") or ""),
            "area": str(v.get("vod_area", "") or ""),
            "remarks": str(v.get("vod_remarks", "") or ""),
            "actor": str(v.get("vod_actor", "") or ""),
            "director": str(v.get("vod_director", "") or ""),
            "content": _txt(str(v.get("vod_content", "") or ""))[:800],
            "shows": shows,
            "urls": urls,
        }


DETAIL_PATS = [
    r'href="((?:https?://[^/"]+)?/[a-z][a-z0-9_-]{0,20}/[a-z0-9][a-z0-9_-]{1,60}/?)"',
    r'href="([^"]*?/[a-z][a-z0-9_-]{0,20}/[a-z0-9_-]+\d[a-z0-9_-]*\.html?)"',
    r'href="([^"]*?/[a-z][a-z0-9_-]{0,20}/\d+[a-z0-9_-]*\.html?)"',
    r'href="([^"]*?/\d{2,}\.html)"',
]
NON_CONTENT = set("""login register user users about contact help search so vodsearch
list type show category channel news article page pages tag tags topic topics
index home map rss sitemap feedback gbook guestbook download app apk share
playlist playlists filter rank richlist requests api static upload assets
images image css js fonts ajax member vip pay order cart comment comments
notice notices ad ads gg adress address app-download dm8 mine my
vodtype vodshow detail voddetail post cat movie tv anime yingshi ziyuan
gongju zhinan yule site web item items file files""".split())
CAT_PATS = [
    r'<a[^>]+href="([^"]*?/vod(?:type|show)/(\d+)[^"]*?)"[^>]*>([\s\S]{1,300}?)</a>',
    r'<a[^>]+href="([^"]*?/(?:type|list|category|channel)/(\d+)[^"]*?)"[^>]*>([\s\S]{1,300}?)</a>',
]
NAV_PATS = [
    r'<a[^>]+href="(/[a-z][a-z0-9/.\-]{0,40})"[^>]*>\s*(电影|电视剧|剧集|动漫|动画|综艺|短剧|院线|影视|大片|韩剧|美剧|国漫|日番|纪录片)\s*</a>',
]
NEXT_PATS = [
    r'<a[^>]+href="([^"]+)"[^>]*>\s*(?:下一页|下页|后一页|»|›|&gt;&gt;|&raquo;|Next)\s*</a>',
    r'<a[^>]+class="[^"]*(?:next|page-next)[^"]*"[^>]+href="([^"]+)"',
]


class HtmlSite(object):

    def __init__(self):
        self.detail_re = None
        self.cat_re = None
        self.page_fmt = None
        self._next = {}
        self._cats = []
        self.sniffed = False
        self._detail_prefix = ""
        self._p1sig = {}

    @staticmethod
    def _id_of(url):
        if not url:
            return ""
        path = url.split("?")[0].split("#")[0].rstrip("/")
        segs = [s for s in path.split("/") if s]
        if url.startswith("http") and segs:
            segs = segs[1:]
        CONTENT_DIRS = set("""detail voddetail vodshow vodtype post play vodplay
            detail- vod- show- vodshow- movie movies tv anime show video videos subject mv
            stream watch item items file files info content drama list playinfo
            v d ep eps video- watch- mv- anime-""".split())
        if len(segs) <= 1:
            one = re.sub(r"\.html?$", "", segs[0] if segs else "", flags=re.I)
            m = re.fullmatch(r"([a-zA-Z]{3,12})[-_]?(\d{2,12})", one)
            if m:
                pre = m.group(1).lower()
                if pre in CONTENT_DIRS or (pre + "-") in CONTENT_DIRS:
                    return one
                if pre not in NON_CONTENT and pre not in ("type", "list", "page", "index"):
                    return one
            return ""
        parent = segs[-2].lower()
        if parent in NON_CONTENT and parent not in CONTENT_DIRS:
            return ""
        seg = re.sub(r"\.html?$", "", segs[-1], flags=re.I)
        if parent in ("id", "ids", "vid", "vodid", "key", "code", "name", "title") \
                and len(segs) >= 3:
            cand = re.sub(r"\.html?$", "", segs[-2], flags=re.I)
            if seg.isdigit() and len(seg) >= 2:
                return seg
            if cand.isdigit() and len(cand) >= 2:
                return cand
            if re.fullmatch(r"[a-zA-Z0-9_-]{2,60}", seg):
                return seg
        if seg.isdigit() and len(seg) <= 6 and len(segs) >= 3:
            cand = re.sub(r"\.html?$", "", segs[-2], flags=re.I)
            pp = segs[-3].lower()
            if pp in CONTENT_DIRS and re.fullmatch(r"[a-zA-Z0-9_-]{3,}", cand):
                return cand
        if not seg or len(seg) < 2 or len(seg) > 60:
            return ""
        if not re.fullmatch(r"[a-zA-Z0-9_-]+", seg):
            return ""
        if seg.isdigit():
            return seg if len(seg) >= 2 else ""
        if seg.lower() in NON_CONTENT:
            return ""
        if re.search(r"\d", seg) or (seg != seg.lower() and seg != seg.upper()) or len(seg) >= 4:
            return seg
        if parent in CONTENT_DIRS and len(seg) >= 3:
            return seg
        return ""

    @staticmethod
    def _path_key(url):
        if not url:
            return ""
        p = url.split("?")[0].split("#")[0]
        if p.startswith("http"):
            p = re.sub(r"^https?://[^/]+", "", p)
        if not p.startswith("/"):
            p = "/" + p
        segs = [s for s in p.split("/") if s]
        CONTENT_DIRS = set("""detail voddetail vodshow vodtype post play vodplay
            detail- vod- show- vodshow- movie movies tv anime show video videos subject mv
            stream watch item items file files info content drama list playinfo
            v d ep eps video- watch- mv- anime-""".split())
        if len(segs) < 2:
            one = segs[0] if segs else ""
            m = re.fullmatch(r"([a-zA-Z]{3,12})[-_]?(\d{2,12})(\.html?)?", one, re.I)
            if m:
                pre = m.group(1).lower()
                if pre in CONTENT_DIRS or (pre + "-") in CONTENT_DIRS or \
                        pre not in NON_CONTENT:
                    return "/%s#%s" % (pre, (m.group(3) or "").lower())
            return ""
        parent = segs[-2]
        last = segs[-1]
        if parent.lower() in NON_CONTENT and parent.lower() not in CONTENT_DIRS:
            return ""
        ext = ""
        m = re.search(r"(\.html?|\.php|\.aspx?)$", last, re.I)
        if m:
            ext = m.group(1).lower()
        if not re.search(r"[a-zA-Z0-9]", last):
            return ""
        if last.isdigit() and len(last) <= 6 and len(segs) >= 3:
            pp = segs[-3].lower()
            if pp in CONTENT_DIRS and re.fullmatch(r"[a-zA-Z0-9_-]{3,}", parent):
                return "/%s/#/%s" % (pp, last)
        return "/%s/#%s" % (parent.lower(), ext)

    @staticmethod
    def _looks_dead(html):
        if not html:
            return True
        low = html.lower()
        for kw in ("域名过期", "域名已过期", "出售此域名", "buy this domain",
                   "domain for sale", "domain is for sale", "本域名出售",
                   "网站已关闭", "站已关闭", "该站已停止",
                   "账户已被冻结", "账户被暂停",
                   "alternatives here", "permanent link below"):
            if kw in low:
                return True
        body = re.sub(r"<(script|style)[\s\S]*?</\1>", "", html)
        tags = len(re.findall(r"<[a-z][^>]*>", body, re.I))
        links = _hrefs(html)
        if tags < 5 and len(links) < 5:
            return True
        if len(links) < 8 and not re.search(
                r"电影|电视剧|动漫|综艺|剧集|影片|在线观看|播放|vod|movie", body, re.I):
            return True
        return False

    @staticmethod
    def _migrate_target(html):
        if not html or len(html) > 600000:
            return ""
        for pat in (r'NEW_SITE_URL\s*=\s*["\'](https?://[^"\']+)',
                    r'(?:window\.)?location(?:\.href)?\s*=\s*["\'](https?://[^"\']+)',
                    r'location\.replace\(\s*["\'](https?://[^"\']+)',
                    r'<meta[^>]+http-equiv=["\']?refresh[^>]*url=(https?://[^"\'>\s]+)'):
            m = re.search(pat, html, re.I)
            if m:
                return m.group(1).rstrip("/")
        low = re.sub(r"<[^>]+>", " ", html)
        if not re.search(r"永久地址|最新地址|新域名|新网址|备用域名|永久域名|站点迁移|"
                         r"domain rotate|new domain|permanent", low, re.I):
            return ""
        host0 = re.sub(r"^https?://", "", _base()).split("/")[0].lower()
        brand = re.sub(r"^www\.", "", host0).split(".")[0]
        if len(brand) < 3:
            return ""
        cands = []
        for u in re.findall(r'https?://[a-zA-Z0-9.-]+\.[a-z]{2,9}', html):
            d = re.sub(r"^https?://", "", u).lower()
            if brand in re.sub(r"^www\.", "", d):
                cands.append(u.rstrip("/"))
        if not cands:
            return ""
        for c in cands:
            if c.lower().rstrip("/") != _base().lower():
                return c
        return ""

    def sniff(self):
        if self.sniffed:
            return
        self.sniffed = True
        html, best_html = "", ""
        for i in range(len(BASES)):
            _CUR[0] = i
            try:
                h = _fetch(BASES[i].rstrip("/") + "/", retry=2)
            except Exception:
                h = ""
            if not h:
                continue
            if not best_html:
                best_html = h
            if not self._looks_dead(h):
                html, best_html = h, h
                break
        if not html or len(_hrefs(html)) < 12:
            tgt = self._migrate_target(html or best_html)
            if tgt:
                try:
                    h2 = _fetch(tgt + "/")
                except Exception:
                    h2 = ""
                if h2 and not self._looks_dead(h2) and len(_hrefs(h2)) >= 12:
                    if tgt not in [b.rstrip("/") for b in BASES]:
                        BASES.insert(0, tgt)
                    _CUR[0] = 0
                    html = h2
        if not html:
            html = best_html
        if not html:
            return
        all_hrefs = _hrefs(html)
        groups = {}
        for u in all_hrefs:
            key = self._path_key(u)
            if not key:
                continue
            groups.setdefault(key, []).append(u)
        best = None
        for key, urls in groups.items():
            uniq_ids = set()
            for u in urls[:80]:
                s = self._id_of(u)
                if s:
                    uniq_ids.add(s)
            if len(uniq_ids) < 3:
                continue
            avg = sum(len(x) for x in uniq_ids) / float(len(uniq_ids))
            score = len(uniq_ids) * 10 + avg * 3 + min(len(urls), 200) * 0.2
            if best is None or score > best[0]:
                sample = max(urls[:80], key=len)
                best = (score, sample, len(uniq_ids))
        if best:
            sample = best[1]
            self.detail_re = self._build_detail_re(sample)
            segs = sample.split("?")[0].rstrip("/").split("/")
            if len(segs) >= 2:
                self._detail_prefix = "/".join(segs[:-1]) + "/"
        for pat in CAT_PATS:
            found = re.findall(pat, html, re.I)
            if len(found) >= 2:
                self._cats = []
                seen = set()
                for href, tid, name in found:
                    name = self._clean_cat(_txt(name))
                    if tid not in seen and name and len(name) <= 12:
                        seen.add(tid)
                        self._cats.append((tid, name))
                self._cats = self._order_cats(self._cats)
                if self._cats:
                    sample_href = found[0][0]
                    self.page_fmt = self._build_page_fmt(sample_href)
                    break
        if not self._cats:
            nav = re.findall(NAV_PATS[0], html)
            seen = set()
            for path, name in nav:
                name = self._clean_cat(name.strip())
                path = path.rstrip("/")
                if path not in seen and name and len(name) <= 12 and path not in ("/",):
                    seen.add(path)
                    self._cats.append((path, name))
            if self._cats:
                self._cats = self._order_cats(self._cats)

    @staticmethod
    def _clean_cat(name):
        n = (name or "").strip()
        n = re.sub(r"每周热门|本周最佳|本周|热门|排行榜|排行|榜$", "", n)
        n = n.replace("连续剧", "电视剧").replace("综艺纪录", "综艺")
        n = n.strip("·-— ")
        exact = {
            "连续剧": "电视剧", "电视剧": "电视剧", "剧集": "电视剧", "国产连续剧": "电视剧",
            "动漫": "动漫", "动画": "动漫", "番剧": "动漫",
            "综艺": "综艺", "综艺片": "综艺", "真人秀": "综艺",
            "电影片": "电影", "电影": "电影", "影片": "电影",
        }
        return exact.get(n, n)

    @staticmethod
    def _order_cats(cats):
        rank = {"电影": 0, "电视剧": 1, "动漫": 2, "综艺": 3}
        seen, out = set(), []
        for tid, n in cats:
            if not n or n in seen:
                continue
            seen.add(n)
            out.append((tid, n))
        out.sort(key=lambda x: rank.get(x[1], 99))
        return out

    def _build_detail_re(self, sample):
        sample = sample.split("?")[0]
        segs = [s for s in sample.split("/") if s]
        if sample.startswith("http"):
            segs = segs[1:]
        if segs:
            last = segs[-1]
            ext = ""
            m = re.search(r"(\.html?|\.php|\.aspx?)$", last, re.I)
            if m:
                ext = m.group(1)
                last = last[:m.start()]
            parent = "/".join(segs[:-1])
            head = "/" + parent + "/" if parent else "/"
            if not parent:
                m2 = re.fullmatch(r"([a-zA-Z_-]{3,12}?)(\d{2,12})", last)
                if m2:
                    return "/" + re.escape(m2.group(1)) + r"(\d{2,12})" + re.escape(ext)
                return "/" + re.escape(last) + re.escape(ext)
            if len(segs) >= 3 and segs[-2].lower() in (
                    "id", "ids", "vid", "vodid", "key", "code", "name", "title"):
                stem = "/" + "/".join(segs[:-1]) + "/"
                return re.escape(stem) + r"([a-zA-Z0-9_-]{1,60})" + re.escape(ext)
            if last.isdigit() and len(last) <= 6 and len(segs) >= 3:
                pp = segs[-3].lower()
                if pp in ("v", "d", "ep", "eps", "video", "watch", "detail", "play", "vod"):
                    stem = "/" + "/".join(segs[:-2]) + "/"
                    return re.escape(stem) + r"([a-zA-Z0-9_-]{2,60})/" + re.escape(last) + re.escape(ext)
            if re.fullmatch(r"[a-zA-Z0-9_-]{3,}", last) and (
                    re.search(r"\d", last) or len(last) >= 4):
                return re.escape(head) + r"([a-zA-Z0-9_-]{2,60})" + re.escape(ext)
        esc = re.escape(sample)
        found = list(re.finditer(r"\d{3,}", esc))
        if not found:
            return esc
        lastm = found[-1]
        return esc[:lastm.start()] + r"(\d+)" + esc[lastm.end():]

    def _build_page_fmt(self, sample):
        s = sample.split("?")[0]
        if re.search(r"-\d+\.html$", s):
            return "dash"
        if re.search(r"/\d+/?\.html$", s):
            return "slash"
        if re.search(r"-\d+/?$", s):
            return "dash2"
        return "dash"

    def cats(self):
        self.sniff()
        return self._cats or []

    def parse_items(self, html):
        self.sniff()
        items, seen = [], set()
        if not self.detail_re:
            return items
        for m in re.finditer(self.detail_re, html, re.I):
            href = m.group(0)
            if href.startswith('href="'):
                href = href[6:]
            if not href.startswith("http"):
                href = _abs(href)
            path = href.split("?")[0].split("#")[0]
            vid = self._id_of(path)
            if not vid:
                nums = re.findall(r"(\d{2,})", path)
                vid = nums[-1] if nums else ""
            if not vid:
                continue
            if vid in seen:
                continue
            start = html.rfind("<a", 0, m.start() + 5)
            end = html.find("</a>", m.end())
            block = html[start:end + 4] if start >= 0 and end > 0 else ""
            name = ""
            t = _first(block, [r'title="([^"]{2,40})"', r'alt="([^"]{2,40})"'])
            if t:
                name = t
            else:
                name = _txt(block)
            name = re.split(r"\s{2,}", name)[0].strip()
            if not name or len(name) > 30:
                box = html[max(0, start - 400): end + 400]
                name = _txt(_first(box, [r'<h\d[^>]*>([^<]{1,30})</h\d>', r'class="[^"]*title[^"]*"[^>]*>([^<]{1,30})<']))
            if not name or len(name) > 30:
                continue
            seen.add(vid)
            pic = _img(block)
            if not pic:
                pic = _img(html[max(0, start - 700): end + 200])
            remark = ""
            rm = re.search(r'(更新至?\s*\d+\s*集?|HD[\d.]*|完结|预告|全\d+集)', block)
            if not rm:
                after = html[end:end + 400]
                rm = re.search(r'<p[^>]*>([^<]{1,20})</p>', after, re.I)
            if rm:
                cand = rm.group(1).strip()
                if re.search(r'\d|HD|更新|完结|预告', cand):
                    remark = cand
            items.append({"id": vid, "name": name, "pic": pic, "remark": remark, "url": href})
        return items

    def filters(self, tid):
        try:
            html = _fetch(_abs("/vodtype/{}.html".format(tid)))
        except Exception:
            html = ""
        areas, classes = [], []
        if html:
            for seg in re.findall(r"/vodshow/" + re.escape(str(tid)) + r"-([^\"']*?)\.html", html):
                parts = urllib.parse.unquote(seg).split("-")
                if len(parts) > 1 and parts[1] and parts[1] not in areas:
                    areas.append(parts[1])
                if len(parts) > 3 and parts[3] and parts[3] not in classes:
                    classes.append(parts[3])
        if not classes:
            classes = ["剧情", "动作", "喜剧", "爱情", "科幻", "悬疑", "恐怖", "惊悚", "战争", "动画", "纪录", "古装", "奇幻", "犯罪", "家庭", "青春"]
        if not areas:
            areas = ["中国大陆", "中国香港", "中国台湾", "美国", "韩国", "日本", "英国", "法国", "泰国", "印度", "其他"]
        out = [{"key": "class", "name": "类型",
                "value": [{"n": "全部", "v": ""}] + [{"n": v, "v": v} for v in classes]},
               {"key": "area", "name": "地区",
                "value": [{"n": "全部", "v": ""}] + [{"n": v, "v": v} for v in areas]}]
        out.extend(_FILTER_EXTRA)
        return out

    def _filter_urls(self, tid, pg, d):
        _cand = getattr(self, "_cat_urls", {}) or {}
        base = (_cand.get(tid) or "/vodtype/{}.html".format(tid)) \
            if tid and not str(tid).startswith("/") else (tid or "/")
        stem = re.sub(r"\.html?$", "", base)
        area = d.get("area", "")
        lang = d.get("lang", "")
        year = d.get("year", "")
        letter = d.get("letter", "")
        cls = d.get("sort2") or d.get("class", "")
        out = []
        if tid and str(tid).isdigit():
            a = [str(tid), area, "", cls, lang, letter, year, "", "", "", ""]
            out.append("/vodshow/" + "-".join(a) + ".html")
            if pg > 1:
                a2 = list(a); a2[-1] = str(pg)
                out.append("/vodshow/" + "-".join(a2) + ".html")
            out.append("/vodshow/{tid}--------{area}-{lang}---{pg}.html".format(tid=tid, area=area, lang=lang, pg=pg))
            out.append("/vodshow/{tid}--------{area}-{lang}--{year}--{letter}-{pg}.html".format(
                tid=tid, area=area, lang=lang, year=year, letter=letter, pg=pg))
        segs = []
        if cls:
            segs.append("class/" + urllib.parse.quote(cls, safe=""))
        if area:
            segs.append("area/" + urllib.parse.quote(area, safe=""))
        if lang:
            segs.append("lang/" + urllib.parse.quote(lang, safe=""))
        if year:
            segs.append("year/" + urllib.parse.quote(year, safe=""))
        if letter:
            segs.append("letter/" + urllib.parse.quote(letter, safe=""))
        if segs:
            body = "/".join(segs)
            out.append(stem + "/" + body + ("/page/" + str(pg) if pg > 1 else "") + ".html")
            out.append(stem + "/" + body + ("/" + str(pg) if pg > 1 else ""))
        qs = urllib.parse.urlencode({k: v for k, v in d.items() if v})
        if qs:
            out.append(stem + ".html?" + qs + ("&page=" + str(pg) if pg > 1 else ""))
        seen, res = set(), []
        for u in out:
            u = _abs(u)
            if u and u not in seen:
                seen.add(u)
                res.append(u)
        return res

    def _list_plain(self, tid=None, pg=1, ext=None):
        if not tid or tid == "all":
            url = SITE
        elif _ext_dict(ext):
            d = _ext_dict(ext)
            parts = [str(tid), d.get("area", ""), "", d.get("class", ""), "", "", "", "", "", "", "", ""]
            url = _abs("/vodshow/" + "-".join(parts) + ".html")
            try:
                html = _fetch(url)
            except Exception:
                return [], pg
            items = self.parse_items(html)
            return items, (pg + 1 if items else pg)
        else:
            url = self._page_url(tid, pg)
        html = _fetch(url)
        items = self.parse_items(html)
        if not items and pg > 1:
            self._cand = getattr(self, "_cand", 0) + 1
            url = self._page_url(tid, pg)
            try:
                html = _fetch(url)
                items = self.parse_items(html)
            except Exception:
                items = []
        nxt = _first(html, NEXT_PATS)
        if nxt:
            self._next[tid] = _abs(nxt)
        sig = tuple(x["id"] for x in items[:5])
        if pg <= 1:
            self._p1sig[tid] = sig
        elif not nxt and sig and sig == self._p1sig.get(tid):
            return [], pg - 1
        return items, (pg + 1 if (nxt or items) else pg)

    def list(self, tid=None, pg=1, ext=None):
        self.sniff()
        d = _ext_kv(ext)
        if not d:
            return self._list_plain(tid=tid, pg=pg, ext=ext)
        try:
            base_items = self.parse_items(_fetch(self._page_url(tid, 1)))
        except Exception:
            base_items = None
        base_sig = tuple(x["id"] for x in (base_items or [])[:5])
        for cand in self._filter_urls(tid, pg, d):
            try:
                h = _fetch(cand)
            except Exception:
                continue
            if not h:
                continue
            it = self.parse_items(h)
            if not it:
                continue
            if tuple(x["id"] for x in it[:5]) != base_sig:
                nxt = _first(h, NEXT_PATS)
                if nxt:
                    self._next[tid] = _abs(nxt)
                return it, (pg + 1 if (nxt or it) else pg)
        return self._list_plain(tid=tid, pg=pg, ext=ext)

    def _page_url(self, tid, pg):
        if tid.startswith("/"):
            base = tid
        else:
            base = "/vodtype/{}.html".format(tid)
        if pg <= 1:
            return _abs(base)
        nxt = self._next.get(tid)
        if nxt:
            return nxt
        stem = re.sub(r"\.html?$", "", base)
        cands = [
            stem + "-{}.html",
            base + "?page={}",
            stem + "/{}",
            base + "?{}",
            stem + "_{}.html",
            "/vodshow/{}----------{}---.html",
            "/type/{}/{}.html",
            "/list/{}/{}.html",
        ]
        if stem == base:
            cands = cands[1:]
        self._cand = getattr(self, "_cand", 0)
        c = cands[self._cand % len(cands)]
        try:
            return _abs(c.format(tid.lstrip("/"), pg))
        except Exception:
            return _abs(base)

    @staticmethod
    def _is_detail_page(html, vid):
        if not html or len(html) < 800:
            return False
        need = str(vid)
        if ("/" + need) in html or ("-" + need) in html or ("=" + need) in html:
            if re.search(r"vodplay|/play/|player_|播放", html, re.I):
                return True
        if re.search(r"player_[a-zA-Z]*\s*=\s*\{", html):
            return True
        if re.search(r"/vodplay/|/voddetail/|/play/\d", html, re.I):
            return True
        return False

    def detail(self, vid, item_url=""):
        self.sniff()
        html = ""
        cands = ([item_url] if item_url else []) + self._guess_detail_urls(vid)
        for u in cands:
            try:
                h = _fetch(u)
            except Exception:
                continue
            if not h:
                continue
            if not html:
                html = h
            if self._is_detail_page(h, vid):
                html = h
                break
        if not html:
            return None
        cands_name = []
        for pat in (r'<h1[^>]*>([^<]{1,40})</h1>',
                    r'<meta[^>]+property="og:title"[^>]+content="([^"]+)"',
                    r'<title>([^<]{1,80})</title>'):
            v = _txt(_first(html, [pat]))
            if v:
                cands_name.append(v)
        name = ""
        for v in cands_name:
            v = re.split(r"\s*[-_|–—]\s*(?:在线|高清|免费|完整版|@NAME@)|_@NAME@|@NAME@",
                         v)[0].strip()
            if v and len(v) <= 30:
                name = v
                break
        if not name and cands_name:
            name = _txt(cands_name[0])[:30]
        pic = _img(html)
        info = _first(html, [
            r'(?:导演|导演：|导演:)\s*[:：]?\s*<[^>]*>([^<]{1,30})<',
            r'(?:主演|主演：|主演:)\s*[:：]?\s*<[^>]*>([^<]{1,120})<',
        ])
        summary = _first(html, [
            r'<meta[^>]+name="description"[^>]+content="([^"]{5,})"',
            r'(?:剧情|简介|内容介绍)[^<]{0,10}[:：]\s*</?[^>]*>([\s\S]{5,600}?)</',
        ])
        summary = _txt(summary)[:500]
        groups = {}
        g0 = {}
        for m in re.finditer(
                r'<a[^>]+href="([^"]*?/([a-z0-9_-]+)/([a-z0-9]+)-(\d+)-(\d+)\.html)"[^>]*>(.*?)</a>',
                html, re.S | re.I):
            href = m.group(1)
            sid = m.group(4)
            eid = int(m.group(5))
            inner = _txt(m.group(6))
            if inner and re.search(r"APP|下载|安装|vip|开通", inner, re.I):
                continue
            g0.setdefault(sid, {})
            if href not in g0[sid]:
                g0[sid][href] = [inner or "第{}".format(eid), href, eid]
        for sid, eps in g0.items():
            ordered = sorted(eps.values(), key=lambda x: x[2])
            groups[sid] = [[n, u] for n, u, _ in ordered]
        for href, pid, sid, eid, inner in re.findall(
                r'<a[^>]+href="([^"]*?/(?:vodplay|play)/?(\d+)[-_/](\d+)[-_/](\d+)[^"]*)"[^>]*>(.*?)</a>',
                html, re.S | re.I):
            if "/vod/play/" in href:
                url = href
            else:
                url = "/vodplay/{}-{}-{}.html".format(pid, sid, eid)
            groups.setdefault(sid, []).append([_txt(inner) or eid, url])
        if not groups:
            for chunk in re.split(r"<a\s", html):
                tag = chunk.split(">")[0]
                m1 = re.search(r'href="([^"]*?/play/[a-zA-Z0-9]{5,}[^"]*)"', tag)
                m2 = re.search(r'data-line="(\d+)"', tag)
                m3 = re.search(r'data-episode="(\d+)"', tag)
                if m1 and m2 and m3:
                    ep = m3.group(1)
                    groups.setdefault(m2.group(1), []).append(["第{}集".format(ep), m1.group(1)])
        if not groups:
            for href, inner in re.findall(r'<a[^>]+href="([^"]*(?:play|vodplay)[^"]*)"[^>]*>(.*?)</a>', html, re.S | re.I):
                if not re.search(r"\d", href):
                    continue
                if href.startswith("http") and not any(
                        href.startswith(b.rstrip("/")) for b in BASES):
                    continue
                t = _txt(inner)
                if re.search(r"教程|帮助|下载|注册|登录|充值|公告|APP|求片|\d\.\d\s*分|\b19\d{2}\b|\b20\d{2}\b", t):
                    continue
                if len(t) <= 20:
                    groups.setdefault("1", []).append([t or "播放", href])
        if not groups:
            for src in re.findall(r'(?:iframe[^>]+src|"url"\s*:\s*)"([^"]*(?:m3u8|player|play)[^"]*)"', html, re.I):
                groups.setdefault("1", []).append([_txt(src)[:12] or "线路", src])
        shows = ["线路{}".format(i + 1) for i in range(len(groups))]
        urls = [groups[k] for k in sorted(groups, key=lambda x: (len(x), x))]
        for g in urls:
            for e in g:
                u = e[1]
                if u and not u.startswith("http"):
                    e[1] = _abs(u)
        if not urls:
            return {"id": vid, "name": name or vid, "pic": pic, "typename": "", "year": "",
                    "area": "", "remarks": "", "actor": "", "director": "", "content": info or summary,
                    "shows": ["在线播放"], "urls": [[["播放", item_url or ""]]]}
        return {"id": vid, "name": name or vid, "pic": pic, "typename": "", "year": "",
                "area": "", "remarks": "", "actor": "", "director": "", "content": info or summary,
                "shows": shows, "urls": urls}

    def _guess_detail_urls(self, vid):
        out = []
        if self.detail_re:
            guess = re.sub(r"\(\[[a-z0-9_\-\\]+\](?:\{\d+(?:,\d+)?\})?\)",
                           vid, self.detail_re, flags=re.I)
            guess = guess.replace('href="', "").replace('"', "")
            out.append(_abs(guess))
        if getattr(self, "_detail_prefix", ""):
            out.append(_abs(self._detail_prefix + vid))
        for tpl in ("/play/{}", "/voddetail/{}.html", "/detail/{}.html", "/vod/{}.html",
                    "/movie/{}.html", "/video/{}.html", "/{}.html",
                    "/voddetail/{}/", "/index.php/vod/detail/id/{}.html"):
            u = _abs(tpl.format(vid))
            if u not in out:
                out.append(u)
        return out

    def search(self, wd, pg=1):
        kw = urllib.parse.quote(str(wd))
        cands = [
            "/search?q={kw}&page={pg}",
            "/search?q={kw}",
            "/vodsearch/{kw}-------------.html",
            "/vodsearch/{kw}----------{pg}---.html",
            "/index.php/vod/search.html?wd={kw}&page={pg}",
            "/vodsearch/{kw}.html",
            "/search.php?searchword={kw}",
            "/search?wd={kw}&page={pg}",
            "/vod/search/{kw}/{pg}",
            "/search/{kw}/page/{pg}.html",
            "/index.php?m=vod-search&wd={kw}&page={pg}",
            "/so/{kw}.html",
        ]
        for c in cands:
            url = c.format(kw=kw, pg=pg)
            try:
                html = _fetch(url)
            except Exception:
                continue
            items = self.parse_items(html)
            if items:
                return items
        return []

class NextSite(object):

    def __init__(self):
        self._home = ""
        self._html = HtmlSite()

    def _ssr_vods(self, html):
        clean = _next_unesc(html)
        out = {}
        for m in re.finditer(r'"vodId":(\d+)', clean):
            start = clean.rfind('{', 0, m.start())
            try:
                d = json.loads(_next_balanced(clean, start))
            except Exception:
                continue
            if d.get("vodName") and d.get("vodPic"):
                out[str(d["vodId"])] = d
        return out

    def _items(self, html):
        self._html.detail_re = r"/detail/(\d+)"
        self._html._detail_prefix = "/detail/"
        items = self._html.parse_items(html)
        ssr = self._ssr_vods(html)
        if ssr:
            for x in items:
                d = ssr.get(str(x["id"]))
                if d:
                    x["pic"] = str(d["vodPic"])
                    if not x.get("remark"):
                        x["remark"] = str(d.get("vodRemarks") or "")
            if not items:
                for vid, d in ssr.items():
                    items.append({"id": vid, "name": str(d["vodName"]), "pic": str(d["vodPic"]),
                                  "remark": str(d.get("vodRemarks") or ""), "url": "/detail/" + vid})
        return items

    def cats(self):
        try:
            html = _fetch(_base() + "/")
        except Exception:
            return []
        self._home = html
        cats, seen = [], set()
        for tid, block in re.findall(r'<a[^>]*href="/vod/show/id/(\d+)"[^>]*>(.*?)</a>', html, re.S):
            name = _txt(block).split()
            name = name[0] if name else ""
            if tid not in seen and name and len(name) <= 12:
                seen.add(tid)
                cats.append((tid, name))
        return cats

    def filters(self, tid):
        try:
            html = _fetch(_abs("/vod/show/id/" + str(tid)), ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36")
        except Exception:
            return []
        groups, order = {}, []
        for dim, val in re.findall(r"/vod/show/id/" + re.escape(str(tid)) + r"/(class|area|lang|year)/([^/\"'\s<]+)", html):
            val = urllib.parse.unquote(val)
            if dim not in groups:
                groups[dim] = []
                order.append(dim)
            if val and val not in groups[dim]:
                groups[dim].append(val)
        names = {"class": "类型", "area": "地区", "lang": "语言", "year": "年份"}
        out = []
        for dim in ("class", "area", "lang", "year"):
            if groups.get(dim):
                out.append({"key": dim, "name": names[dim],
                            "value": [{"n": "全部", "v": ""}] + [{"n": v, "v": v} for v in groups[dim]]})
        have = set(f.get("key") for f in out)
        for f in _FILTER_EXTRA:
            if f["key"] not in have:
                out.append(f)
        return out

    def _list_plain(self, tid=None, pg=1, ext=None):
        if not tid:
            url = _base() + "/"
        elif tid.startswith("/"):
            url = _abs(tid)
        else:
            path = "/vod/show/id/" + str(tid)
            d = _ext_dict(ext)
            for dim in ("class", "area", "lang", "year"):
                if d.get(dim):
                    path += "/" + dim + "/" + urllib.parse.quote(d[dim], safe="")
            url = _abs(path)
        try:
            html = _fetch(url)
        except Exception:
            return [], 1
        items = self._items(html)
        if pg and pg > 1:
            first = tuple(x["id"] for x in items[:5])
            for cand in (url + "?page={}".format(pg), url + "/page/{}".format(pg),
                         url + "?pg={}".format(pg)):
                try:
                    h2 = _fetch(cand)
                except Exception:
                    continue
                it2 = self._items(h2)
                if it2 and tuple(x["id"] for x in it2[:5]) != first:
                    return it2, pg + 1
            return [], pg - 1
        return items, (pg + 1 if items else pg)

    def list(self, tid=None, pg=1, ext=None):
        d = _ext_kv(ext)
        if not tid or not d or not any(k in d for k in ("lang", "year", "letter", "area", "class")):
            return self._list_plain(tid=tid, pg=pg, ext=ext)
        path = "/vod/show/id/" + str(tid)
        for dim in ("class", "area", "lang", "year", "letter"):
            if d.get(dim):
                path += "/" + dim + "/" + urllib.parse.quote(d[dim], safe="")
        if pg > 1:
            path += "/page/" + str(pg)
        try:
            html = _fetch(_abs(path))
        except Exception:
            html = ""
        its = self._items(html) if html else []
        if its:
            return its, (pg + 1 if len(its) >= 20 else pg)
        return self._list_plain(tid=tid, pg=pg, ext=ext)

    def detail(self, vid):
        try:
            html = _fetch(_abs("/detail/" + str(vid)))
        except Exception:
            return None
        clean = _next_unesc(html)
        for m in re.finditer(r'"vodId":' + re.escape(str(vid)) + r'\b', clean):
            start = clean.rfind('{', 0, m.start())
            try:
                d = json.loads(_next_balanced(clean, start))
            except Exception:
                continue
            if d.get("vodName") and d.get("episodeList"):
                eps = []
                for e in d["episodeList"]:
                    nid = e.get("nid")
                    if nid:
                        eps.append([str(e.get("name") or nid), _abs("/vod/play/{}/1/{}".format(vid, nid))])
                content = _txt(str(d.get("vodContent") or ""))[:800]
                return {"id": str(vid), "name": str(d.get("vodName") or vid),
                        "pic": str(d.get("vodPic") or ""), "typename": str(d.get("typeName") or ""),
                        "year": str(d.get("vodYear") or ""), "area": str(d.get("vodArea") or ""),
                        "remarks": str(d.get("vodRemarks") or ""), "actor": str(d.get("vodActor") or ""),
                        "director": str(d.get("vodDirector") or ""), "content": content,
                        "shows": ["线路1"], "urls": [eps] if eps else []}
        v = HtmlSite().detail(str(vid), _abs("/detail/" + str(vid)))
        if v:
            for g in v.get("urls") or []:
                for e in g:
                    mm = re.match(r".*/vodplay/(\d+)-(\d+)-(\d+)\.html$", e[1] or "")
                    if mm:
                        e[1] = "/vod/play/{}/{}/{}".format(mm.group(1), mm.group(2), mm.group(3))
        return v

    def search(self, wd, pg=1):
        kw = urllib.parse.quote(str(wd))
        try:
            html = _fetch(_abs("/vod/search/" + kw), ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36")
        except Exception:
            return []
        return self._items(html)

    def play(self, raw):
        try:
            html = _fetch(raw)
        except Exception:
            return {"parse": 1, "url": raw}
        clean = _next_unesc(html)
        m = re.search(r'"playUrl"\s*:\s*"([^"]+\.(?:m3u8|mp4)[^"]*)"', clean)
        if m:
            url = m.group(1).replace("\\/", "/")
            return {"parse": 0, "url": url, "header": {"User-Agent": UA},
                    "contentType": "application/vnd.apple.mpegurl" if ".m3u8" in url else "video/mp4"}
        m = re.search(r"(https?:[^\"'\s<>]+\.m3u8[^\"'\s<>]*)", clean)
        if m:
            return {"parse": 0, "url": m.group(1), "header": {"User-Agent": UA},
                    "contentType": "application/vnd.apple.mpegurl"}
        return {"parse": 1, "url": raw}


class Spider(_BaseSpider):

    VERSION = "一键写PY通用版 v2.0"

    def __init__(self):
        if _BaseSpider is not object:
            try:
                _BaseSpider.__init__(self)
            except Exception:
                pass
        self.json = None
        self.html = HtmlSite()
        self.nextsite = NextSite()
        self.mode = None
        self.inited = False
        self._item_url = {}

    def getName(self):
        return SITE_NAME + "┃[py]"

    def getDependence(self):
        return {}

    def init(self, extend=""):
        if self.inited:
            return
        self.inited = True
        api = API_HINT
        if api and api.startswith("http"):
            self.json = JsonAPI(api)
            self.mode = "json"
            return
        if FORCE_MODE == "nextjs":
            self.mode = "nextjs"
            return
        if FORCE_MODE != "html":
            for path in ("/api.php/provide/vod", "/api.php/provide/vod/at/json",
                         "/provide/vod", "/api/vod"):
                d = _json(SITE.rstrip("/") + path, {"ac": "list"})
                if isinstance(d, dict) and d.get("list"):
                    self.json = JsonAPI(SITE.rstrip("/") + path)
                    self.mode = "json"
                    return
            try:
                home = _fetch(SITE.rstrip("/") + "/")
                if _next_is_nextjs(home):
                    self.mode = "nextjs"
                    return
            except Exception:
                pass
        self.mode = "html"
        self.html.sniff()

    def homeContent(self, filter):
        self.init("")
        cats, lst = [], []
        try:
            if self.mode == "json":
                cats = [{"type_id": t, "type_name": n} for t, n in self.json.cats()]
                items, _ = self.json.list(pg=1)
                lst = [self._vod(x) for x in items[:60]]
            elif self.mode == "nextjs":
                cats = [{"type_id": "n_" + t, "type_name": n} for t, n in self.nextsite.cats()]
                items, _ = self.nextsite.list(pg=1)
                lst = [self._vod(x) for x in items[:60]]
            else:
                cats = [{"type_id": "t_" + t, "type_name": n} for t, n in self.html.cats()]
                items, _ = self.html.list(pg=1)
                lst = [self._vod(x) for x in items[:60]]
        except Exception:
            pass
        if not cats:
            cats = [{"type_id": "all", "type_name": "全部"}]
        filters = {}
        try:
            if self.mode == "nextjs":
                for c in cats:
                    t = c["type_id"].replace("n_", "")
                    f = self.nextsite.filters(t)
                    if f:
                        filters[c["type_id"]] = f
            elif self.mode == "html":
                for c in cats:
                    t = c["type_id"].replace("t_", "")
                    if t == "all":
                        continue
                    try:
                        filters[c["type_id"]] = self.html.filters(t)
                    except Exception:
                        pass
        except Exception:
            filters = {}
        out = {"class": cats, "list": lst}
        if filters:
            out["filters"] = filters
        return out

    def homeVideoContent(self):
        self.init("")
        try:
            if self.mode == "json":
                items, _ = self.json.list(pg=1)
            elif self.mode == "nextjs":
                items, _ = self.nextsite.list(pg=1)
            else:
                items, _ = self.html.list(pg=1)
            return {"list": [self._vod(x) for x in items[:60]]}
        except Exception:
            return {"list": []}

    def categoryContent(self, tid, pg, filter, ext):
        self.init("")
        try:
            page = max(1, int(pg))
        except Exception:
            page = 1
        try:
            if self.mode == "json":
                items, pc = self.json.list(tid=tid, pg=page, ext=ext)
            elif self.mode == "nextjs":
                t = tid.replace("n_", "")
                items, pc = self.nextsite.list(tid=t, pg=page, ext=ext)
            else:
                t = tid.replace("t_", "")
                items, pc = self.html.list(tid=None if t == "all" else t, pg=page, ext=ext)
        except Exception:
            return {"page": page, "pagecount": 1, "limit": 60, "total": 0, "list": []}
        for x in items:
            if x.get("url"):
                self._item_url[x["id"]] = x["url"]
        return {"page": page, "pagecount": max(1, pc), "limit": 60,
                "total": max(1, pc) * 60, "list": [self._vod(x) for x in items]}

    def detailContent(self, array):
        self.init("")
        vid = str(array[0]) if isinstance(array, (list, tuple)) else str(array)
        try:
            if self.mode == "json":
                v = self.json.detail(vid)
            elif self.mode == "nextjs":
                v = self.nextsite.detail(vid)
            else:
                v = self.html.detail(vid, self._item_url.get(vid, ""))
        except Exception:
            v = None
        if not v:
            return {"list": []}
        dpic = v.get("pic", "") or ""
        if dpic and IMG_PROXY:
            try:
                dpic = IMG_PROXY + urllib.parse.quote(dpic, safe="")
            except Exception:
                dpic = IMG_PROXY + dpic
        return {"list": [{
            "vod_id": v["id"], "vod_name": v["name"], "vod_pic": dpic,
            "type_name": v.get("typename", ""), "vod_year": v.get("year", ""),
            "vod_area": v.get("area", ""), "vod_remarks": v.get("remarks", ""),
            "vod_actor": v.get("actor", ""), "vod_director": v.get("director", ""),
            "vod_content": v.get("content", ""),
            "vod_play_from": "$$$".join(v["shows"]),
            "vod_play_url": "$$$".join(
                "#".join("{}${}".format(e[0], e[1]) for e in g) for g in v["urls"]),
        }]}

    def searchContent(self, key, quick, pg="1"):
        self.init("")
        try:
            page = max(1, int(pg))
        except Exception:
            page = 1
        try:
            if self.mode == "json":
                items, _ = self.json.list(wd=str(key), pg=page)
            elif self.mode == "nextjs":
                items = self.nextsite.search(str(key), page)
            else:
                items = self.html.search(str(key), page)
        except Exception:
            items = []
        return {"list": [self._vod(x) for x in items], "page": page}

    def playerContent(self, flag, id, vipFlags):
        raw = str(id).strip()
        if getattr(self, "mode", None) == "nextjs":
            if not raw.startswith("http"):
                raw = _abs(raw)
            return self.nextsite.play(raw)
        if "$" in raw and raw.split("$", 1)[1].startswith("http"):
            raw = raw.split("$", 1)[1].strip()
            if re.search(r"\.(?:m3u8|mp4|flv|mkv|ts)(?:\?|$)", raw, re.I):
                return self._play(raw)
        if raw.startswith("http") and re.search(r"\.(m3u8|mp4|flv|mkv|ts)(\?|$)", raw, re.I):
            return self._play(raw)
        try:
            html = _fetch(raw)
            url = ""
            m = re.search(r"player_[a-zA-Z]*\s*=\s*(\{[\s\S]*?\})\s*;?\s*</script>", html)
            if m:
                try:
                    d = json.loads(m.group(1))
                    url = str(d.get("url") or "")
                except Exception:
                    pass
            if not url:
                url = _first(html, [
                    r'"url"\s*:\s*"([^"]+\.(?:m3u8|mp4)[^"]*)"',
                    r"(https?:[^\"'\s<>]+\.m3u8[^\"'\s<>]*)",
                    r"source\s*:\s*'([^']+\.(?:m3u8|mp4)[^']*)'",
                ])
            url = url.replace("\\/", "/")
            if url:
                return self._play(url)
        except Exception:
            pass
        return {"parse": 1, "url": raw}

    def _play(self, url):
        low = url.lower().split("?")[0]
        ct = ""
        if ".m3u8" in low:
            ct = "application/vnd.apple.mpegurl"
        elif ".mp4" in low:
            ct = "video/mp4"
        return {"parse": 0, "url": url, "header": {"User-Agent": UA}, "contentType": ct}

    def localProxy(self, param):
        url = ""
        headers = {}
        try:
            if isinstance(param, dict):
                url = param.get("url") or param.get("Url") or ""
                headers = param.get("headers") or param.get("header") or {}
            elif isinstance(param, (list, tuple)):
                if param:
                    url = str(param[0])
                if len(param) > 1 and isinstance(param[1], dict):
                    headers = param[1]
            elif isinstance(param, str):
                url = param
        except Exception:
            url = ""
        if not url:
            return {"code": 404, "content": "", "headers": {}}
        try:
            h = {"User-Agent": UA}
            for k, v in (headers or {}).items():
                h[str(k)] = str(v)
            req = urllib.request.Request(url, headers=h)
            with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
                raw = r.read()
                return {"code": r.getcode(),
                        "content": base64.b64encode(raw).decode("ascii"),
                        "headers": {"Content-Type": r.headers.get("Content-Type", "")}}
        except Exception as e:
            return {"code": 500, "content": "", "headers": {}, "msg": str(e)}

    def isVideoFormat(self, url):
        return False

    def isTextFormat(self, url):
        return False

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return {"code": 0, "msg": ""}

    def destroy(self):
        return "destroy"

    def _vod(self, x):
        pic = x.get("pic", "") or ""
        if pic and IMG_PROXY:
            try:
                pic = IMG_PROXY + urllib.parse.quote(pic, safe="")
            except Exception:
                pic = IMG_PROXY + pic
        return {"vod_id": str(x["id"]), "vod_name": x["name"],
                "vod_pic": pic, "vod_remarks": x.get("remark", "")}
