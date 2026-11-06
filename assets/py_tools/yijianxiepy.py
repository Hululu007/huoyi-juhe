# -*- coding: utf-8 -*-
"""One-click PY writer for Huoyi Juhe (Fire Ant Aggregation).

Paste a site URL, auto-detect its engine (Apple CMS JSON API, Next.js,
or generic HTML with auto sniffing) and generate a TVBox py source file
into the shared folder, then import it from the app site manager.

Adapted from a FongMiTV-oriented original: FongMi-only push/sync and
config files are removed; Activity lookup uses ActivityThread reflection
so it works inside the Flutter host activity; generated files land in the
shared output folder and a copy is kept in the app support folder.
"""

import base64
import hashlib
import json
import os
import re
import threading
import time
import urllib.parse
import urllib.request

try:
    from base.spider import Spider as BaseSpider
except Exception:
    BaseSpider = object

_UA = "Mozilla/5.0 (Linux; Android 11) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36"


def _detect_storage_root():
    candidates = []
    external = str(os.environ.get("EXTERNAL_STORAGE", "")).strip()
    if external:
        candidates.append(external)
    candidates.extend(("/sdcard", "/storage/emulated/0", os.path.expanduser("~/storage/shared")))
    seen = set()
    for candidate in candidates:
        path = os.path.abspath(os.path.expanduser(candidate))
        real = os.path.realpath(path)
        if real in seen:
            continue
        seen.add(real)
        if os.path.isdir(path):
            return real
    return os.path.abspath(external or "/sdcard")


STORAGE_ROOT = _detect_storage_root()
DEFAULT_SCAN_DIR = os.path.join(STORAGE_ROOT, "火蚁聚合", "一键写PY")


def _current_activity():
    try:
        from java import jclass
        thread_cls = jclass("android.app.ActivityThread")
        thread = thread_cls.currentActivityThread()
        if thread is None:
            return None
        field = thread.getClass().getDeclaredField("mActivities")
        field.setAccessible(True)
        activities = field.get(thread)
        records = []
        try:
            n = int(activities.size())
            for i in range(n):
                records.append(activities.valueAt(i))
        except Exception:
            try:
                for rec in activities.values():
                    records.append(rec)
            except Exception:
                return None
        fallback = None
        for rec in records:
            if rec is None:
                continue
            act = None
            try:
                f = rec.getClass().getDeclaredField("activity")
                f.setAccessible(True)
                act = f.get(rec)
            except Exception:
                try:
                    act = rec.activity
                except Exception:
                    act = None
            if act is None:
                continue
            paused = True
            try:
                pf = rec.getClass().getDeclaredField("paused")
                pf.setAccessible(True)
                paused = bool(pf.getBoolean(rec))
            except Exception:
                try:
                    paused = bool(rec.paused)
                except Exception:
                    paused = True
            if not paused:
                return act
            fallback = act
        return fallback
    except Exception:
        return None


def _toast(activity, msg):
    try:
        from java import jclass
        toast_cls = jclass("android.widget.Toast")
        toast_cls.makeText(activity, str(msg), toast_cls.LENGTH_LONG).show()
    except Exception:
        pass


def _support_dir():
    try:
        act = _current_activity()
        if act is None:
            return None
        try:
            f = act.getFilesDir()
            if f is not None:
                p = str(f.getAbsolutePath())
                if p:
                    return p
        except Exception:
            pass
        try:
            f = act.getExternalFilesDir(None)
            if f is not None:
                p = str(f.getAbsolutePath())
                if p:
                    return p
        except Exception:
            pass
    except Exception:
        pass
    return None


def _settings_path():
    sup = _support_dir()
    if sup:
        return os.path.join(sup, "yijianxiepy_settings.json")
    return os.path.join(DEFAULT_SCAN_DIR, ".yijianxiepy_settings.json")


def _proxy_fetch(param, ua=_UA, timeout=15):
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
        h = {"User-Agent": ua}
        for k, v in (headers or {}).items():
            h[str(k)] = str(v)
        req = urllib.request.Request(url, headers=h)
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            return {
                "code": resp.getcode(),
                "content": base64.b64encode(raw).decode("ascii"),
                "headers": {"Content-Type": resp.headers.get("Content-Type", "")},
            }
    except Exception as exc:
        return {"code": 500, "content": "", "headers": {}, "msg": str(exc)}

UNIVERSAL_PY_TEMPLATE = r'''import base64
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
'''

PY_TEMPLATE = UNIVERSAL_PY_TEMPLATE
HTML_PY_TEMPLATE = UNIVERSAL_PY_TEMPLATE

class RemoteSite(object):

    def __init__(self, base, name, gen_code, force="auto", bases=None):
        self.base = str(base).strip().rstrip("/")
        self.name = name
        self.sp = None
        self.cats = []
        self.ready = False
        try:
            code = (gen_code
                    .replace("@NAME@", name)
                    .replace("@SITE@", self.base)
                    .replace("@BASES@", repr(bases or [self.base]))
                    .replace("@API@", "")
                    .replace("@FORCE@", force)
                    .replace("@IMGPROXY@", "")
                    .replace("@MODE@", "自动")
                    .replace("@TS@", ""))
            ns = {"__name__": "remote_" + re.sub(r"\W", "_", name)}
            exec(compile(code, "remote_" + name, "exec"), ns)
            self.ns = ns
            self.sp = ns["Spider"]()
        except Exception:
            self.sp = None

    def _prepare(self):
        if self.ready or self.sp is None:
            return self.sp is not None
        try:
            self.sp.init("")
            self.ready = True
        except Exception:
            pass
        return self.ready

    def load_cats(self):
        if not self._prepare():
            return
        try:
            hc = self.sp.homeContent(False)
            cats = hc.get("class") or []
            self.cats = [c for c in cats if c.get("type_id")][:14]
        except Exception:
            pass

    def _norm(self, v):
        return {
            "id": str(v.get("vod_id", "")),
            "name": str(v.get("vod_name", "")).strip(),
            "pic": str(v.get("vod_pic", "") or ""),
            "remark": str(v.get("vod_remarks", "") or ""),
        }

    def list_home(self, pg):
        if not self._prepare():
            return [], 1
        try:
            items = (self.sp.homeVideoContent() or {}).get("list") or []
            return [self._norm(x) for x in items], (pg + 1 if items else 1)
        except Exception:
            return [], 1

    def list_cat(self, tid, pg):
        if not self._prepare():
            return [], 1
        try:
            res = self.sp.categoryContent(tid, pg, False, "")
            items = [self._norm(x) for x in (res.get("list") or [])]
            return items, max(1, int(res.get("pagecount", 1)))
        except Exception:
            return [], 1

    def search(self, wd, pg):
        if not self._prepare():
            return []
        try:
            res = self.sp.searchContent(str(wd), False, str(pg))
            return [self._norm(x) for x in (res.get("list") or [])]
        except Exception:
            return []

    def detail(self, vid):
        if not self._prepare():
            return None
        try:
            res = self.sp.detailContent([str(vid)])
            lst = res.get("list") or []
            return lst[0] if lst else None
        except Exception:
            return None

    def play(self, flag, rid):
        if not self._prepare():
            return {"parse": 1, "url": rid}
        try:
            return self.sp.playerContent(flag, rid, "")
        except Exception:
            return {"parse": 1, "url": rid}


