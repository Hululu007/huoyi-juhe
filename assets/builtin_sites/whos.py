import json
import re
import ssl
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


BASE = "https://whos.tv"
IMG_BASE = "https://v.hersav.me"
UA_DESKTOP = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)
UA_MOBILE = (
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 "
    "Mobile/15E148 Safari/604.1"
)
UA_ANDROID = (
    "Mozilla/5.0 (Linux; Android 14; PGT-AN10) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36"
)

CARD_RE = re.compile(
    r'href="/videos/([a-z0-9-]+)"[^>]*>.*?data-cover-src="([0-9a-f]+)"'
    r'[^>]*alt="([^"]*)"',
    re.S,
)
HASH_RE = re.compile(r"/images/av/([0-9a-f]{32})\.jpg")

BRANDS = [
    ("fc2ppv", "FC2"),
    ("sdam", "SDAM"),
    ("ssis", "SSIS"),
    ("ipzz", "IPZZ"),
    ("ipz", "IPZ"),
    ("ipx", "IPX"),
    ("midv", "MIDV"),
    ("mide", "MIDE"),
    ("miaa", "MIAA"),
    ("sone", "SONE"),
    ("soe", "SOE"),
    ("sir", "SIRO"),
    ("cnt", "CNT"),
    ("sta", "STARS"),
    ("prtd", "PRTD"),
    ("hntd", "HNTD"),
    ("cjvr", "CJVR"),
    ("dsvr", "DSVR"),
    ("vvvd", "VVVD"),
    ("juq", "JUQ"),
]

CATS = [
    {"type_id": "new", "type_name": "最新作品"},
    {"type_id": "rank", "type_name": "排行榜"},
] + [{"type_id": "brand:" + key, "type_name": "厂牌 · " + name} for key, name in BRANDS]

_CACHE = {}


def _ssl_ctx():
    return ssl._create_unverified_context()


def _get(url, accept="text/html", ua=UA_DESKTOP, timeout=45):
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": ua,
            "Accept": accept,
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        },
    )
    with urllib.request.urlopen(req, timeout=timeout, context=_ssl_ctx()) as resp:
        raw = resp.read()
    return raw.decode("utf-8", "replace")


def _looks_real(html):
    return (
        bool(html)
        and len(html) > 10000
        and "data-cover-src" in html
        and "Just a moment" not in html
    )


def _fetch(target):
    encoded = urllib.parse.quote(target, safe="")
    channels = [
        ("https://validator.nu/?doc=" + encoded + "&showsource=yes&out=json", True),
        (
            "https://validator.w3.org/nu/?doc="
            + encoded
            + "&showsource=yes&out=json",
            True,
        ),
        (target, False),
    ]
    uas = [UA_MOBILE, UA_ANDROID]
    for url, is_json in channels:
        for attempt in range(2):
            try:
                body = _get(
                    url,
                    accept="application/json" if is_json else "text/html",
                    ua=uas[attempt % len(uas)],
                )
                if is_json:
                    doc = json.loads(body)
                    source = doc.get("source") or {}
                    body = source.get("code") or ""
                if _looks_real(body):
                    return body
            except Exception:
                pass
    return ""


def _decode_cover(cipher):
    cipher = (cipher or "").strip().lower()
    if len(cipher) < 4 or len(cipher) % 2:
        return None, None
    try:
        raw = bytes.fromhex(cipher)
    except Exception:
        return None, None
    key = raw[-1]
    plain = bytes(b ^ key for b in raw[:-1]).decode("utf-8", "replace")
    match = HASH_RE.search(plain)
    if not match:
        return None, None
    return plain, match.group(1)


def _cards(html):
    items = []
    for code, cipher, alt in CARD_RE.findall(html or ""):
        pic, digest = _decode_cover(cipher)
        if not digest:
            continue
        title = (alt or "").strip()
        _CACHE[code] = {
            "title": title,
            "pic": pic or "",
            "m3u8": IMG_BASE + "/" + digest + "/" + digest + ".m3u8",
        }
        items.append(
            {
                "vod_id": code,
                "vod_name": title,
                "vod_pic": pic or "",
                "vod_remarks": "高清",
                "vod_play_from": "whos",
                "vod_play_url": "正片$" + _CACHE[code]["m3u8"],
            }
        )
    return items


