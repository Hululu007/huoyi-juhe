import gzip
import json
import re
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

try:
    import requests as _requests
except Exception:
    _requests = None

BASE = 'https://aimove.click'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
PAGE_SIZE = 24

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

CACHE = {}
CATS_TTL = 3600
_GUEST_TOKEN = [None]


def _now():
    return time.time()


def _http_json(url, method='GET', token=None, timeout=25):
    hdr = {
        'User-Agent': UA,
        'Accept': 'application/json, text/plain, */*',
        'Referer': BASE + '/',
    }
    if token:
        hdr['Authorization'] = 'Bearer ' + token
    for attempt in range(3):
        text = None
        if _requests is not None:
            try:
                if method == 'POST':
                    hdr2 = dict(hdr)
                    hdr2['Content-Type'] = 'application/json'
                    resp = _requests.post(url, headers=hdr2, data='{}', timeout=timeout)
                else:
                    resp = _requests.get(url, headers=hdr, timeout=timeout)
                if resp.status_code == 200:
                    text = resp.content.decode('utf-8', 'replace')
                else:
                    text = resp.content.decode('utf-8', 'replace')
                    try:
                        data = json.loads(text)
                        msg = str(data.get('message') or '')
                        raise RuntimeError('HTTP %d %s' % (resp.status_code, msg))
                    except RuntimeError:
                        raise
                    except Exception:
                        raise RuntimeError('HTTP %d' % resp.status_code)
            except RuntimeError:
                raise
            except Exception:
                text = None
        if text is None:
            try:
                if method == 'POST':
                    hdr3 = dict(hdr)
                    hdr3['Content-Type'] = 'application/json'
                    req = urllib.request.Request(url, data=b'{}', headers=hdr3, method='POST')
                else:
                    req = urllib.request.Request(url, headers=hdr)
                with urllib.request.urlopen(req, timeout=timeout, context=CTX) as resp:
                    raw = resp.read()
                    text = raw.decode('utf-8', 'replace')
                    if resp.status != 200:
                        try:
                            data = json.loads(text)
                            msg = str(data.get('message') or '')
                            raise RuntimeError('HTTP %d %s' % (resp.status, msg))
                        except RuntimeError:
                            raise
                        except Exception:
                            raise RuntimeError('HTTP %d' % resp.status)
            except RuntimeError:
                raise
            except Exception:
                text = None
        if text is not None:
            try:
                data = json.loads(text)
            except Exception:
                raise RuntimeError('non-JSON response')
            code = data.get('code')
            if code is not None and code != 0:
                msg = str(data.get('message') or '')
                raise RuntimeError('code %s %s' % (code, msg))
            return data
        if attempt < 2:
            try:
                time.sleep(1)
            except Exception:
                pass
    raise RuntimeError('request failed')


def _get_json(url, token=None):
    return _http_json(url, method='GET', token=token)


def _post_json(url, token=None):
    return _http_json(url, method='POST', token=token)


def _guest_token():
    if _GUEST_TOKEN[0]:
        return _GUEST_TOKEN[0]
    data = _post_json(BASE + '/api/member/auto/register')
    token = str(((data.get('data') or {}).get('accessToken')) or '')
    if not token:
        raise RuntimeError('auto register returned no token')
    _GUEST_TOKEN[0] = token
    return token


def _clear_guest_token():
    _GUEST_TOKEN[0] = None


def _check_in(token):
    try:
        _post_json(BASE + '/api/member/daily-check-in', token=token)
    except Exception:
        pass


def _unlock_next(drama_id, token):
    return _post_json(BASE + '/api/member/dramas/%s/unlock' % drama_id, token=token)


def _abs_url(raw):
    u = (raw or '').strip()
    if not u:
        return ''
    if u.startswith('http://') or u.startswith('https://'):
        return u
    if u.startswith('//'):
        return 'https:' + u
    if u.startswith('/'):
        return BASE + u
    return BASE + '/' + u


