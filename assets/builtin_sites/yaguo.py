import gzip
import json
import ssl
import time
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

BASE_URL = 'https://app.whjzjx.cn'
LOGIN_URL = 'https://u.shytkjgs.com/user/v1/account/login'
DEVICE = '24250683a3bdb3f118dff25ba4b1cba1a'
VERSION_NAME = '3.8.3.1'
TOKEN_TTL = 6 * 3600
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

try:
    import requests
    _HAS_REQ = True
except Exception:
    _HAS_REQ = False

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

_TOKEN_CACHE = {'token': '', 'expires': 0}


def _http_json(url, headers=None, data=None, timeout=25):
    hdr = {'User-Agent': UA, 'Accept': 'application/json, */*', 'Accept-Encoding': 'gzip, deflate'}
    if headers:
        hdr.update(headers)
    body = None
    if data is not None:
        body = json.dumps(data).encode('utf-8')
        hdr['Content-Type'] = 'application/json'
    if _HAS_REQ:
        try:
            if body is not None:
                r = requests.post(url, headers=hdr, data=body, timeout=timeout)
            else:
                r = requests.get(url, headers=hdr, timeout=timeout)
            if r.status_code == 200 and r.text:
                obj = json.loads(r.text)
                if isinstance(obj, dict):
                    return obj
        except Exception:
            pass
    for attempt in range(3):
        try:
            req = urllib.request.Request(url, data=body, headers=hdr, method='POST' if body is not None else 'GET')
            with urllib.request.urlopen(req, timeout=timeout, context=CTX) as resp:
                raw = resp.read()
                enc = (resp.headers.get('Content-Encoding') or '').lower()
            if enc == 'gzip' or raw[:2] == b'\x1f\x8b':
                try:
                    raw = gzip.decompress(raw)
                except Exception:
                    pass
            obj = json.loads(raw.decode('utf-8', 'replace'))
            if isinstance(obj, dict):
                return obj
            return None
        except Exception:
            if attempt < 2:
                time.sleep(1)
    return None


def _txt(v):
    if v is None:
        return ''
    if isinstance(v, str):
        return v.strip()
    return str(v).strip()


def _int(v):
    try:
        return int(v)
    except Exception:
        try:
            return int(float(v))
        except Exception:
            return 0


def _first_text(obj, keys):
    if not isinstance(obj, dict):
        return ''
    for k in keys:
        v = obj.get(k)
        if isinstance(v, str) and v.strip():
            return v.strip()
        if isinstance(v, (int, float)):
            return str(v)
    return ''


def _extract_token(body):
    token = _first_text(body, ['token', 'access_token', 'accessToken'])
    if token:
        return token
    data = body.get('data') if isinstance(body, dict) else None
    return _first_text(data, ['token', 'access_token', 'accessToken'])


def _token():
    now = time.time()
    if _TOKEN_CACHE['token'] and now < _TOKEN_CACHE['expires']:
        return _TOKEN_CACHE['token']
    body = _http_json(LOGIN_URL, headers={'platform': '1'}, data={'device': DEVICE})
    if not isinstance(body, dict):
        return ''
    token = _extract_token(body)
    if token:
        _TOKEN_CACHE['token'] = token
        _TOKEN_CACHE['expires'] = now + TOKEN_TTL
    return token


def _request(path, query=None):
    token = _token()
    if not token:
        return None
    url = BASE_URL + path
    if query:
        url += '?' + urllib.parse.urlencode(query)
    headers = {
        'Referer': BASE_URL + '/',
        'authorization': token,
        'platform': '1',
        'version_name': VERSION_NAME,
    }
    return _http_json(url, headers=headers)


def _search_request(query):
    token = _token()
    if not token:
        return None
    headers = {
        'Referer': BASE_URL + '/',
        'authorization': token,
        'platform': '1',
        'version_name': VERSION_NAME,
    }
    return _http_json(BASE_URL + '/v3/search', headers=headers, data={'text': query})


def _catalog_items(rows):
    out = []
    for entry in rows or []:
        if not isinstance(entry, dict):
            continue
        theater = entry.get('theater')
        if isinstance(theater, dict) and theater:
            target = theater
        else:
            target = entry
        vid = _first_text(target, ['id', 'theater_id', 'theater_parent_id'])
        if not vid:
            continue
        title = _first_text(target, ['title', 'name'])
        if not title:
            continue
        count = 0
        for k in ('total', 'total_num', 'current_num'):
            count = _int(target.get(k))
            if count > 0:
                break
        cover = _first_text(target, ['cover_url', 'son_cover_url', 'cover'])
        out.append({
            'vod_id': vid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_remarks': ('共%d集' % count) if count > 0 else '',
        })
    return out


