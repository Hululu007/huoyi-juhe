try:
    from base.spider import BaseSpider
except Exception:
    try:
        from base import BaseSpider
    except Exception:
        class BaseSpider:
            pass


import gzip
import http.client
import json
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

try:
    import requests
    _HAS_REQ = True
except Exception:
    _HAS_REQ = False


NAME = "牛牛资源"
KEY = "niuniuzy"
BASE = "https://api.niuniuzy.me"
API_JSON = "https://api.niuniuzy.me/api.php/provide/vod/at/json"
API_XML = "https://api.niuniuzy.me/api.php/provide/vod/at/xml"
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"
FALLBACK_CATS = [('1', '电影'), ('2', '电视剧'), ('3', '综艺'), ('4', '动漫'), ('6', '动作片'), ('7', '喜剧片'), ('8', '爱情片'), ('9', '科幻片'), ('10', '恐怖片'), ('11', '剧情片'), ('12', '战争片'), ('13', '国产剧'), ('14', '欧美剧'), ('15', '韩剧'), ('16', '日剧'), ('17', '港剧'), ('18', '台剧'), ('19', '泰剧'), ('20', '纪录片'), ('23', '海外剧'), ('25', '大陆综艺'), ('26', '日韩综艺'), ('27', '港台综艺'), ('28', '欧美综艺'), ('29', '国产动漫'), ('30', '日韩动漫'), ('31', '欧美动漫'), ('39', '动画片'), ('44', '港台动漫'), ('45', '海外动漫'), ('47', '演唱会'), ('48', '体育赛事'), ('49', '篮球'), ('50', '足球'), ('51', '预告片'), ('52', '斯诺克'), ('53', '影视解说'), ('54', '爽文短剧'), ('55', '伦理'), ('56', '港台三级'), ('57', '韩国伦理'), ('58', '西方伦理'), ('59', '日本伦理'), ('60', '两性课堂'), ('61', '写真热舞'), ('62', '4K电影'), ('63', '有声动漫'), ('64', '女频恋爱'), ('65', '反转爽剧'), ('66', '古装仙侠'), ('67', '年代穿越'), ('68', '脑洞悬疑'), ('69', '现代都市'), ('70', '邵氏电影'), ('71', 'Netflix电影'), ('72', 'Netflix自制剧'), ('73', '擦边短剧'), ('74', '科普学习'), ('75', '漫剧')]
EXCLUDED_IDS = []
DROP_WORDS = ("游戏", "棋牌", "博彩", "彩票", "赌")


def _ctx():
    return ssl._create_unverified_context()


def _http_get(url, referer="", timeout=20):
    headers = {
        "User-Agent": UA,
        "Accept": "application/json,text/xml,text/html,*/*",
        "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        "Referer": referer or BASE + "/",
    }
    for attempt in range(3):
        if _HAS_REQ:
            try:
                resp = requests.get(url, headers=headers, timeout=timeout, verify=False)
                if resp.status_code in (200, 206):
                    resp.encoding = resp.apparent_encoding or "utf-8"
                    return resp.text
            except Exception:
                pass
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=timeout, context=_ctx()) as resp:
                raw = b""
                while True:
                    try:
                        chunk = resp.read(65536)
                    except http.client.IncompleteRead as e:
                        raw += e.partial or b""
                        break
                    if not chunk:
                        break
                    raw += chunk
                if raw[:2] == b"\x1f\x8b":
                    raw = gzip.decompress(raw)
                enc = resp.headers.get_content_charset() or "utf-8"
                return raw.decode(enc, errors="replace")
        except urllib.error.HTTPError as e:
            try:
                raw = e.read()
                if raw[:2] == b"\x1f\x8b":
                    raw = gzip.decompress(raw)
                return raw.decode("utf-8", errors="replace")
            except Exception:
                return ""
        except Exception:
            if attempt < 2:
                time.sleep(0.5)
    return ""


def _text(node, tag):
    child = node.find(tag)
    if child is None:
        return ""
    return (child.text or "").strip()


def _norm_json_record(item):
    return {
        "vod_id": str(item.get("vod_id") or "").strip(),
        "vod_name": str(item.get("vod_name") or "").strip(),
        "vod_pic": str(item.get("vod_pic") or "").strip(),
        "vod_remarks": str(item.get("vod_remarks") or "").strip(),
        "type_id": str(item.get("type_id") or "").strip(),
        "type_name": str(item.get("type_name") or "").strip(),
        "vod_actor": str(item.get("vod_actor") or "").strip(),
        "vod_director": str(item.get("vod_director") or "").strip(),
        "vod_year": str(item.get("vod_year") or "").strip(),
        "vod_area": str(item.get("vod_area") or "").strip(),
        "vod_content": str(item.get("vod_content") or item.get("vod_blurb") or "").strip(),
        "vod_class": str(item.get("vod_class") or "").strip(),
        "vod_play_from": str(item.get("vod_play_from") or "").strip(),
        "vod_play_url": str(item.get("vod_play_url") or "").strip(),
    }