def _drama_card(v):
    if not isinstance(v, dict):
        return None
    try:
        did = int(v.get('id') or 0)
    except Exception:
        return None
    if did == 0:
        return None
    title = str(v.get('title') or '').strip()
    if not title:
        return None
    cover = _abs_url(str(v.get('coverUrl') or ''))
    try:
        total = int(v.get('totalEpisodes') or 0)
    except Exception:
        total = 0
    try:
        views = int(v.get('viewCount') or 0)
    except Exception:
        views = 0
    if total > 0 and views > 0:
        remark = '%d集 · %d播放' % (total, views)
    elif total > 0:
        remark = '%d集' % total
    else:
        remark = ''
    return {
        'vod_id': str(did),
        'vod_name': title,
        'vod_pic': cover,
        'vod_remarks': remark,
    }


def _paginate(items, pg):
    if pg < 1:
        pg = 1
    start = (pg - 1) * PAGE_SIZE
    total = len(items)
    if start >= total:
        return [], pg
    return items[start:min(total, start + PAGE_SIZE)], pg


def _fetch_categories():
    v = CACHE.get('cats')
    if v and _now() - v[0] < v[2]:
        return v[1]
    cats = []
    try:
        data = _get_json(BASE + '/api/dramas/categories')
        items = (data.get('data') or []) if isinstance(data, dict) else []
        for item in items:
            if not isinstance(item, dict):
                continue
            try:
                cid = int(item.get('id') or 0)
            except Exception:
                continue
            name = str(item.get('name') or '').strip()
            if cid != 0 and name:
                cats.append((str(cid), name))
    except Exception:
        pass
    ttl = CATS_TTL
    if len(cats) <= 1:
        ttl = 300
    if len(CACHE) > 20:
        CACHE.clear()
    CACHE['cats'] = (_now(), cats, ttl)
    return cats


def _list_all():
    data = _get_json(BASE + '/api/dramas')
    items = (data.get('data') or []) if isinstance(data, dict) else []
    return items


def _fetch_detail(drama_id, token=None):
    data = _get_json(BASE + '/api/dramas/%s' % drama_id, token=token)
    if isinstance(data, dict):
        return data.get('data') or {}
    return {}


def _find_episode(detail, episode_id):
    eps = detail.get('episodes') or []
    for ep in eps:
        if not isinstance(ep, dict):
            continue
        try:
            eid = int(ep.get('id') or 0)
        except Exception:
            continue
        if str(eid) == str(episode_id):
            return ep
    return None


def _episode_title(ep):
    try:
        no = int(ep.get('episodeNo') or 0)
    except Exception:
        no = 0
    if no > 0:
        base = '第%d集' % no
    else:
        base = str(ep.get('title') or '').strip()
    locked = not bool(ep.get('isUnlocked'))
    if locked:
        try:
            cost = int(ep.get('unlockPoints') or 0)
        except Exception:
            cost = 0
        if cost > 0:
            return '%s（%d金币）' % (base, cost)
        return '%s（未解锁）' % base
    return base


def _norm_id(ids):
    if isinstance(ids, (list, tuple)):
        return str(ids[0]) if ids else ''
    return str(ids)


def _norm_pg(pg):
    try:
        return int(pg)
    except Exception:
        try:
            return int(str(pg).strip())
        except Exception:
            return 1


def _empty_detail(vod_id):
    return {'list': [{
        'vod_id': vod_id,
        'vod_name': '',
        'vod_pic': '',
        'vod_actor': '',
        'vod_director': '',
        'vod_remarks': '',
        'vod_year': '',
        'vod_area': '',
        'vod_content': '',
        'type_name': '',
        'vod_tag': '',
        'vod_play_from': '在线播放',
        'vod_play_url': '',
        'stills': [],
    }]}


