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

try:
    import requests
    _HAS_REQ = True
except Exception:
    _HAS_REQ = False


API = 'https://greplhggmqxb8hcj.nvdi81ptfe3lhved.com/api'
UA = 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36'
REFERER = 'https://nvdi496899299599.cc/pages/home'
PAGE_SIZE = 20

CATEGORIES = [
    ('17', 'AI定制'),
    ('16', '国产剧情'),
    ('11', '网红模特'),
    ('10', '热门事件'),
    ('3', '国产精品'),
    ('2', '无码流出'),
    ('6', '成人动漫'),
    ('4', '欧美风情'),
    ('12', '韩国精品'),
    ('5', '独家CG'),
    ('1', '日本AV'),
    ('7', '经典三级'),
]

RANKS = [
    ('new', '最新影片', '1'),
    ('hot', '热门影片', '2'),
    ('fav', '收藏榜', '4'),
]


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _http_get(url, timeout=25):
    h = {'User-Agent': UA, 'Referer': REFERER, 'Accept': 'application/json, text/plain, */*'}
    for _ in range(3):
        if _HAS_REQ:
            try:
                r = requests.get(url, headers=h, timeout=timeout)
                if r.status_code == 200 and r.text:
                    return r.text
            except Exception:
                pass
        try:
            req = urllib.request.Request(url, headers=h)
            with urllib.request.urlopen(req, timeout=timeout, context=_ctx()) as resp:
                data = resp.read()
                enc = (resp.headers.get('Content-Encoding') or '').lower()
                if enc == 'gzip' or data[:2] == b'\x1f\x8b':
                    try:
                        data = gzip.decompress(data)
                    except Exception:
                        pass
                return data.decode('utf-8', 'replace')
        except urllib.error.HTTPError as e:
            try:
                return e.read().decode('utf-8', 'ignore')
            except http.client.IncompleteRead as ie:
                return ie.partial.decode('utf-8', 'ignore')
        except Exception:
            pass
        time.sleep(1)
    return ''


def _api_json(path):
    last = ''
    for _ in range(3):
        txt = _http_get(API + path)
        if not txt:
            time.sleep(1)
            continue
        try:
            v = json.loads(txt)
        except Exception as e:
            last = str(e)
            time.sleep(1)
            continue
        if not isinstance(v, dict):
            return v
        st = v.get('status')
        if st not in (0, 1, None):
            return v
        if st == 0:
            return v
        return v
    return {}


def _text(v, keys):
    if not isinstance(v, dict):
        return ''
    for k in keys:
        x = v.get(k)
        if x is None or isinstance(x, bool):
            continue
        s = str(x)
        if s:
            return s
    return ''


def _int(v, keys):
    s = _text(v, keys)
    try:
        return int(float(s))
    except Exception:
        return 0


def _cover_of(row):
    if not isinstance(row, dict):
        return ''
    cover = row.get('cover')
    if isinstance(cover, dict):
        t = _text(cover, ['thumbnail'])
        if t:
            return t
        return _text(cover, ['source'])
    return _text(row, ['cover', 'img'])


def _card(row):
    vid = _text(row, ['id'])
    title = _text(row, ['title'])
    cover = _cover_of(row)
    remark = _text(row, ['watched']) or _text(row, ['startdate'])
    return {
        'vod_id': vid,
        'vod_name': title,
        'vod_pic': cover,
        'vod_remarks': remark,
    }


def _folder(vid, name, cover, remark):
    return {
        'vod_id': vid,
        'vod_name': name,
        'vod_pic': cover,
        'vod_remarks': remark,
        'vod_tag': 'folder',
    }


def _data_rows(body):
    if not isinstance(body, dict):
        return []
    data = body.get('data')
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        if isinstance(data.get('list'), list):
            return data['list']
        if isinstance(data.get('videos'), list):
            return data['videos']
    return []


def _has_more(body, page, items):
    total = _int(body, ['total'])
    if total > 0:
        return page * PAGE_SIZE < total
    return len(items) >= PAGE_SIZE