def _norm_xml_record(node):
    play_from = []
    play_url = []
    dl = node.find("dl")
    if dl is not None:
        for dd in dl.findall("dd"):
            play_from.append((dd.get("flag") or "").strip())
            play_url.append((dd.text or "").strip())
    return {
        "vod_id": _text(node, "id"),
        "vod_name": _text(node, "name"),
        "vod_pic": _text(node, "pic"),
        "vod_remarks": _text(node, "note") or _text(node, "state"),
        "type_id": _text(node, "tid"),
        "type_name": _text(node, "type"),
        "vod_actor": _text(node, "actor"),
        "vod_director": _text(node, "director"),
        "vod_year": _text(node, "year"),
        "vod_area": _text(node, "area"),
        "vod_content": _text(node, "des"),
        "vod_class": _text(node, "type"),
        "vod_play_from": "$$$".join(play_from),
        "vod_play_url": "$$$".join(play_url),
    }


def _parse_json(text):
    try:
        data = json.loads(text)
    except Exception:
        return None
    if not isinstance(data, dict) or "list" not in data:
        return None
    records = [_norm_json_record(item) for item in (data.get("list") or []) if isinstance(item, dict)]
    cats = []
    for item in (data.get("class") or []):
        if isinstance(item, dict):
            tid = str(item.get("type_id") or "").strip()
            name = str(item.get("type_name") or "").strip()
            if tid and name:
                cats.append((tid, name))
    try:
        pagecount = int(data.get("pagecount") or 0)
    except Exception:
        pagecount = 0
    try:
        total = int(data.get("total") or 0)
    except Exception:
        total = 0
    try:
        page = int(data.get("page") or 1)
    except Exception:
        page = 1
    return {"list": records, "class": cats, "page": page, "pagecount": pagecount, "total": total}


def _parse_xml(text):
    try:
        root = ET.fromstring(text)
    except Exception:
        return None
    if root.tag != "rss":
        return None
    cats = []
    class_node = root.find("class")
    if class_node is not None:
        for ty in class_node.findall("ty"):
            tid = (ty.get("id") or "").strip()
            name = (ty.text or "").strip()
            if tid and name:
                cats.append((tid, name))
    list_node = root.find("list")
    records = []
    page = 1
    pagecount = 0
    total = 0
    if list_node is not None:
        try:
            page = int(list_node.get("page") or 1)
        except Exception:
            page = 1
        try:
            pagecount = int(list_node.get("pagecount") or 0)
        except Exception:
            pagecount = 0
        try:
            total = int(list_node.get("recordcount") or 0)
        except Exception:
            total = 0
        for node in list_node.findall("video"):
            records.append(_norm_xml_record(node))
    return {"list": records, "class": cats, "page": page, "pagecount": pagecount, "total": total}


def _fetch(params):
    qs = urllib.parse.urlencode(params)
    text = _http_get(API_JSON + "?" + qs, referer=BASE + "/")
    parsed = _parse_json(text) if text else None
    if parsed is not None and (parsed["list"] or parsed["class"]):
        return parsed
    if parsed is not None and params.get("ac") == "detail":
        return parsed
    text = _http_get(API_XML + "?" + qs, referer=BASE + "/")
    parsed = _parse_xml(text) if text else None
    if parsed is not None:
        return parsed
    return {"list": [], "class": [], "page": 1, "pagecount": 0, "total": 0}


def _keep_cat(tid, name):
    if tid in EXCLUDED_IDS:
        return False
    for word in DROP_WORDS:
        if word in name:
            return False
    return True


def _classes(live):
    out = []
    seen = set()
    for tid, name in live:
        if tid in seen:
            continue
        if not _keep_cat(tid, name):
            continue
        seen.add(tid)
        out.append((tid, name))
    if out:
        return out
    for tid, name in FALLBACK_CATS:
        if tid in seen:
            continue
        if not _keep_cat(tid, name):
            continue
        seen.add(tid)
        out.append((tid, name))
    return out


def _enrich(records):
    need = [r for r in records if r.get("vod_id") and not r.get("vod_pic")]
    if not need:
        return records
    ids = ",".join([r["vod_id"] for r in need])
    data = _fetch({"ac": "detail", "ids": ids})
    by_id = {}
    for item in data.get("list") or []:
        if item.get("vod_id"):
            by_id[item["vod_id"]] = item
    for record in records:
        extra = by_id.get(record.get("vod_id") or "")
        if extra:
            if not record.get("vod_pic") and extra.get("vod_pic"):
                record["vod_pic"] = extra["vod_pic"]
            if not record.get("vod_remarks") and extra.get("vod_remarks"):
                record["vod_remarks"] = extra["vod_remarks"]
    return records


