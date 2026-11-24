try:
    from base.spider import BaseSpider
except Exception:
    try:
        from base import BaseSpider
    except Exception:
        class BaseSpider:
            pass


import gzip
import html as _html
import http.client
import json
import re
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

try:
    import requests
    _HAS_REQ = True
except Exception:
    _HAS_REQ = False


BASE = 'https://play.jinguoduanju.app'
API = BASE + '/api/v1'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
PAGE_SIZE = 24

TAGS = [
    ('1', '都市'),
    ('24', '灵异'),
    ('12', '职场'),
    ('14', '校园'),
    ('19', '奇幻'),
    ('20', '丧尸'),
    ('22', '古装'),
    ('21', '穿越'),
    ('15', 'NTR'),
    ('16', '绿帽'),
    ('13', '同事'),
    ('23', '后宫'),
    ('25', '魔改'),
]


def _salvage_list(text):
    txt = (text or '').strip()
    if not txt.startswith('['):
        return None
    idx = len(txt)
    for _ in range(8):
        idx = txt.rfind('},', 0, idx)
        if idx < 0:
            break
        try:
            val = json.loads(txt[:idx + 1] + ']')
        except Exception:
            continue
        if isinstance(val, list) and val:
            return val
    return None


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _unescape(s):
    if not s:
        return ''
    return _html.unescape(s).replace('\\/', '/').strip()


def _fix_url(raw):
    u = (raw or '').strip()
    if not u:
        return ''
    if u.startswith('//'):
        return 'https:' + u
    if u.startswith('/'):
        return BASE + u
    return u


def _norm_id(ids):
    if isinstance(ids, (list, tuple)):
        ids = ids[0] if ids else ''
    return str(ids or '').strip()


def _norm_pg(pg):
    try:
        pg = int(pg)
    except Exception:
        pg = 1
    return pg if pg >= 1 else 1