def _config_categories(body):
    out = []
    if isinstance(body, dict):
        data = body.get('data')
        if isinstance(data, dict):
            arr = data.get('category')
            if isinstance(arr, list):
                for row in arr:
                    vid = _text(row, ['id'])
                    name = _text(row, ['title'])
                    if vid and name:
                        out.append((vid, name))
    return out or list(CATEGORIES)


def _config_tags(body):
    out = []
    if isinstance(body, dict):
        data = body.get('data')
        if isinstance(data, dict):
            arr = data.get('tags')
            if isinstance(arr, list):
                for row in arr:
                    vid = _text(row, ['id'])
                    name = _text(row, ['title'])
                    if vid and name:
                        out.append((vid, name))
    return out


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
    def getName(self):
        return '女帝'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cats(self):
        cats = [(i, n) for i, n, _ in RANKS]
        try:
            body = _api_json('/config.html')
            for vid, name in _config_categories(body):
                cats.append(('c' + vid, name))
        except Exception:
            for vid, name in CATEGORIES:
                cats.append(('c' + vid, name))
        cats.append(('topics', '专题'))
        cats.append(('actors', '明星'))
        cats.append(('tags', '喜好标签'))
        return cats

    def homeContent(self, filter=''):
        cats = self._cats()
        items = []
        body = _api_json('/movieList.html?type=1&pageNo=1&pageSize=%s' % PAGE_SIZE)
        items = [_card(r) for r in _data_rows(body)]
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in cats],
            'list': items,
        }

    def homeVideoContent(self):
        body = _api_json('/movieList.html?type=1&pageNo=1&pageSize=%s' % PAGE_SIZE)
        items = [_card(r) for r in _data_rows(body)]
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        rank = None
        for i, _, ty in RANKS:
            if i == tid:
                rank = ty
                break
        if rank:
            body = _api_json('/movieList.html?type=%s&pageNo=%s&pageSize=%s' % (rank, pg, PAGE_SIZE))
            items = [_card(r) for r in _data_rows(body)]
            return {'list': items, 'page': pg, 'pagecount': 0, 'total': _int(body, ['total'])}
        if tid.startswith('c') and tid[1:].isdigit():
            body = _api_json('/category.html?cat=%s&pageNo=%s&pageSize=%s' % (tid[1:], pg, PAGE_SIZE))
            items = [_card(r) for r in _data_rows(body)]
            return {'list': items, 'page': pg, 'pagecount': 0, 'total': _int(body, ['total'])}
        if tid == 'topics':
            body = _api_json('/topic.html?pageNo=%s&pageSize=%s' % (pg, PAGE_SIZE))
            items = []
            for row in _data_rows(body):
                vid = _text(row, ['id'])
                title = _text(row, ['title'])
                if not vid or not title:
                    continue
                items.append(_folder('topic:' + vid, title, _text(row, ['img']), _text(row, ['intro'])))
            return {'list': items, 'page': pg, 'pagecount': 0, 'total': _int(body, ['total'])}
        if tid.startswith('topic:'):
            body = _api_json('/topic.html?topic_id=%s&pageNo=%s&pageSize=10' % (tid[6:], pg))
            items = [_card(r) for r in _data_rows(body)]
            return {'list': items, 'page': pg, 'pagecount': 0, 'total': _int(body, ['total'])}
        if tid == 'actors':
            body = _api_json('/actor.html?pageNo=%s&pageSize=%s' % (pg, PAGE_SIZE))
            items = []
            for row in _data_rows(body):
                vid = _text(row, ['id'])
                title = _text(row, ['title'])
                if not vid or not title:
                    continue
                total = _text(row, ['list_total'])
                items.append(_folder('actor:' + vid, title, _text(row, ['cover']), total + ' 部' if total else ''))
            return {'list': items, 'page': pg, 'pagecount': 0, 'total': _int(body, ['total'])}
        if tid.startswith('actor:'):
            body = _api_json('/actor.html?actor_id=%s&pageNo=%s&pageSize=%s' % (tid[6:], pg, PAGE_SIZE))
            items = [_card(r) for r in _data_rows(body)]
            return {'list': items, 'page': pg, 'pagecount': 0, 'total': _int(body, ['total'])}
        if tid == 'tags':
            body = _api_json('/config.html')
            items = [_folder('tag:' + vid, name, '', '') for vid, name in _config_tags(body)]
            return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}
        if tid.startswith('tag:'):
            body = _api_json('/config.html')
            title = ''
            for vid, name in _config_tags(body):
                if vid == tid[4:]:
                    title = name
                    break
            if not title:
                return {'list': [], 'page': pg, 'pagecount': 0, 'total': 0}
            sbody = _api_json('/search.html?keyword=%s&pageNo=%s&pageSize=%s' % (urllib.parse.quote(title), pg, PAGE_SIZE))
            items = [_card(r) for r in _data_rows(sbody)]
            return {'list': items, 'page': pg, 'pagecount': 0, 'total': _int(sbody, ['total'])}
        return {'list': [], 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        body = _api_json('/movie.html?m_id=%s' % urllib.parse.quote(nid))
        if not isinstance(body, dict):
            return {'list': []}
        title = _text(body, ['title'])
        if not title:
            return {'list': []}
        cover = _cover_of(body)
        watched = _text(body, ['watched'])
        startdate = _text(body, ['startdate'])
        barcode = _text(body, ['barcode'])
        play_list = _text(body, ['play_list'])
        if not play_list:
            return {'list': []}
        user = body.get('user') if isinstance(body.get('user'), dict) else {}
        is_vip = _int(user, ['is_vip']) == 1
        actors = []
        if isinstance(body.get('actor'), list):
            for r in body['actor']:
                n = _text(r, ['title'])
                if n:
                    actors.append(n)
        tags = []
        if isinstance(body.get('tag'), list):
            for r in body['tag']:
                n = _text(r, ['title'])
                if n:
                    tags.append(n)
        parts = []
        if watched:
            parts.append('播放 ' + watched)
        if startdate:
            parts.append('上架 ' + startdate)
        if barcode:
            parts.append('编码 ' + barcode)
        synopsis = ' · '.join(parts)
        if actors:
            if synopsis:
                synopsis += '\n'
            synopsis += '演员：' + ' / '.join(actors)
        if tags:
            if synopsis:
                synopsis += '\n'
            synopsis += '标签：' + ' / '.join(tags)
        if is_vip:
            synopsis += '\n已开通 VIP，全片可播'
        else:
            synopsis += '\n匿名试看 60 秒（网页端只放 10 秒，登录非 VIP 25 秒）；全片须 VIP'
        related = []
        if isinstance(body.get('recommend'), list):
            for r in body['recommend'][:5]:
                t = _text(r, ['title'])
                if t:
                    related.append(t)
        if related:
            synopsis += '\n猜你喜欢：' + ' / '.join(related)
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': ' / '.join(actors),
            'vod_director': '',
            'vod_remarks': watched,
            'vod_year': '',
            'vod_area': '',
            'vod_content': synopsis,
            'type_name': '',
            'vod_tag': ' / '.join(tags),
            'vod_play_from': '在线播放',
            'vod_play_url': '在线播放$%s@0' % nid,
            'stills': [cover] if cover else [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        key = (key or '').strip()
        if not key:
            return {'list': [], 'page': pg, 'pagecount': 0, 'total': 0}
        body = _api_json('/search.html?keyword=%s&pageNo=1&pageSize=%s' % (urllib.parse.quote(key), PAGE_SIZE))
        items = [_card(r) for r in _data_rows(body)]
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': _int(body, ['total'])}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        header = {'User-Agent': UA, 'Referer': REFERER}
        mid = raw.split('@')[0]
        if not mid or not mid.isdigit():
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        body = _api_json('/movie.html?m_id=%s' % mid)
        url = _text(body, ['play_list']) if isinstance(body, dict) else ''
        if not url:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        return {'parse': 0, 'playUrl': url, 'url': url, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', '']

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