def _card(record):
    vid = str(record.get("vod_id") or "").strip()
    name = str(record.get("vod_name") or "").strip()
    if not vid or not name:
        return None
    return {
        "vod_id": vid,
        "vod_name": name,
        "vod_pic": str(record.get("vod_pic") or "").strip(),
        "vod_remarks": str(record.get("vod_remarks") or "").strip(),
    }


def _cards(records):
    out = []
    for record in records:
        card = _card(record)
        if card:
            out.append(card)
    return out


def _norm_id(ids):
    if isinstance(ids, (list, tuple)):
        return str(ids[0]) if ids else ""
    return str(ids or "").strip()


def _norm_pg(pg):
    try:
        return max(1, int(pg))
    except Exception:
        return 1


class Spider(BaseSpider):
    def getName(self):
        return NAME

    def getDependence(self):
        return []

    def init(self, extend=""):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=""):
        data = _fetch({"ac": "list", "pg": 1})
        cats = _classes(data.get("class") or [])
        records = _enrich(data.get("list") or [])
        return {
            "class": [{"type_id": tid, "type_name": name} for tid, name in cats],
            "list": _cards(records),
        }

    def homeVideoContent(self):
        data = _fetch({"ac": "list", "pg": 1})
        records = _enrich(data.get("list") or [])
        return {
            "list": _cards(records),
            "page": data.get("page") or 1,
            "pagecount": data.get("pagecount") or 0,
            "total": data.get("total") or 0,
        }

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        tid = _norm_id(tid)
        params = {"ac": "list", "pg": pg}
        if tid:
            params["t"] = tid
        data = _fetch(params)
        records = _enrich(data.get("list") or [])
        return {
            "list": _cards(records),
            "page": pg,
            "pagecount": data.get("pagecount") or 0,
            "total": data.get("total") or 0,
        }

    def detailContent(self, ids):
        vid = _norm_id(ids)
        if not vid:
            return {"list": []}
        data = _fetch({"ac": "detail", "ids": vid})
        records = data.get("list") or []
        if not records:
            return {"list": []}
        record = records[0]
        name = str(record.get("vod_name") or "").strip()
        if not name:
            return {"list": []}
        return {"list": [{
            "vod_id": vid,
            "vod_name": name,
            "vod_pic": str(record.get("vod_pic") or "").strip(),
            "vod_actor": str(record.get("vod_actor") or "").strip(),
            "vod_director": str(record.get("vod_director") or "").strip(),
            "vod_remarks": str(record.get("vod_remarks") or "").strip(),
            "vod_year": str(record.get("vod_year") or "").strip(),
            "vod_area": str(record.get("vod_area") or "").strip(),
            "vod_content": str(record.get("vod_content") or "").strip(),
            "type_name": str(record.get("type_name") or "").strip(),
            "vod_tag": str(record.get("vod_class") or "").strip(),
            "vod_play_from": str(record.get("vod_play_from") or "").strip(),
            "vod_play_url": str(record.get("vod_play_url") or "").strip(),
            "stills": [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        data = _fetch({"ac": "list", "wd": key or "", "pg": pg})
        records = _enrich(data.get("list") or [])
        return {
            "list": _cards(records),
            "page": pg,
            "pagecount": data.get("pagecount") or 0,
            "total": data.get("total") or 0,
        }

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        if "$" in raw:
            raw = raw.rsplit("$", 1)[1].strip()
        header = {"User-Agent": UA, "Referer": BASE + "/"}
        stream = raw if raw.startswith("http") else ""
        return {"parse": 0, "playUrl": stream, "url": stream, "header": header}

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
            parsed = urllib.parse.urlparse(target)
            headers = {
                "User-Agent": UA,
                "Referer": "%s://%s/" % (parsed.scheme, parsed.netloc),
            }
            if _HAS_REQ:
                try:
                    resp = requests.get(target, headers=headers, timeout=20, verify=False)
                    ctype = resp.headers.get("Content-Type") or "application/octet-stream"
                    return [resp.status_code, ctype, resp.content, {}]
                except Exception:
                    pass
            req = urllib.request.Request(target, headers=headers)
            last_err = None
            for _ in range(3):
                try:
                    with urllib.request.urlopen(req, timeout=20, context=_ctx()) as resp:
                        ctype = resp.headers.get("Content-Type") or "application/octet-stream"
                        return [resp.status, ctype, resp.read(), {}]
                except urllib.error.HTTPError as e:
                    try:
                        body = e.read()
                    except Exception:
                        body = b""
                    return [e.code, e.headers.get("Content-Type") or "text/plain", body, {}]
                except Exception as e:
                    last_err = e
                    time.sleep(0.5)
            raise last_err
        except Exception:
            return [502, "text/plain", b"proxy error", {}]

    def isVideoFormat(self, url):
        url = (url or "").lower()
        return any(k in url for k in (".m3u8", ".mp4", ".m4s", ".ts", ".flv"))

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