def _videos_url(keyword, pg):
    pg = int(pg or 1)
    if pg < 1:
        pg = 1
    query = ("?q=" + urllib.parse.quote(keyword, safe="")) if keyword else ""
    if pg <= 1:
        return BASE + "/videos" + query
    return BASE + "/videos/page-" + str(pg) + query


def _page_url(tid, pg):
    tid = str(tid or "").strip()
    if tid == "rank":
        return BASE + "/ranking/video"
    keyword = tid[len("brand:"):].strip() if tid.startswith("brand:") else ""
    return _videos_url(keyword, pg)


class Spider(BaseSpider):
    def getName(self):
        return "whos"

    def getDependence(self):
        return []

    def init(self, extend=""):
        return

    def destroy(self):
        return

    def homeContent(self, filter=""):
        html = _fetch(BASE + "/videos")
        return {"class": CATS, "list": _cards(html)}

    def homeVideoContent(self):
        html = _fetch(BASE + "/videos")
        items = _cards(html)
        return {"list": items, "page": 1, "pagecount": 9999, "total": len(items)}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        try:
            pg = int(pg or 1)
        except Exception:
            pg = 1
        url = _page_url(tid, pg)
        html = _fetch(url)
        items = _cards(html)
        single_page = str(tid or "").strip() == "rank"
        return {
            "list": items,
            "page": pg,
            "pagecount": pg if single_page or not items else 9999,
            "total": len(items),
        }

    def detailContent(self, ids):
        code = str(ids[0] if isinstance(ids, (list, tuple)) else ids)
        code = code.strip()
        if code.startswith("whos:"):
            code = code[5:]
        if not code:
            return {"list": []}
        cached = _CACHE.get(code) or {}
        title = cached.get("title") or code
        pic = cached.get("pic") or ""
        m3u8 = cached.get("m3u8") or ""
        if not m3u8:
            html = _fetch(BASE + "/videos/" + code)
            for card in _cards(html):
                if card.get("vod_id") == code:
                    m3u8 = (card.get("vod_play_url") or "").split("$", 1)[-1]
                    title = card.get("vod_name") or title
                    pic = card.get("vod_pic") or pic
                    break
        if not m3u8:
            return {"list": []}
        play_url = "正片$" + m3u8
        return {
            "list": [
                {
                    "vod_id": code,
                    "vod_name": title,
                    "vod_pic": pic,
                    "vod_remarks": "高清",
                    "vod_content": "<p>whos · " + code + "</p>",
                    "vod_play_from": "whos",
                    "vod_play_url": play_url,
                    "stills": [],
                }
            ]
        }

    def searchContent(self, key, quick=False, pg=1):
        keyword = (key or "").strip()
        if not keyword:
            return {"list": [], "page": 1, "pagecount": 1, "total": 0}
        try:
            pg = int(pg or 1)
        except Exception:
            pg = 1
        items = _cards(_fetch(_videos_url(keyword, pg)))
        if not items and pg <= 1:
            items = _cards(_fetch(BASE + "/result?q=" + urllib.parse.quote(keyword, safe="")))
        return {
            "list": items,
            "page": pg,
            "pagecount": 9999 if items else pg,
            "total": len(items),
        }

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or "").strip()
        if raw.startswith("whos:"):
            raw = raw[5:]
        url = raw if raw.startswith("http") else (
            _CACHE.get(raw, {}).get("m3u8") or ""
        )
        if not url:
            return {"parse": 0, "playUrl": "", "url": "", "header": {}}
        return {
            "parse": 0,
            "playUrl": url,
            "url": url,
            "header": {"User-Agent": UA_DESKTOP, "Referer": BASE + "/"},
        }

    def isVideoFormat(self, url):
        return ".m3u8" in str(url or "")

    def manualVideoCheck(self):
        return False