class Spider(BaseSpider):

    def getName(self):
        return '新黄果短剧'

    def getDependence(self):
        return []

    def init(self, extend=None):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=False):
        cats = [{'type_id': cid, 'type_name': name}
                for cid, name in _fetch_categories()]
        return {'class': cats, 'filters': {}}

    def homeVideoContent(self):
        try:
            items = [_drama_card(v) for v in _list_all()]
            items = [c for c in items if c]
        except Exception:
            items = []
        page_items, pg = _paginate(items, 1)
        return {'list': page_items, 'page': pg, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        tid = _norm_id(tid)
        pg = _norm_pg(pg)
        if pg < 1:
            pg = 1
        try:
            if not tid or tid == 'all':
                url = BASE + '/api/dramas'
            elif tid.isdigit():
                url = BASE + '/api/dramas?categoryId=' + tid
            else:
                url = BASE + '/api/dramas'
            data = _get_json(url)
            raw = (data.get('data') or []) if isinstance(data, dict) else []
            items = [c for c in [_drama_card(v) for v in raw] if c]
        except Exception:
            items = []
        page_items, pg = _paginate(items, pg)
        return {'list': page_items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        raw = _norm_id(ids)
        nid = ''.join([ch for ch in raw if ch.isdigit()])
        if not nid:
            return _empty_detail(raw)
        try:
            data = _fetch_detail(nid)
        except Exception:
            return _empty_detail(nid)
        title = str(data.get('title') or '').strip()
        if not title:
            return _empty_detail(nid)
        cover = _abs_url(str(data.get('coverUrl') or ''))
        synopsis = str(data.get('intro') or '').strip()
        try:
            total = int(data.get('totalEpisodes') or 0)
        except Exception:
            total = 0
        try:
            views = int(data.get('viewCount') or 0)
        except Exception:
            views = 0
        if total > 0 and views > 0:
            remark = '%d集 · %d播放' % (total, views)
        elif total > 0:
            remark = '%d集' % total
        else:
            remark = ''
        plays = []
        eps = data.get('episodes') or []
        for ep in eps:
            if not isinstance(ep, dict):
                continue
            try:
                eid = int(ep.get('id') or 0)
            except Exception:
                continue
            if eid == 0:
                continue
            plays.append('%s$aimove:%s:%d' % (_episode_title(ep), nid, eid))
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': remark,
            'vod_year': '',
            'vod_area': '',
            'vod_content': synopsis,
            'type_name': '',
            'vod_tag': '',
            'vod_play_from': '在线播放',
            'vod_play_url': '#'.join(plays),
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        if pg < 1:
            pg = 1
        needle = str(key or '').strip().lower()
        try:
            raw = _list_all()
        except Exception:
            raw = []
        items = []
        for v in raw:
            if not isinstance(v, dict):
                continue
            title = str(v.get('title') or '')
            if needle and needle not in title.lower():
                continue
            card = _drama_card(v)
            if card:
                items.append(card)
        page_items, pg = _paginate(items, pg)
        return {'list': page_items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        if raw.startswith('aimove:'):
            raw = raw.split(':', 1)[1].strip()
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        if raw.startswith('http'):
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        parts = raw.split(':')
        if len(parts) != 2:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        drama_id, episode_id = parts[0].strip(), parts[1].strip()
        if not drama_id or not episode_id:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        try:
            detail = _fetch_detail(drama_id)
        except Exception:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        ep = _find_episode(detail, episode_id)
        if ep is None:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        url = _abs_url(str(ep.get('videoUrl') or ''))
        if url:
            return {'parse': 0, 'playUrl': url, 'url': url, 'header': header}
        try:
            no = int(ep.get('episodeNo') or 0)
        except Exception:
            no = 0
        bound = no if no > 0 else 1
        try:
            token = _guest_token()
        except Exception:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        _check_in(token)
        for _ in range(bound):
            try:
                _unlock_next(drama_id, token)
            except Exception as e:
                msg = str(e)
                if '401' in msg or 'token' in msg.lower():
                    _clear_guest_token()
                return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
            try:
                detail = _fetch_detail(drama_id, token=token)
            except Exception:
                return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
            ep = _find_episode(detail, episode_id)
            if ep is None:
                return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
            url = _abs_url(str(ep.get('videoUrl') or ''))
            if url:
                return {'parse': 0, 'playUrl': url, 'url': url, 'header': header}
        return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}

    def localProxy(self, param):
        return [404, 'text/plain', b'', {}]

    def isVideoFormat(self, url):
        u = str(url or '').lower().split('?')[0]
        return u.endswith(('.m3u8', '.mp4', '.mkv', '.webm', '.flv', '.ts'))

    def manualVideoCheck(self):
        return True

    def action(self, action, params=None):
        return {'code': 0, 'msg': 'ok'}