def _norm_id(ids):
    if isinstance(ids, (list, tuple)):
        return str(ids[0]) if ids else ''
    return str(ids or '')


def _norm_pg(pg):
    try:
        pg = int(pg)
    except Exception:
        pg = 1
    return pg if pg >= 1 else 1


class Spider(BaseSpider):

    def getName(self):
        return '芽果'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cats(self):
        resp = _request('/cloud/v2/theater/classes')
        out = []
        seen = set()
        if isinstance(resp, dict):
            data = resp.get('data')
            if isinstance(data, list):
                for group in data:
                    if not isinstance(group, dict):
                        continue
                    classes = group.get('alg_class')
                    if not isinstance(classes, list):
                        continue
                    for entry in classes:
                        if not isinstance(entry, dict):
                            continue
                        cid = _txt(entry.get('id'))
                        name = _first_text(entry, ['class_name', 'name'])
                        if not cid or not name or len(name) > 24 or cid in seen:
                            continue
                        seen.add(cid)
                        out.append({'type_id': cid, 'type_name': name})
        if not out:
            out = [{'type_id': '1', 'type_name': '剧场'}, {'type_id': '9', 'type_name': '榜单'}]
        return out

    def homeContent(self, filter=''):
        cats = self._cats()
        items = []
        if cats:
            items = self._catalog(cats[0]['type_id'], 1)
        return {'class': cats, 'filters': {}, 'list': items}

    def homeVideoContent(self):
        items = self._catalog('1', 1)
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def _catalog(self, tid, pg):
        if tid == '9':
            resp = _request('/cloud/v1/first_level_ranking/detail', {'id': '1'})
            if isinstance(resp, dict):
                data = resp.get('data')
                if isinstance(data, dict):
                    rows = data.get('list')
                    if isinstance(rows, list):
                        return _catalog_items(rows)
            return []
        class_id = tid if tid.lstrip('-').isdigit() else ''
        resp = _request('/cloud/v2/theater/home_page', {
            'theater_class_id': class_id,
            'type': '1',
            'class2_ids': '0',
            'page_num': str(pg),
            'page_size': '24',
        })
        if isinstance(resp, dict):
            data = resp.get('data')
            if isinstance(data, dict):
                rows = data.get('list')
                if isinstance(rows, list):
                    return _catalog_items(rows)
        return []

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        items = self._catalog(_norm_id(tid), pg)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        sid = _norm_id(ids)
        if not sid:
            return {'list': []}
        resp = _request('/v2/theater_parent/detail', {'theater_parent_id': sid})
        data = None
        if isinstance(resp, dict) and isinstance(resp.get('data'), dict) and resp['data']:
            data = resp['data']
        if not data:
            return {'list': []}
        title = _first_text(data, ['title', 'share_title'])
        cover = _first_text(data, ['cover_url', 'share_cover'])
        raw_list = data.get('theaters')
        if not isinstance(raw_list, list):
            return {'list': []}
        indexed = []
        for i, entry in enumerate(raw_list):
            if not isinstance(entry, dict):
                continue
            url = _first_text(entry, ['son_video_url', 'video_url'])
            if not url:
                continue
            number = 0
            for k in ('num', 'sort'):
                number = _int(entry.get(k))
                if number > 0:
                    break
            if number <= 0:
                number = i + 1
            node_title = _first_text(entry, ['son_title', 'title'])
            ep_title = node_title if node_title else ('第%d集' % number)
            indexed.append((number, '%s$%s' % (ep_title, url)))
        if not indexed:
            return {'list': []}
        indexed.sort(key=lambda x: x[0])
        return {'list': [{
            'vod_id': sid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': '',
            'vod_year': '',
            'vod_area': '',
            'vod_content': '',
            'type_name': '',
            'vod_tag': '',
            'vod_play_from': '在线播放',
            'vod_play_url': '#'.join(e for _, e in indexed),
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        resp = _search_request(str(key or ''))
        items = []
        if isinstance(resp, dict):
            data = resp.get('data')
            rows = None
            if isinstance(data, dict):
                rows = data.get('list')
                if not isinstance(rows, list):
                    theater = data.get('theater')
                    if isinstance(theater, dict):
                        rows = theater.get('search_data')
            if isinstance(rows, list):
                items = _catalog_items(rows)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        header = {'User-Agent': UA, 'Referer': BASE_URL + '/'}
        if raw.startswith('http'):
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}

    def localProxy(self, param):
        return [404, 'text/plain', b'', {}]

    def isVideoFormat(self, url):
        u = (url or '').lower()
        return u.endswith('.m3u8') or u.endswith('.mp4') or '.m3u8?' in u or '.mp4?' in u

    def manualVideoCheck(self):
        return False

    def action(self, action, params=None):
        return None