class Spider(BaseSpider):
    def __init__(self):
        self._device_id = str(uuid.uuid4())
        self._token = ''
        self._cache = {}

    def getName(self):
        return '金果短剧'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _http_json(self, method, path, body=None, retry_auth=True):
        for _ in range(3):
            if not self._token:
                self._auth()
            h = {'User-Agent': UA, 'Accept': 'application/json', 'Referer': BASE + '/'}
            if self._token:
                h['Authorization'] = 'Bearer ' + self._token
            url = API + path
            status = 0
            text = ''
            if _HAS_REQ:
                try:
                    if method == 'POST':
                        r = requests.request(method, url, headers=h, json=body, timeout=60)
                    else:
                        r = requests.request(method, url, headers=h, timeout=60)
                    status = r.status_code
                    text = r.text
                except Exception:
                    status = 0
                    text = ''
            if status == 0:
                try:
                    data = json.dumps(body).encode('utf-8') if body is not None else None
                    if data:
                        h['Content-Type'] = 'application/json'
                    h['Accept-Encoding'] = 'identity'
                    req = urllib.request.Request(url, data=data, headers=h, method=method)
                    with urllib.request.urlopen(req, timeout=60, context=_ctx()) as resp:
                        status = resp.status
                        try:
                            raw = resp.read()
                        except http.client.IncompleteRead as ie:
                            raw = ie.partial or b''
                            status = resp.status
                        enc = (resp.headers.get('Content-Encoding') or '').lower()
                        if enc == 'gzip' or raw[:2] == b'\x1f\x8b':
                            try:
                                raw = gzip.decompress(raw)
                            except Exception:
                                try:
                                    import zlib
                                    raw = zlib.decompressobj(31).decompress(raw)
                                except Exception:
                                    pass
                        text = raw.decode('utf-8', 'replace')
                except urllib.error.HTTPError as e:
                    status = e.code
                    try:
                        text = e.read().decode('utf-8', 'ignore')
                    except http.client.IncompleteRead as ie:
                        text = ie.partial.decode('utf-8', 'ignore')
                except http.client.IncompleteRead as ie:
                    status = 200
                    text = ie.partial.decode('utf-8', 'ignore')
                except Exception:
                    status = 0
                    text = ''
            if status == 401 and retry_auth:
                self._token = ''
                self._auth()
                return self._http_json(method, path, body, retry_auth=False)
            if status == 200 and text:
                try:
                    return json.loads(text)
                except Exception:
                    salv = _salvage_list(text)
                    if salv is not None:
                        return salv
            if status in (401, 403, 404):
                return None
            time.sleep(1)
        return None

    def _auth(self):
        self._token = ''
        for _ in range(2):
            h = {'User-Agent': UA, 'Accept': 'application/json', 'Referer': BASE + '/', 'Content-Type': 'application/json'}
            body = {'deviceId': 'h5:' + self._device_id}
            data = None
            if _HAS_REQ:
                try:
                    r = requests.post(API + '/auth/device', headers=h, json=body, timeout=30)
                    if r.status_code == 200:
                        d = r.json()
                        if d.get('token'):
                            self._token = d['token']
                            return True
                except Exception:
                    pass
            try:
                data = json.dumps(body).encode('utf-8')
                req = urllib.request.Request(API + '/auth/device', data=data, headers=h, method='POST')
                with urllib.request.urlopen(req, timeout=30, context=_ctx()) as resp:
                    try:
                        raw = resp.read()
                    except http.client.IncompleteRead as ie:
                        raw = ie.partial or b''
                    d = json.loads(raw.decode('utf-8', 'replace'))
                    if d.get('token'):
                        self._token = d['token']
                        return True
            except Exception:
                pass
            time.sleep(1)
        return False

    def _cats(self):
        data = self._http_json('GET', '/filter-config')
        out = []
        seen = set()
        if isinstance(data, list):
            for grp in data:
                for tag in grp.get('tags') or []:
                    tid = str(tag.get('id'))
                    name = (tag.get('name') or '').strip()
                    if not name or tid in seen:
                        continue
                    seen.add(tid)
                    out.append((tid, name))
        return out or list(TAGS)

    def _cards(self, items):
        out = []
        seen = set()
        for it in items or []:
            vid = str(it.get('id') or '').strip()
            if not vid or vid in seen:
                continue
            title = _unescape(it.get('title') or '')
            if not title:
                continue
            seen.add(vid)
            ep = it.get('episodeCount') or 0
            try:
                ep = int(ep)
            except Exception:
                ep = 0
            ftype = (it.get('filmType') or '').strip()
            remarks = ('%d集' % ep) if ep else ''
            if ftype and ftype != 'FREE':
                remarks = (remarks + '·' + ftype) if remarks else ftype
            out.append({
                'vod_id': vid,
                'vod_name': title,
                'vod_pic': _fix_url(it.get('coverUrl') or ''),
                'vod_remarks': remarks,
            })
        return out

    def _list(self, path):
        if path in self._cache:
            return self._cache[path]
        data = self._http_json('GET', path)
        items = data if isinstance(data, list) else []
        self._cache[path] = items
        return items

    def _page(self, items, pg):
        start = (pg - 1) * PAGE_SIZE
        return items[start:start + PAGE_SIZE]

    def homeContent(self, filter=''):
        cats = self._cats()
        items = self._list('/dramas?displayArea=HOME_FEED')
        page = self._page(items, 1)
        cls = [{'type_id': 'all', 'type_name': '全部'}]
        cls += [{'type_id': tid, 'type_name': name} for tid, name in cats]
        return {
            'class': cls,
            'list': self._cards(page),
        }

    def homeVideoContent(self):
        items = self._list('/dramas?displayArea=HOME_FEED')
        return {'list': self._cards(self._page(items, 1)), 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        tid = _norm_id(tid)
        if tid == 'all' or not tid:
            items = self._list('/dramas')
        else:
            items = self._list('/dramas?tags=%s' % urllib.parse.quote(tid))
        return {'list': self._cards(self._page(items, pg)), 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        nid = _norm_id(ids).strip().lstrip('/')
        if not nid:
            return {'list': []}
        data = self._http_json('GET', '/dramas/%s' % urllib.parse.quote(nid))
        if not isinstance(data, dict):
            return {'list': []}
        drama = data.get('drama') or {}
        title = _unescape(drama.get('title') or '')
        if not title:
            return {'list': []}
        tags = drama.get('tags') or []
        ep = drama.get('episodeCount') or 0
        try:
            ep = int(ep)
        except Exception:
            ep = 0
        ftype = (drama.get('filmType') or '').strip()
        remarks = ('%d集' % ep) if ep else ''
        if ftype and ftype != 'FREE':
            remarks = (remarks + '·' + ftype) if remarks else ftype
        eps = []
        seen = set()
        for e in data.get('episodes') or []:
            eid = str(e.get('id') or '').strip()
            if not eid or eid in seen:
                continue
            seen.add(eid)
            num = e.get('number')
            try:
                num = int(num)
            except Exception:
                num = len(eps) + 1
            label = (e.get('title') or '').strip() or ('第%d集' % num)
            eps.append('%s$jinguo:%s' % (label, eid))
        if not eps:
            return {'list': []}
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': _fix_url(drama.get('coverUrl') or ''),
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': remarks,
            'vod_year': '',
            'vod_area': '',
            'vod_content': _unescape(data.get('description') or ''),
            'type_name': '·'.join([str(t) for t in tags[:3]]),
            'vod_tag': '',
            'vod_play_from': '在线播放',
            'vod_play_url': '#'.join(eps),
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        items = self._list('/dramas?q=%s&sort=latest' % urllib.parse.quote(key or ''))
        return {'list': self._cards(self._page(items, pg)), 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        if raw.startswith('jinguo:'):
            raw = raw[len('jinguo:'):]
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        m3u8 = ''
        data = self._http_json('GET', '/episodes/%s/play' % urllib.parse.quote(raw))
        if isinstance(data, dict):
            allow = data.get('allowance') or {}
            if allow.get('allowed') is not False:
                m3u8 = _unescape(data.get('videoUrl') or '')
        return {'parse': 0, 'playUrl': m3u8, 'url': m3u8, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', '']

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