class Spider(BaseSpider):

    VERSION = "v2.0"

    RESCAN_ID = "__py_scan_rescan__"
    EDIT_DIR_ID = "__py_scan_edit_dir__"
    WRITE_ID = "__py_write__"
    IMGFIX_ID = "__py_imgfix__"
    BROWSER_ID = "__py_browser__"
    SHELL_TOOL_ID = "__py_shelltool__"
    MUSIC_ID = "__py_music__"

    ACTION_RESCAN = "py_scan_rescan"
    ACTION_EDIT_DIR = "py_scan_edit_dir"
    ACTION_WRITE = "py_write_input"
    ACTION_IMGFIX = "py_imgfix_input"
    ACTION_BROWSER = "py_browser"
    ACTION_SHELL_TOOL = "py_shelltool"
    ACTION_MUSIC = "py_music"

    SHELL_TOOL_URL = "https://56.al/"
    MUSIC_URL = "https://tonzhon.com/"

    MAX_SCAN_DEPTH = 8
    MAX_SCAN_FILES = 3000
    MAX_SOURCE_SIZE = 5 * 1024 * 1024

    def __init__(self):
        if BaseSpider is not object:
            try:
                BaseSpider.__init__(self)
            except Exception:
                pass
        self.lock = threading.RLock()
        self.inited = False
        self.scan_dir = DEFAULT_SCAN_DIR
        self.sources = []
        self.status = self._empty_status()
        self._dialog_refs = []
        self.remotes = []
        self.remotes_loaded = False
        self.cur_remote = None

    def getName(self):
        return "一键写PY {}".format(self.VERSION)

    def getDependence(self):
        return {}

    def _empty_status(self):
        return {
            "scan_time": "-",
            "found": 0,
            "included": 0,
            "skipped": 0,
            "write_state": "尚未扫描",
            "error": "",
            "warnings": [],
        }

    def init(self, extend=""):
        with self.lock:
            if self.inited:
                return
            self._load_settings()
            try:
                self._refresh()
            except Exception as exc:
                self.status["warnings"].append("启动扫描失败: {}".format(exc))
            self.inited = True

    def destroy(self):
        return "destroy"

    def _load_settings(self):
        try:
            path = _settings_path()
            if not os.path.isfile(path):
                return
            with open(path, "r", encoding="utf-8") as fp:
                data = json.load(fp)
            if isinstance(data, dict):
                value = str(data.get("scan_dir", "")).strip()
                if value:
                    self.scan_dir = value
        except Exception:
            pass

    def _save_settings(self):
        try:
            path = _settings_path()
            parent = os.path.dirname(path)
            if parent and not os.path.isdir(parent):
                os.makedirs(parent, exist_ok=True)
            with open(path, "w", encoding="utf-8") as fp:
                json.dump({"scan_dir": self.scan_dir}, fp, ensure_ascii=False, indent=2)
        except Exception:
            pass


    def _is_spider_file(self, path):
        try:
            with open(path, "rb") as fp:
                data = fp.read(256 * 1024)
            text = data.decode("utf-8", errors="ignore")
        except Exception:
            return False
        return bool(re.search(r"\bclass\s+Spider\s*(?:\(|:)", text))

    def _scan(self):
        self.sources = []
        self.status = self._empty_status()
        self.status["scan_time"] = time.strftime("%Y-%m-%d %H:%M:%S")
        root = os.path.abspath(os.path.expanduser(self.scan_dir))
        if not os.path.isdir(root):
            self.status["write_state"] = "目录不存在"
            self.status["error"] = "扫描目录不存在: {}".format(root)
            return False
        self_path = os.path.realpath(__file__)
        found = 0
        included = 0
        skipped = 0
        for current, dirs, files in os.walk(root, topdown=True, followlinks=False):
            rel = os.path.relpath(current, root)
            depth = 0 if rel == "." else rel.count(os.sep) + 1
            dirs[:] = sorted(
                [d for d in dirs if not d.startswith(".") and d != "__pycache__"],
                key=lambda v: v.lower(),
            )
            if depth >= self.MAX_SCAN_DEPTH:
                dirs[:] = []
            for file_name in sorted(files, key=lambda v: v.lower()):
                if not file_name.lower().endswith(".py"):
                    continue
                if file_name == "__init__.py":
                    continue
                if found >= self.MAX_SCAN_FILES:
                    break
                full_path = os.path.join(current, file_name)
                if os.path.islink(full_path) or not os.path.isfile(full_path):
                    continue
                real_path = os.path.realpath(full_path)
                if real_path == self_path:
                    continue
                found += 1
                try:
                    stat = os.stat(real_path)
                    if stat.st_size <= 0 or stat.st_size > self.MAX_SOURCE_SIZE:
                        skipped += 1
                        continue
                except Exception:
                    skipped += 1
                    continue
                if not self._is_spider_file(real_path):
                    skipped += 1
                    continue
                relative = os.path.relpath(real_path, root).replace(os.sep, "/")
                self.sources.append({
                    "path": real_path,
                    "relative": relative,
                    "base_name": file_name[:-3],
                })
                included += 1
        self._apply_display_names()
        self.status["found"] = found
        self.status["included"] = included
        self.status["skipped"] = skipped
        self.status["write_state"] = "扫描完成"
        return True

    def _apply_display_names(self):
        counts = {}
        for source in self.sources:
            key = source["base_name"].lower()
            counts[key] = counts.get(key, 0) + 1
        for source in self.sources:
            base = source["base_name"]
            if counts.get(base.lower(), 0) > 1:
                folder = os.path.dirname(source["relative"])
                suffix = folder.replace("/", " · ") if folder else "根目录"
                source["name"] = "{} [{}]┃[py]".format(base, suffix)
            else:
                source["name"] = base + "┃[py]"

    def _file_url(self, path):
        absolute = os.path.realpath(os.path.abspath(path))
        storage_root = os.path.realpath(STORAGE_ROOT)
        try:
            relative = os.path.relpath(absolute, storage_root).replace(os.sep, "/")
        except Exception:
            relative = ""
        if relative and relative != ".." and not relative.startswith("../"):
            return "file://" + relative.lstrip("/")
        return "file://" + absolute

    def _source_hash(self, source):
        return hashlib.sha256(source["path"].encode("utf-8")).hexdigest()[:12]

    def _refresh(self):
        ok = self._scan()
        self.remotes_loaded = False
        self.remotes = []
        return ok

    def _safe_name(self, site):
        try:
            host = urllib.parse.urlparse(site).netloc or site
        except Exception:
            host = site
        host = host.replace("www.", "")
        name = re.sub(r"[^0-9A-Za-z\u4e00-\u9fa5]+", "", host.split(":")[0])
        return name or "生成源"

    def _site_alive(self, site):
        try:
            req = urllib.request.Request(
                site + "/", headers={"User-Agent": "Mozilla/5.0"})
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            with opener.open(req, timeout=6) as r:
                return r.getcode() == 200
        except Exception:
            return False

    def _is_nextjs_site(self, site):
        try:
            req = urllib.request.Request(
                site.rstrip("/") + "/", headers={"User-Agent": "Mozilla/5.0"})
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            with opener.open(req, timeout=8) as r:
                html = r.read().decode("utf-8", errors="ignore")
            return "/_next/static" in html and "/vod/play/" in html and "/detail/" in html
        except Exception:
            return False

    def _probe_site(self, site):
        site = site.rstrip("/")
        candidates = [
            "/api.php/provide/vod",
            "/api.php/provide/vod/at/json",
            "/provide/vod",
            "/api/vod",
        ]
        for path in candidates:
            try:
                url = site + path
                req = urllib.request.Request(
                    url + ("&" if "?" in url else "?") + "ac=list",
                    headers={"User-Agent": "Mozilla/5.0"},
                )
                opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
                with opener.open(req, timeout=8) as r:
                    data = json.loads(r.read().decode("utf-8", errors="ignore").lstrip("\ufeff"))
                if isinstance(data, dict) and data.get("list"):
                    return url
            except Exception:
                continue
        return None

    def _fetch_home(self, site):
        try:
            req = urllib.request.Request(
                site.rstrip("/") + "/",
                headers={"User-Agent": "Mozilla/5.0"})
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            with opener.open(req, timeout=8) as r:
                return r.read().decode("utf-8", errors="ignore")
        except Exception:
            return ""

    def _probe_tvbox_api(self, site, home_html):
        hosts = []
        for m in re.finditer(r"https?://([A-Za-z0-9.\-]+)(?::\d+)?/api/tvbox/", home_html or ""):
            if m.group(1) not in hosts:
                hosts.append(m.group(1))
        try:
            base_host = urllib.parse.urlparse(site).netloc
        except Exception:
            base_host = ""
        if base_host and base_host not in hosts:
            hosts.append(base_host)
        for host in hosts:
            try:
                url = "https://" + host + "/api/tvbox/home?nav=1"
                req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
                opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
                with opener.open(req, timeout=8) as r:
                    data = json.loads(r.read().decode("utf-8", errors="ignore").lstrip("\ufeff"))
                if isinstance(data, dict) and (data.get("nav") or data.get("list") or data.get("data")):
                    return "https://" + host
            except Exception:
                continue
        return None

    def _probe_maccms(self, home_html):
        html = home_html or ""
        pats = ("/vod/detail/", "/vod/play/", "/vod/type/", "/vod/search/",
                "/voddetail/", "/vodplay/", "/vodtype/", "/vodsearch/",
                "/index.php/vod/")
        return any(p in html for p in pats)

    def _probe_wordpress(self, site):
        try:
            url = site.rstrip("/") + "/wp-json/wp/v2/"
            req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            with opener.open(req, timeout=8) as r:
                data = json.loads(r.read().decode("utf-8", errors="ignore").lstrip("\ufeff"))
            return isinstance(data, dict) and ("routes" in data or "name" in data or "namespaces" in data)
        except Exception:
            return False

    def _copy_to_support(self, path, file_name):
        try:
            sup = _support_dir()
            if not sup:
                return False
            d = os.path.join(sup, "imported_py")
            if not os.path.isdir(d):
                os.makedirs(d, exist_ok=True)
            with open(path, "rb") as src:
                data = src.read()
            with open(os.path.join(d, file_name), "wb") as dst:
                dst.write(data)
            return True
        except Exception:
            return False

    def _generate_code(self, site, name="", hint_template=""):
        site = (site or "").strip()
        if not site:
            return {"ok": False, "error": "empty site url"}
        if "#" in site:
            site, name_in = site.split("#", 1)
            name_in = name_in.strip()
            if name_in and not name:
                name = name_in
        parts = [x.strip() for x in site.split("|") if x.strip()]
        bases = []
        for x in parts:
            if not x.startswith("http"):
                x = "https://" + x
            bases.append(x.rstrip("/"))
        if not bases:
            return {"ok": False, "error": "empty site url"}
        if not name:
            name = self._safe_name(bases[0])
        hint = (hint_template or "").strip()
        order = ["apple_cms_v10", "tvbox_api", "maccms_html", "wordpress", "nextjs"]
        if hint in order:
            order = [hint] + [x for x in order if x != hint]
        home_cache = {}

        def home_of(base):
            if base not in home_cache:
                home_cache[base] = self._fetch_home(base)
            return home_cache[base]

        found = None
        for base in bases:
            for tid in order:
                if tid == "apple_cms_v10":
                    api_url = self._probe_site(base)
                    if api_url:
                        found = (base, tid, "json", "apple cms json", api_url)
                        break
                elif tid == "tvbox_api":
                    api_host = self._probe_tvbox_api(base, home_of(base))
                    if api_host:
                        found = (base, tid, "html", "tvbox api", api_host)
                        break
                elif tid == "maccms_html":
                    if self._probe_maccms(home_of(base)):
                        found = (base, tid, "html", "maccms html", "")
                        break
                elif tid == "wordpress":
                    if self._probe_wordpress(base):
                        found = (base, tid, "html", "wordpress", "")
                        break
                elif tid == "nextjs":
                    if self._is_nextjs_site(base):
                        found = (base, tid, "nextjs", "nextjs", "")
                        break
            if found:
                break
            if self._site_alive(base):
                found = (base, "generic_html", "html", "generic html sniffing", "")
                break
        if not found:
            found = (bases[0], "generic_html", "html", "generic html sniffing", "")
        base, template_id, force, mode, api = found
        ordered = [base] + [x for x in bases if x != base]
        code = (UNIVERSAL_PY_TEMPLATE
                .replace("@NAME@", name)
                .replace("@SITE@", base)
                .replace("@BASES@", repr(ordered))
                .replace("@API@", api)
                .replace("@FORCE@", force)
                .replace("@IMGPROXY@", self._img_proxy())
                .replace("@MODE@", mode)
                .replace("@TS@", time.strftime("%Y-%m-%d %H:%M:%S")))
        return {
            "ok": True,
            "name": name,
            "source": code,
            "mode": mode,
            "template_id": template_id,
            "api": api,
            "bases": ordered,
        }

    def _write_py_from_site(self, site, name=""):
        result = self._generate_code(site, name)
        if not result.get("ok"):
            return False, result.get("error") or "生成失败"
        code = result["source"]
        name = result["name"]
        mode = result["mode"]
        api = result["api"]
        template_id = result["template_id"]
        if template_id == "apple_cms_v10":
            mode_label = "JSON接口模式"
        elif template_id == "nextjs":
            mode_label = "Next.js模式"
        else:
            mode_label = "通用网页引擎（自动嗅探）"
        try:
            out_dir = os.path.abspath(os.path.expanduser(self.scan_dir))
            if not os.path.isdir(out_dir):
                os.makedirs(out_dir, exist_ok=True)
            file_name = "一键_{}.py".format(name)
            path = os.path.join(out_dir, file_name)
            with open(path, "w", encoding="utf-8") as fp:
                fp.write(code)
        except Exception as exc:
            return False, "写py失败: {}".format(exc)
        copied = self._copy_to_support(path, file_name)
        msg = "已生成[{}]\n{}".format(mode_label, path)
        if api:
            msg += "\n接口: {}".format(api)
        if copied:
            msg += "\n已同步一份到应用支持目录 imported_py/"
        msg += "\n去站源管理导入 py 文件即可使用"
        return True, msg

    def _img_proxy_file(self):
        return os.path.join(os.path.abspath(os.path.expanduser(self.scan_dir)), ".imgproxy")

    def _img_proxy(self):
        try:
            with open(self._img_proxy_file(), "r", encoding="utf-8") as fp:
                return fp.read().strip()
        except Exception:
            return ""

    def _apply_img_proxy(self, proxy):
        proxy = (proxy or "").strip()
        try:
            out_dir = os.path.abspath(os.path.expanduser(self.scan_dir))
            if not os.path.isdir(out_dir):
                os.makedirs(out_dir, exist_ok=True)
            with open(self._img_proxy_file(), "w", encoding="utf-8") as fp:
                fp.write(proxy)
        except Exception as exc:
            return False, "保存设置失败: {}".format(exc)
        changed = 0
        try:
            for fn in os.listdir(out_dir):
                if not fn.endswith(".py"):
                    continue
                path = os.path.join(out_dir, fn)
                try:
                    with open(path, "r", encoding="utf-8") as fp:
                        code = fp.read()
                except Exception:
                    continue
                if "IMG_PROXY = " not in code:
                    continue
                new = re.sub(r'IMG_PROXY = ".*?"',
                             'IMG_PROXY = "{}"'.format(proxy.replace("\\", "\\\\")),
                             code, count=1)
                if new != code:
                    with open(path, "w", encoding="utf-8") as fp:
                        fp.write(new)
                    changed += 1
        except Exception as exc:
            return False, "改写py失败: {}".format(exc)
        return True, "已应用图修复到 {} 个py".format(changed)

    def _toggle_img_fix(self):
        if self._img_proxy():
            ok, msg = self._apply_img_proxy("")
            return ("图修复已关闭，封面恢复直连。回首页下拉刷新生效。" if ok
                    else "关闭失败: " + msg), ok
        ok, msg = self._apply_img_proxy("https://wsrv.nl/?url=")
        if not ok:
            return "开启失败: " + msg, False
        with self.lock:
            self._refresh()
        return ("图修复已开启（封面走代理）。{}\n回首页下拉刷新即可看到封面".format(msg)), True

    def _open_write_dialog(self):
        try:
            from java import dynamic_proxy, jclass

            toast_class = jclass("android.widget.Toast")
            click_listener = jclass("android.content.DialogInterface$OnClickListener")
            runnable_class = jclass("java.lang.Runnable")
            edit_text_class = jclass("android.widget.EditText")
            frame_layout_class = jclass("android.widget.FrameLayout")
            try:
                builder_class = jclass(
                    "com.google.android.material.dialog.MaterialAlertDialogBuilder"
                )
            except Exception:
                builder_class = jclass("android.app.AlertDialog$Builder")

            activity = _current_activity()
            if activity is None:
                return False, "取不到当前页面"
            owner = self

            def toast(msg):
                _toast(activity, msg)

            class DoWrite(dynamic_proxy(runnable_class)):
                def run(self):
                    try:
                        text = str(holder["edit"].getText()).strip()
                        if not text:
                            toast("请输入网站地址")
                            return
                        ok, msg = owner._write_py_from_site(text)
                        if not ok:
                            toast(msg)
                            return
                        with owner.lock:
                            owner._refresh()
                        toast(msg)
                    except Exception as exc:
                        toast("写PY失败: " + str(exc))

            class WriteClick(dynamic_proxy(click_listener)):
                def onClick(self, dialog, which):
                    try:
                        activity.runOnUiThread(DoWrite())
                    except Exception as exc:
                        toast("错误: " + str(exc))

            class ShowRunner(dynamic_proxy(runnable_class)):
                def run(self):
                    try:
                        try:
                            edit = edit_text_class.newInstance()
                        except Exception:
                            edit = edit_text_class(activity)
                        try:
                            edit.setHint("粘贴网站，如 https://example.com")
                        except Exception:
                            pass
                        try:
                            edit.setSingleLine(True)
                        except Exception:
                            pass
                        pad = 40
                        wrap = frame_layout_class(activity)
                        wrap.setPadding(pad, pad, pad, 0)
                        wrap.addView(edit)
                        b = builder_class(activity)
                        b.setTitle("一键写PY · 输入网站")
                        b.setView(wrap)
                        b.setPositiveButton("生成", WriteClick())
                        b.setNegativeButton("取消", None)
                        d = b.show()
                        holder["edit"] = edit
                        owner._dialog_refs.append(d)
                        owner._dialog_refs = owner._dialog_refs[-8:]
                    except Exception as exc:
                        toast("打开失败: " + str(exc))

            holder = {"edit": None}
            runner = ShowRunner()
            self._dialog_refs.append(runner)
            activity.runOnUiThread(runner)
            return True, ""
        except Exception as exc:
            return False, "打开输入框失败: {}".format(exc)

    def _open_dir_browser(self):
        try:
            from java import dynamic_proxy, jclass, jarray
            from java.lang import String as JString

            toast_class = jclass("android.widget.Toast")
            click_listener = jclass("android.content.DialogInterface$OnClickListener")
            runnable_class = jclass("java.lang.Runnable")
            try:
                builder_class = jclass(
                    "com.google.android.material.dialog.MaterialAlertDialogBuilder"
                )
            except Exception:
                builder_class = jclass("android.app.AlertDialog$Builder")

            activity = _current_activity()
            if activity is None:
                return False, "取不到当前页面"
            owner = self

            start = os.path.abspath(os.path.expanduser(owner.scan_dir or DEFAULT_SCAN_DIR))
            if not os.path.isdir(start):
                start = os.path.realpath(STORAGE_ROOT)
            state = {"path": start, "showing": False, "dialog": None}

            def list_dirs(path):
                try:
                    return sorted(
                        [
                            d
                            for d in os.listdir(path)
                            if os.path.isdir(os.path.join(path, d)) and not d.startswith(".")
                        ],
                        key=lambda v: v.lower(),
                    )
                except Exception:
                    return []

            def dismiss_current():
                d = state.get("dialog")
                if d is not None:
                    try:
                        d.dismiss()
                    except Exception:
                        pass
                state["dialog"] = None

            def schedule_show():
                if state["showing"]:
                    return
                state["showing"] = True
                runner = ShowRunner()
                owner._dialog_refs.append(runner)
                owner._dialog_refs = owner._dialog_refs[-8:]
                activity.runOnUiThread(runner)

            def navigate_to(new_path):
                state["path"] = new_path
                dismiss_current()
                schedule_show()

            def use_current():
                path = state["path"]
                with owner.lock:
                    owner.scan_dir = path
                    owner._save_settings()
                    try:
                        owner._refresh()
                    except Exception as exc:
                        toast_class.makeText(
                            activity, "扫描失败: " + str(exc), toast_class.LENGTH_LONG
                        ).show()
                        return
                dismiss_current()
                toast_class.makeText(
                    activity,
                    "已选择并扫描: {} ({} 个PY源)".format(path, len(owner.sources)),
                    toast_class.LENGTH_LONG,
                ).show()

            class ItemClick(dynamic_proxy(click_listener)):
                def onClick(self, dialog, which):
                    try:
                        idx = int(which)
                        path = state["path"]
                        dirs = list_dirs(path)
                        has_parent = os.path.dirname(path) != path
                        offset = 0
                        if has_parent:
                            if idx == 0:
                                navigate_to(os.path.dirname(path))
                                return
                            offset = 1
                        di = idx - offset
                        if 0 <= di < len(dirs):
                            navigate_to(os.path.join(path, dirs[di]))
                    except Exception as exc:
                        try:
                            toast_class.makeText(
                                activity, "错误: " + str(exc), toast_class.LENGTH_LONG
                            ).show()
                        except Exception:
                            pass

            class UseButton(dynamic_proxy(click_listener)):
                def onClick(self, dialog, which):
                    try:
                        use_current()
                    except Exception as exc:
                        try:
                            toast_class.makeText(
                                activity, "错误: " + str(exc), toast_class.LENGTH_LONG
                            ).show()
                        except Exception:
                            pass

            class ShowRunner(dynamic_proxy(runnable_class)):
                def run(self):
                    try:
                        path = state["path"]
                        dirs = list_dirs(path)
                        labels = []
                        if os.path.dirname(path) != path:
                            labels.append("⬆  返回上级目录")
                        if not dirs:
                            labels.append("（没有子文件夹）")
                        else:
                            for d in dirs:
                                labels.append("📁  " + d)
                        arr = jarray(JString)(labels)
                        b = builder_class(activity)
                        b.setTitle(path)
                        b.setItems(arr, ItemClick())
                        b.setPositiveButton("使用此目录", UseButton())
                        b.setNegativeButton("取消", None)
                        d = b.show()
                        state["dialog"] = d
                        owner._dialog_refs.append(d)
                        owner._dialog_refs = owner._dialog_refs[-8:]
                    except Exception as exc:
                        try:
                            toast_class.makeText(
                                activity,
                                "打开失败: " + str(exc),
                                toast_class.LENGTH_LONG,
                            ).show()
                        except Exception:
                            pass
                    finally:
                        state["showing"] = False

            schedule_show()
            return True, ""
        except Exception as exc:
            return False, "打开目录选择器失败: {}".format(exc)

    def _load_remotes(self):
        if self.remotes_loaded:
            return
        self.remotes_loaded = True
        seen = set()
        self.remotes = []
        for source in self.sources:
            try:
                with open(source["path"], "r", encoding="utf-8", errors="ignore") as fp:
                    head = fp.read(64 * 1024)
            except Exception:
                continue
            m = re.search(r'SITE\s*=\s*["\']([^"\']+)["\']', head)
            if not m:
                continue
            base = m.group(1).strip().rstrip("/")
            if base in seen:
                continue
            seen.add(base)
            fm = re.search(r'FORCE_MODE\s*=\s*["\'](\w+)["\']', head)
            force = fm.group(1) if fm else "auto"
            bm = re.search(r'BASES\s*=\s*(\[[^\]]*\])', head)
            bases = None
            if bm:
                try:
                    import ast as _ast
                    v = _ast.literal_eval(bm.group(1))
                    if isinstance(v, list) and v:
                        bases = [str(x).rstrip("/") for x in v]
                except Exception:
                    bases = None
            name = source["base_name"].replace("一键_", "")
            self.remotes.append({
                "base": base, "name": name,
                "remote": RemoteSite(base, name, UNIVERSAL_PY_TEMPLATE, force, bases),
                "cats": [], "catmap": [],
            })
        t = threading.Thread(target=self._probe_async, daemon=True)
        t.start()

    def _probe_async(self):
        for r in self.remotes:
            try:
                r["remote"].load_cats()
                cm = []
                for c in r["remote"].cats:
                    cm.append(str(c.get("type_id")))
                r["cats"] = r["remote"].cats
                r["catmap"] = cm
            except Exception:
                pass

    def _remote(self, i):
        if 0 <= i < len(self.remotes):
            r = self.remotes[i]
            if r["remote"].sp is not None:
                self.cur_remote = r["remote"]
                return r["remote"]
        self.cur_remote = None
        return None

    @staticmethod
    def _empty(page):
        return {"page": page, "pagecount": 1, "limit": 60, "total": 0, "list": []}

    @staticmethod
    def _parse_col_id(s):
        s = str(s)
        if not s.startswith("col"):
            return -1, None
        body = s[3:]
        if body.endswith("_home"):
            try:
                return int(body[:-5]), None
            except Exception:
                return -1, None
        if "_t" in body:
            a, b = body.split("_t", 1)
            try:
                return int(a), b
            except Exception:
                return -1, None
        try:
            return int(body), None
        except Exception:
            return -1, None

    def homeContent(self, filter):
        try:
            with self.lock:
                if not self.inited:
                    self.init("")
                self._load_remotes()
            cats = [
                {"type_id": "all", "type_name": "PY源 ({})".format(len(self.sources))},
            ]
            for i, r in enumerate(self.remotes):
                cats.append({"type_id": "col{}_home".format(i), "type_name": r["name"]})
                for j, c in enumerate(r.get("cats") or []):
                    cats.append({
                        "type_id": "col{}_t{}".format(i, j),
                        "type_name": "{}·{}".format(r["name"], c.get("type_name", "")),
                    })
            return {"class": cats, "list": self._home_items()}
        except Exception as exc:
            try:
                self.status["warnings"].append("主页: {}".format(exc))
            except Exception:
                pass
            return {"class": [{"type_id": "all", "type_name": "PY源"}],
                    "list": self._home_items()}

    def homeVideoContent(self):
        try:
            with self.lock:
                if not self.inited:
                    self.init("")
                self._load_remotes()
            return {"list": self._home_items()}
        except Exception:
            return {"list": []}

    def _home_items(self):
        return [
            {
                "vod_id": self.WRITE_ID,
                "vod_name": "一键写PY",
                "vod_pic": "https://files.seeusercontent.com/2026/10/13/g0dS/1791894305322_edit_2712206973539.png",
                "vod_remarks": "输入网站自动生成py",
                "action": self.ACTION_WRITE,
            },
            {
                "vod_id": self.RESCAN_ID,
                "vod_name": "扫描",
                "vod_pic": "https://files.seeusercontent.com/2026/10/13/g0dS/1791894305322_edit_2712206973539.png",
                "vod_remarks": "重新扫描目录",
                "action": self.ACTION_RESCAN,
            },
            {
                "vod_id": self.EDIT_DIR_ID,
                "vod_name": "设置目录",
                "vod_pic": "https://files.seeusercontent.com/2026/10/13/g0dS/1791894305322_edit_2712206973539.png",
                "vod_remarks": "选择py目录",
                "action": self.ACTION_EDIT_DIR,
            },
            {
                "vod_id": self.IMGFIX_ID,
                "vod_name": "图修复",
                "vod_pic": "https://files.seeusercontent.com/2026/10/13/g0dS/1791894305322_edit_2712206973539.png",
                "vod_remarks": "已开启·点关闭" if self._img_proxy() else "封面裂图点一下",
                "action": self.ACTION_IMGFIX,
            },
            {
                "vod_id": self.BROWSER_ID,
                "vod_name": "浏览器",
                "vod_pic": "https://ts1.tc.mm.bing.net/th/id/R-C.ebb76677ab39b223db950498034e6d8d?rik=jgHby9tVOe2aRg&riu=http%3a%2f%2fwww.googlechromer.com%2fphotos%2fgooglechrome.jpg&ehk=elSX3GOBvM6IzE59EH%2bdSQpxHN1fcw%2b31xm%2f3Ho3VcA%3d&risl=&pid=ImgRaw&r=0",
                "vod_remarks": "内置浏览器·点开即用",
                "action": self.ACTION_BROWSER,
            },
            {
                "vod_id": self.SHELL_TOOL_ID,
                "vod_name": "脱壳工具",
                "vod_pic": "https://ts1.tc.mm.bing.net/th/id/OIP-C.yl-8hXD-bFdJVQFxgQ5LHQAAAA?r=0&dpr=3.3&pid=ImgDetMain&o=7&rm=3",
                "vod_remarks": "APK脱壳·56.al",
                "action": self.ACTION_SHELL_TOOL,
            },
            {
                "vod_id": self.MUSIC_ID,
                "vod_name": "音乐播放器",
                "vod_pic": "https://pic3.zhimg.com/80/v2-92d475f7a6938a51f5024fb1114e652a_qhd.jpg",
                "vod_remarks": "在线音乐·tonzhon",
                "action": self.ACTION_MUSIC,
            },
        ]

    def categoryContent(self, tid, pg, filter, ext):
        with self.lock:
            if not self.inited:
                self.init("")
            self._load_remotes()
        try:
            page = max(1, int(pg))
        except Exception:
            page = 1
        si, stid = self._parse_col_id(tid)
        if si >= 0:
            remote = self._remote(si)
            if not remote:
                return self._empty(page)
            try:
                if stid is None:
                    items, total_pg = remote.list_home(page)
                else:
                    r = self.remotes[si] if 0 <= si < len(self.remotes) else None
                    real_tid = None
                    if r is not None:
                        try:
                            idx = int(stid)
                            real_tid = r["catmap"][idx] if idx < len(r["catmap"]) else None
                        except Exception:
                            real_tid = stid
                    if real_tid is None:
                        return self._empty(page)
                    items, total_pg = remote.list_cat(real_tid, page)
            except Exception:
                return self._empty(page)
            for x in items:
                x["id"] = "cd{}_{}".format(si, x["id"])
            return {
                "page": page,
                "pagecount": max(1, total_pg),
                "limit": 60,
                "total": max(1, total_pg) * 60,
                "list": [self._vod(x) for x in items],
            }
        items = list(self.sources) if tid == "all" else []
        return self._paged(items, page)

    def _paged(self, items, page):
        page_size = 60
        total = len(items)
        page_count = max(1, (total + page_size - 1) // page_size)
        if page > page_count:
            page_items = []
        else:
            start = (page - 1) * page_size
            page_items = items[start:start + page_size]
        return {
            "page": page,
            "pagecount": page_count,
            "limit": page_size,
            "total": total,
            "list": [self._to_vod(item) for item in page_items],
        }

    def _source_id(self, source):
        return "src_" + hashlib.sha256(source["path"].encode("utf-8")).hexdigest()[:16]

    def _vod(self, x):
        return {
            "vod_id": x["id"],
            "vod_name": x["name"],
            "vod_pic": x.get("pic", ""),
            "vod_remarks": x.get("remark", ""),
        }

    def _detail(self, v):
        return {
            "vod_id": v["id"],
            "vod_name": v["name"],
            "vod_pic": v.get("pic", ""),
            "type_name": v.get("type", ""),
            "vod_year": v.get("year", ""),
            "vod_area": v.get("area", ""),
            "vod_remarks": v.get("remarks", ""),
            "vod_actor": v.get("actor", ""),
            "vod_director": v.get("director", ""),
            "vod_content": v.get("content", ""),
            "vod_play_from": "$$$".join(v["shows"]),
            "vod_play_url": "$$$".join(
                "#".join("{}${}".format(e[0], e[1]) for e in group)
                for group in v["urls"]
            ),
        }

    def _to_vod(self, source):
        return {
            "vod_id": self._source_id(source),
            "vod_name": source["name"],
            "vod_pic": "",
            "vod_remarks": source["relative"] + " · 点击查看路径",
        }

    def detailContent(self, array):
        with self.lock:
            if not self.inited:
                self.init("")
        source_id = str(array[0]) if isinstance(array, (list, tuple)) and array else str(array or "")
        if source_id.startswith("cd") and not source_id.startswith("cd_"):
            try:
                si, vid = source_id[2:].split("_", 1)
                remote = self._remote(int(si))
            except Exception:
                remote, vid = None, ""
            if not remote:
                return {"list": [{"vod_name": "站点不可用", "vod_content": "站点初始化失败"}]}
            vod = remote.detail(vid)
            if not vod:
                return {"list": []}
            vod["vod_id"] = source_id
            return {"list": [vod]}
        if source_id == self.WRITE_ID:
            return {"list": [{
                "vod_id": self.WRITE_ID,
                "vod_name": "一键写PY",
                "vod_pic": "",
                "vod_remarks": "点右上角操作或返回点卡片",
                "vod_content": (
                    "点「一键写PY」卡片 → 输入网站地址 → 自动生成py\n"
                    "生成目录: " + os.path.abspath(os.path.expanduser(self.scan_dir)) +
                    "\n生成后去站源管理导入 py 文件即可使用"
                ),
            }]}
        if source_id == self.RESCAN_ID:
            with self.lock:
                ok_scan = self._refresh()
            content = (
                "扫描: {scan}\n"
                "扫到: {n} 个PY源\n"
                "目录: {d}"
            ).format(
                scan="成功" if ok_scan else "失败",
                n=len(self.sources),
                d=os.path.abspath(os.path.expanduser(self.scan_dir)),
            )
            return {"list": [{
                "vod_id": self.RESCAN_ID,
                "vod_name": "扫描完成",
                "vod_pic": "",
                "vod_remarks": "成功" if ok_scan else "失败",
                "vod_content": content,
            }]}
        if source_id == self.EDIT_DIR_ID:
            return {"list": [{
                "vod_id": self.EDIT_DIR_ID,
                "vod_name": "设置目录",
                "vod_pic": "",
                "vod_remarks": "当前目录",
                "vod_content": "当前目录: " + os.path.abspath(os.path.expanduser(self.scan_dir)),
            }]}
        for source in self.sources:
            if self._source_id(source) == source_id:
                content = (
                    "名称: {name}\n"
                    "文件: {path}\n"
                    "相对路径: {relative}\n"
                    "导入方法: 在火蚁聚合的站源管理里导入 py 文件\n"
                    "文件地址: {api}"
                ).format(
                    name=source["name"],
                    path=source["path"],
                    relative=source["relative"],
                    api=self._file_url(source["path"]),
                )
                return {"list": [{
                    "vod_id": source_id,
                    "vod_name": source["name"],
                    "vod_pic": "",
                    "vod_remarks": "PY",
                    "vod_content": content,
                }]}
        return {"list": [{"vod_name": "源不存在", "vod_content": "请重新扫描"}]}

    def searchContent(self, key, quick, pg="1"):
        with self.lock:
            if not self.inited:
                self.init("")
            self._load_remotes()
        keyword = str(key or "").strip()
        try:
            page = max(1, int(pg))
        except Exception:
            page = 1
        if not keyword:
            return self._paged([], page)
        results = []
        for i, r in enumerate(self.remotes[:6]):
            if len(results) >= 60:
                break
            try:
                items = r["remote"].search(keyword, page)
            except Exception:
                items = []
            for x in items:
                x["id"] = "cd{}_{}".format(i, x["id"])
                results.append(self._vod(x))
        lower = keyword.lower()
        results.extend([
            self._to_vod(s) for s in self.sources
            if lower in s["name"].lower() or lower in s["relative"].lower()
        ])
        return {"list": results[:60], "page": page}

    def action(self, action):
        with self.lock:
            if not self.inited:
                self.init("")
        action = str(action)
        if action == self.ACTION_WRITE:
            opened, message = self._open_write_dialog()
            return {"code": 0, "msg": "" if opened else message}
        if action == self.ACTION_IMGFIX:
            msg, ok = self._toggle_img_fix()
            return {"code": 0 if ok else 1, "msg": msg}
        if action == self.ACTION_EDIT_DIR:
            opened, message = self._open_dir_browser()
            return {"code": 0, "msg": "" if opened else message}
        if action == self.ACTION_RESCAN:
            with self.lock:
                ok_scan = self._refresh()
            if ok_scan:
                return {"code": 0, "msg": "扫描完成：{} 个PY源".format(len(self.sources))}
            return {"code": 0, "msg": "扫描失败：{}".format(self.status["error"] or self.status["write_state"])}
        if action == self.ACTION_BROWSER:
            opened, message = _open_browser_dialog(self, "https://cn.bing.com/")
            return {"code": 0 if opened else 1, "msg": "" if opened else message}
        if action == self.ACTION_SHELL_TOOL:
            opened, message = _open_system_browser(self.SHELL_TOOL_URL)
            if not opened:
                opened, message = _shell_browser_open(self, self.SHELL_TOOL_URL)
            return {"code": 0 if opened else 1, "msg": "" if opened else message}
        if action == self.ACTION_MUSIC:
            opened, message = _open_browser_dialog(self, self.MUSIC_URL)
            return {"code": 0 if opened else 1, "msg": "" if opened else message}
        if action.startswith("onekey_generate"):
            payload = action[len("onekey_generate"):].strip()
            try:
                req = json.loads(payload) if payload else {}
            except Exception:
                req = {}
            if not isinstance(req, dict):
                req = {}
            result = self._generate_code(
                req.get("url") or "",
                req.get("name") or "",
                req.get("hint") or "",
            )
            if not result.get("ok"):
                return {"code": 1, "ok": False, "msg": result.get("error") or "生成失败"}
            return {
                "code": 0,
                "ok": True,
                "name": result["name"],
                "source": result["source"],
                "mode": result["mode"],
                "template_id": result["template_id"],
                "api": result["api"],
                "bases": result["bases"],
            }
        return {"code": 0, "msg": "未知操作"}

    def playerContent(self, flag, id, vipFlags):
        if self.cur_remote is not None:
            try:
                return self.cur_remote.play(flag, str(id))
            except Exception:
                pass
        return {"parse": 0, "url": "", "header": {}, "msg": "这是扫描管理条目"}

    def localProxy(self, param):
        return _proxy_fetch(param)

    def isVideoFormat(self, url):
        return False

    def manualVideoCheck(self):
        return False

_BROWSER_ID = "__py_browser__"
_SHELL_HOME = "https://56.al/"
_SHELL_UPLOAD_URL = "https://56.al/upload.php"

_SHELL_INJECT_JS = (
    "(function(){"
    "if(window.__pyShellOn) return 'on'; window.__pyShellOn=1;"
    "document.addEventListener('click', function(e){"
    " try{"
    "  var el=e.target; if(!el||!el.closest) return;"
    "  var box=el.closest('a,button,input,[onclick],[data-href],[data-url]')||el;"
    "  var href=(box.getAttribute&&(box.getAttribute('href')||box.getAttribute('data-href')||box.getAttribute('data-url')))||'';"
    "  var oc=(box.getAttribute&&box.getAttribute('onclick'))||'';"
    "  var txt=(el.textContent||'')+(box.textContent||'');"
    "  var hit=/upload|shangchuan/i.test(href+oc)||/上\\s*传|上传文件|选择文件|脱壳/.test(txt);"
    "  if(hit){"
    "   e.preventDefault(); e.stopPropagation();"
    "   window.__pyJump=/^https?:\\/\\//i.test(href)?href:'FORCE';"
    "  }"
    " }catch(err){}"
    "}, true);"
    "return 'injected';"
    "})()"
)

_SHELL_POLL_JS = "(window.__pyJump||'')"
_browser_holder = {}
_UPLOAD_WATCH_STARTED = [False]


def _browser_normalize_url(text):
    u = str(text or "").strip()
    if not u:
        return ""
    if "://" not in u:
        u = "https://" + u
    return u


def _open_system_browser(url):
    try:
        from java import jclass
        activity = _current_activity()
        if activity is None:
            return False, "拿不到 Activity"
        Intent = jclass("android.content.Intent")
        Uri = jclass("android.net.Uri")
        it = Intent("android.intent.action.VIEW", Uri.parse(str(url)))
        it.addFlags(0x10000000)
        activity.startActivity(it)
        return True, ""
    except Exception as exc:
        return False, str(exc)


def _shell_js_clear(web):
    try:
        web.evaluateJavascript("window.__pyJump=null;", None)
    except Exception:
        pass


def _open_browser_dialog(self, start_url=""):
    try:
        from java import dynamic_proxy, jclass

        activity_probe = _current_activity()
        if not activity_probe:
            return False, "取不到 Activity"
        result_holder = {"ok": False, "msg": ""}

        class RunBuild(dynamic_proxy(jclass("java.lang.Runnable"))):
            def run(self):
                try:
                    ok, msg = _browser_build_ui(self, activity_probe, start_url)
                except Exception as exc:
                    ok, msg = False, "浏览器构建异常: {}".format(exc)
                result_holder["ok"] = ok
                result_holder["msg"] = msg
                if not ok:
                    _toast(activity_probe, "浏览器打开失败: " + str(msg))

        activity_probe.runOnUiThread(RunBuild())
        for _ in range(200):
            if result_holder["ok"] or result_holder["msg"]:
                break
            time.sleep(0.05)
        return result_holder["ok"], result_holder["msg"]
    except Exception as exc:
        return False, "打不开浏览器: {}".format(exc)


def _browser_build_ui(self, activity, start_url):
    try:
        from java import dynamic_proxy, jclass

        toast_class = jclass("android.widget.Toast")
        click_listener = jclass("android.view.View$OnClickListener")
        webview_class = jclass("android.webkit.WebView")
        linear_layout_class = jclass("android.widget.LinearLayout")
        edit_text_class = jclass("android.widget.EditText")
        button_class = jclass("android.widget.Button")
        lp_class = jclass("android.widget.LinearLayout$LayoutParams")
        clip_class = jclass("android.content.ClipData")
        ctx_clip = jclass("android.content.Context")
        try:
            builder_class = jclass(
                "com.google.android.material.dialog.MaterialAlertDialogBuilder"
            )
        except Exception:
            builder_class = jclass("android.app.AlertDialog$Builder")

        def toast(msg):
            _toast(activity, msg)

        root = linear_layout_class(activity)
        root.setOrientation(linear_layout_class.VERTICAL)

        row = linear_layout_class(activity)
        row.setOrientation(linear_layout_class.HORIZONTAL)
        edit = edit_text_class(activity)
        edit.setSingleLine(True)
        edit.setHint("输入网址，如 www.555yy3.com")
        if start_url:
            edit.setText(_browser_normalize_url(start_url))
        row.addView(edit, lp_class(-1, -2, 1.0))
        go_btn = button_class(activity)
        go_btn.setText("前往")
        row.addView(go_btn, lp_class(-2, -2))
        root.addView(row, lp_class(-1, -2))

        web = webview_class(activity)
        try:
            s = web.getSettings()
            s.setJavaScriptEnabled(True)
            s.setDomStorageEnabled(True)
            s.setLoadWithOverviewMode(True)
            s.setUseWideViewPort(True)
            s.setSupportZoom(True)
            s.setBuiltInZoomControls(True)
            s.setDisplayZoomControls(False)
            try:
                s.setMixedContentMode(0)
            except Exception:
                pass
            try:
                s.setMediaPlaybackRequiresUserGesture(False)
            except Exception:
                pass
            s.setUserAgentString(
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
                " (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36")
        except Exception:
            pass
        try:
            web.setBackgroundColor(-1)
        except Exception:
            pass
        WebViewClientBase = jclass("android.webkit.WebViewClient")
        WebChromeClientBase = jclass("android.webkit.WebChromeClient")
        web.setWebViewClient(WebViewClientBase())
        web.setWebChromeClient(WebChromeClientBase())
        root.addView(web, lp_class(-1, -1, 1.0))

        row2 = linear_layout_class(activity)
        row2.setOrientation(linear_layout_class.HORIZONTAL)

        def mkbtn(text):
            b = button_class(activity)
            b.setText(text)
            row2.addView(b, lp_class(-1, -2, 1.0))
            return b

        refresh_b = mkbtn("刷新")
        back_b = mkbtn("返回")
        cookie_b = mkbtn("复制Cookie")
        close_b = mkbtn("关闭")
        root.addView(row2, lp_class(-1, -2))

        holder = {"web": web, "edit": edit, "dialog": None}
        _browser_holder["cur"] = holder

        runnable_class = jclass("java.lang.Runnable")

        class GoRunI(dynamic_proxy(runnable_class)):
            def run(self):
                u = _browser_normalize_url(str(edit.getText()))
                if not u:
                    toast("请输入网址")
                    return
                try:
                    web.loadUrl(u)
                except Exception as exc:
                    toast("加载失败: " + str(exc))

        class GoClick(dynamic_proxy(click_listener)):
            def onClick(self, v):
                activity.runOnUiThread(GoRunI())

        class RefreshClick(dynamic_proxy(click_listener)):
            def onClick(self, v):
                activity.runOnUiThread(GoRunI())

        class BackRun(dynamic_proxy(runnable_class)):
            def run(self):
                try:
                    if web.canGoBack():
                        web.goBack()
                    else:
                        d = holder.get("dialog")
                        if d:
                            d.dismiss()
                except Exception:
                    pass

        class BackClick(dynamic_proxy(click_listener)):
            def onClick(self, v):
                activity.runOnUiThread(BackRun())

        class CookieRun(dynamic_proxy(runnable_class)):
            def run(self):
                try:
                    cm = jclass("android.webkit.CookieManager").getInstance()
                    try:
                        u = str(web.getUrl())
                    except Exception:
                        u = _browser_normalize_url(str(edit.getText()))
                    ck = str(cm.getCookie(u) or "")
                    if not ck:
                        toast("当前站点没有Cookie")
                        return
                    cd = clip_class.newClipData("cookies", ck)
                    cb = activity.getSystemService(ctx_clip.CLIPBOARD_SERVICE)
                    cb.setPrimaryClip(cd)
                    toast("Cookie已复制（{}字符）".format(len(ck)))
                except Exception as exc:
                    toast("复制失败: " + str(exc))

        class CookieClick(dynamic_proxy(click_listener)):
            def onClick(self, v):
                activity.runOnUiThread(CookieRun())

        class CloseClick(dynamic_proxy(click_listener)):
            def onClick(self, v):
                try:
                    d = holder.get("dialog")
                    if d:
                        d.dismiss()
                except Exception:
                    pass

        go_btn.setOnClickListener(GoClick())
        refresh_b.setOnClickListener(RefreshClick())
        back_b.setOnClickListener(BackClick())
        cookie_b.setOnClickListener(CookieClick())
        close_b.setOnClickListener(CloseClick())

        dialog_class = jclass("android.app.Dialog")
        r_style = jclass("android.R$style")
        dialog = dialog_class(activity, r_style.Theme_Black_NoTitleBar_Fullscreen)
        holder["dialog"] = dialog
        dialog.setContentView(root)
        dialog.show()
        try:
            win = dialog.getWindow()
            win.setLayout(-1, -1)
            win.setWindowAnimations(-1)
        except Exception:
            pass

        if start_url:
            try:
                web.loadUrl(_browser_normalize_url(start_url))
            except Exception:
                pass
        try:
            _start_upload_watcher(activity)
        except Exception:
            pass
        return True, ""
    except Exception as exc:
        return False, "打不开浏览器: {}".format(exc)


def _start_upload_watcher(activity):
    if _UPLOAD_WATCH_STARTED[0]:
        return
    _UPLOAD_WATCH_STARTED[0] = True

    def watch_loop():
        time.sleep(1.5)
        from java import dynamic_proxy, jclass
        runnable_class = jclass("java.lang.Runnable")
        value_cb_class = jclass("android.webkit.ValueCallback")

        class WInjectRun(dynamic_proxy(runnable_class)):
            def run(self):
                cur = _browser_holder.get("cur") or {}
                web = cur.get("web")
                if web:
                    try:
                        web.evaluateJavascript(_SHELL_INJECT_JS, None)
                    except Exception:
                        pass

        class WPollValueCB(dynamic_proxy(value_cb_class)):
            def onReceiveValue(self, value):
                try:
                    txt = str(value or "").strip().strip('"')
                    if txt and txt != "null":
                        _browser_holder["jump"] = txt
                except Exception:
                    pass

        class WPollRun(dynamic_proxy(runnable_class)):
            def run(self):
                cur = _browser_holder.get("cur") or {}
                web = cur.get("web")
                if web:
                    try:
                        web.evaluateJavascript(_SHELL_POLL_JS, WPollValueCB())
                    except Exception:
                        pass

        class WClearRun(dynamic_proxy(runnable_class)):
            def run(self):
                cur = _browser_holder.get("cur") or {}
                web = cur.get("web")
                if web:
                    try:
                        web.evaluateJavascript("window.__pyJump=null;", None)
                    except Exception:
                        pass

        while True:
            try:
                cur = _browser_holder.get("cur")
                if not cur:
                    time.sleep(1.0)
                    continue
                dialog = cur.get("dialog")
                showing = False
                try:
                    showing = bool(dialog and dialog.isShowing())
                except Exception:
                    showing = False
                activity.runOnUiThread(WInjectRun())
                time.sleep(0.2)
                activity.runOnUiThread(WPollRun())
                time.sleep(0.4)
                j = _browser_holder.get("jump")
                if j:
                    _browser_holder["jump"] = ""
                    activity.runOnUiThread(WClearRun())
                    target = _SHELL_UPLOAD_URL if j == "FORCE" else j
                    if showing:
                        ok, msg = _open_system_browser(target)
                        if not ok:
                            _toast(activity, "跳转失败: " + str(msg))
            except Exception:
                time.sleep(1.0)

    threading.Thread(target=watch_loop, daemon=True).start()


def _shell_browser_open(self, start_url=""):
    try:
        from java import dynamic_proxy, jclass

        activity = _current_activity()
        if not activity:
            return False, "取不到 Activity"
        holder = {"jump": "", "dialog": None, "web": None}
        result_holder = {"ok": False, "msg": ""}

        class RunBuild(dynamic_proxy(jclass("java.lang.Runnable"))):
            def run(self):
                try:
                    toast_class = jclass("android.widget.Toast")
                    click_listener = jclass("android.view.View$OnClickListener")
                    runnable_class = jclass("java.lang.Runnable")
                    webview_class = jclass("android.webkit.WebView")
                    linear_layout_class = jclass("android.widget.LinearLayout")
                    button_class = jclass("android.widget.Button")
                    lp_class = jclass("android.widget.LinearLayout$LayoutParams")
                    clip_class = jclass("android.content.ClipData")
                    ctx_clip = jclass("android.content.Context")
                    WebViewClientBase = jclass("android.webkit.WebViewClient")
                    WebChromeClientBase = jclass("android.webkit.WebChromeClient")

                    def toast(msg):
                        _toast(activity, msg)

                    root = linear_layout_class(activity)
                    root.setOrientation(linear_layout_class.VERTICAL)

                    web = webview_class(activity)
                    try:
                        s = web.getSettings()
                        s.setJavaScriptEnabled(True)
                        s.setDomStorageEnabled(True)
                        s.setLoadWithOverviewMode(True)
                        s.setUseWideViewPort(True)
                        s.setSupportZoom(True)
                        s.setBuiltInZoomControls(True)
                        s.setDisplayZoomControls(False)
                        try:
                            s.setMixedContentMode(0)
                        except Exception:
                            pass
                        try:
                            s.setMediaPlaybackRequiresUserGesture(False)
                        except Exception:
                            pass
                        s.setUserAgentString(
                            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
                            " (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36")
                    except Exception:
                        pass
                    try:
                        web.setBackgroundColor(-1)
                    except Exception:
                        pass
                    web.setWebViewClient(WebViewClientBase())
                    web.setWebChromeClient(WebChromeClientBase())
                    root.addView(web, lp_class(-1, -1, 1.0))

                    row = linear_layout_class(activity)
                    row.setOrientation(linear_layout_class.HORIZONTAL)

                    def mkbtn(text):
                        b = button_class(activity)
                        b.setText(text)
                        row.addView(b, lp_class(-1, -2, 1.0))
                        return b

                    refresh_b = mkbtn("刷新")
                    back_b = mkbtn("返回")
                    cookie_b = mkbtn("复制Cookie")
                    close_b = mkbtn("关闭")
                    root.addView(row, lp_class(-1, -2))

                    holder["web"] = web

                    def go_home(_v=None):
                        try:
                            web.loadUrl(_SHELL_HOME)
                        except Exception as exc:
                            toast("加载失败: " + str(exc))

                    class RefreshClick(dynamic_proxy(click_listener)):
                        def onClick(self, v):
                            activity.runOnUiThread(go_home)

                    class BackRun(dynamic_proxy(runnable_class)):
                        def run(self):
                            try:
                                if web.canGoBack():
                                    web.goBack()
                                else:
                                    d = holder.get("dialog")
                                    if d:
                                        d.dismiss()
                            except Exception:
                                pass

                    class BackClick(dynamic_proxy(click_listener)):
                        def onClick(self, v):
                            activity.runOnUiThread(BackRun())

                    class CookieRun(dynamic_proxy(runnable_class)):
                        def run(self):
                            try:
                                cm = jclass("android.webkit.CookieManager").getInstance()
                                u = str(web.getUrl() or _SHELL_HOME)
                                ck = str(cm.getCookie(u) or "")
                                if not ck:
                                    toast("当前站点没有Cookie")
                                    return
                                cd = clip_class.newClipData("cookies", ck)
                                cb = activity.getSystemService(ctx_clip.CLIPBOARD_SERVICE)
                                cb.setPrimaryClip(cd)
                                toast("Cookie已复制（{}字符）".format(len(ck)))
                            except Exception as exc:
                                toast("复制失败: " + str(exc))

                    class CookieClick(dynamic_proxy(click_listener)):
                        def onClick(self, v):
                            activity.runOnUiThread(CookieRun())

                    class CloseClick(dynamic_proxy(click_listener)):
                        def onClick(self, v):
                            try:
                                d = holder.get("dialog")
                                if d:
                                    d.dismiss()
                            except Exception:
                                pass

                    refresh_b.setOnClickListener(RefreshClick())
                    back_b.setOnClickListener(BackClick())
                    cookie_b.setOnClickListener(CookieClick())
                    close_b.setOnClickListener(CloseClick())

                    dialog_class = jclass("android.app.Dialog")
                    r_style = jclass("android.R$style")
                    dialog = dialog_class(activity, r_style.Theme_Black_NoTitleBar_Fullscreen)
                    holder["dialog"] = dialog
                    dialog.setContentView(root)
                    dialog.show()
                    try:
                        win = dialog.getWindow()
                        win.setLayout(-1, -1)
                        win.setWindowAnimations(-1)
                    except Exception:
                        pass
                    try:
                        web.loadUrl(_browser_normalize_url(start_url or _SHELL_HOME))
                    except Exception:
                        pass
                    result_holder["ok"] = True
                except Exception as exc:
                    result_holder["ok"] = False
                    result_holder["msg"] = "脱壳浏览器构建异常: {}".format(exc)
                    _toast(activity, str(result_holder["msg"]))

        activity.runOnUiThread(RunBuild())
        for _ in range(200):
            if result_holder["ok"] or result_holder["msg"]:
                break
            time.sleep(0.05)
        if not result_holder["ok"]:
            return False, result_holder["msg"] or "构建超时"

        value_cb_class = jclass("android.webkit.ValueCallback")
        runnable_class = jclass("java.lang.Runnable")

        def on_jump(url):
            target = _SHELL_UPLOAD_URL if url == "FORCE" else url
            ok, msg = _open_system_browser(target)
            if not ok:
                opened, message = _open_browser_dialog(self, target)
                if not opened:
                    _toast(activity, "跳转失败: " + str(message))

        class PollRun(dynamic_proxy(runnable_class)):
            def run(self):
                web = holder.get("web")
                if not web:
                    return
                try:
                    web.evaluateJavascript(_SHELL_POLL_JS, PollValueCB())
                except Exception:
                    pass

        class PollValueCB(dynamic_proxy(value_cb_class)):
            def onReceiveValue(self, value):
                try:
                    txt = str(value or "").strip().strip('"')
                    if txt and txt != "null":
                        holder["jump"] = txt
                except Exception:
                    pass

        class InjectRun(dynamic_proxy(runnable_class)):
            def run(self):
                web = holder.get("web")
                if not web:
                    return
                try:
                    web.evaluateJavascript(_SHELL_INJECT_JS, None)
                except Exception:
                    pass

        def poll_loop():
            time.sleep(1.0)
            n = 0
            while True:
                try:
                    d = holder.get("dialog")
                    w = holder.get("web")
                    if not d or not w:
                        try:
                            if d and not d.isShowing():
                                return
                        except Exception:
                            return
                    activity.runOnUiThread(InjectRun())
                    time.sleep(0.15)
                    activity.runOnUiThread(PollRun())
                    time.sleep(0.35)
                    j = holder.get("jump")
                    if j:
                        holder["jump"] = ""
                        activity.runOnUiThread(_ClearJumpRun())
                        try:
                            on_jump(j)
                        except Exception:
                            pass
                    n += 1
                except Exception:
                    time.sleep(1.0)

        class _ClearJumpRun(dynamic_proxy(runnable_class)):
            def run(self):
                _shell_js_clear(holder.get("web"))

        threading.Thread(target=poll_loop, daemon=True).start()
        return True, ""
    except Exception as exc:
        return False, "脱壳浏览器打不开: {}".format(exc)
