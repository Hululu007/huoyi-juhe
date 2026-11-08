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


HOST = 'https://sexaix.top'
API = HOST + '/api'
UA = 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36'
PAGE_SIZE = 20

_MEDIA_DOMAIN = ''


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _http_get(url, referer=None, accept='application/json, text/plain, */*', timeout=30):
    h = {'User-Agent': UA, 'Accept': accept, 'Accept-Language': 'zh-CN', 'Accept-Encoding': 'gzip, deflate'}
    if referer:
        h['Referer'] = referer
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


def _api(path):
    global _MEDIA_DOMAIN
    txt = _http_get(API + path, referer=HOST + '/')
    try:
        obj = json.loads(txt or '{}')
    except Exception:
        return None
    if isinstance(obj, dict) and obj.get('code') == 0:
        return obj.get('data')
    return obj if isinstance(obj, (list, dict)) else None


def _config():
    global _MEDIA_DOMAIN
    if _MEDIA_DOMAIN:
        return _MEDIA_DOMAIN
    data = _api('/home/config')
    if isinstance(data, dict):
        _MEDIA_DOMAIN = (data.get('mediaDomain') or '').strip()
    return _MEDIA_DOMAIN


def _fix(url):
    if not url:
        return ''
    u = str(url).strip()
    if not u or u.startswith('#'):
        return u
    if re.match(r'^(?:[a-z][a-z\d+\-.]*:)?//', u, re.I) or u.startswith('data:') or u.startswith('blob:'):
        return u
    if u.startswith('/images/') or u.startswith('/assets/'):
        return u
    if u.startswith('/api/'):
        return HOST + u
    md = _config().rstrip('/')
    if md:
        return md + '/' + u.lstrip('/')
    return HOST + u if u.startswith('/') else u


def _card(d):
    if not isinstance(d, dict):
        return None
    did = d.get('id')
    title = d.get('title') or ''
    if did is None or not title:
        return None
    bits = []
    cat = (d.get('categoryName') or '').strip()
    if cat:
        bits.append(cat)
    total = d.get('totalEpisodes')
    if total:
        try:
            bits.append('共%s集' % int(total))
        except Exception:
            pass
    views = d.get('viewCount')
    if views:
        bits.append('播放%s' % views)
    return {
        'vod_id': str(did),
        'vod_name': title,
        'vod_pic': _fix(d.get('coverUrl') or ''),
        'vod_remarks': ' · '.join(bits),
    }


def _cards(items):
    out = []
    seen = set()
    for d in items or []:
        c = _card(d)
        if c and c['vod_id'] not in seen:
            seen.add(c['vod_id'])
            out.append(c)
    return out


def _cats():
    data = _api('/dramas/categories?language=zh-CN')
    cats = [('all', '全部')]
    if isinstance(data, list):
        for c in data:
            if not isinstance(c, dict):
                continue
            cid = c.get('id')
            name = (c.get('name') or '').strip()
            if cid is None or not name:
                continue
            cats.append((str(cid), name))
    return cats


def _list_all(category_id=None, scene=None):
    params = {'language': 'zh-CN'}
    if category_id:
        params['categoryId'] = str(category_id)
    if scene:
        params['scene'] = scene
    qs = urllib.parse.urlencode(params)
    data = _api('/dramas?' + qs)
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        for k in ('items', 'list', 'rows'):
            if isinstance(data.get(k), list):
                return data[k]
    return []


def _detail(did):
    data = _api('/dramas/%s?language=zh-CN' % urllib.parse.quote(str(did)))
    return data if isinstance(data, dict) else {}


def _pick_variant(master_url, referer=None):
    txt = _http_get(master_url, referer=referer, accept='application/vnd.apple.mpegurl, */*')
    if not txt or '#EXT-X-STREAM-INF' not in txt:
        return ''
    best_bw = -1
    best_url = ''
    lines = txt.splitlines()
    for i, line in enumerate(lines):
        line = line.strip()
        if not line.startswith('#EXT-X-STREAM-INF'):
            continue
        bw = -1
        m = re.search(r'BANDWIDTH=(\d+)', line)
        if m:
            try:
                bw = int(m.group(1))
            except Exception:
                bw = -1
        nxt = ''
        for j in range(i + 1, len(lines)):
            s = lines[j].strip()
            if s:
                nxt = s
                break
        if nxt and bw >= best_bw:
            best_bw = bw
            best_url = nxt
    if not best_url:
        return ''
    if best_url.startswith('http://') or best_url.startswith('https://'):
        return best_url
    if best_url.startswith('/'):
        return HOST + best_url
    return master_url.rsplit('/', 1)[0] + '/' + best_url


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


def _page(items, pg):
    pg = _norm_pg(pg)
    total = len(items)
    pages = (total + PAGE_SIZE - 1) // PAGE_SIZE if total else 0
    start = (pg - 1) * PAGE_SIZE
    return items[start:start + PAGE_SIZE], pg, pages, total


class Spider(BaseSpider):
    def getName(self):
        return '幻影AI'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=''):
        cats = _cats()
        items, _, _, _ = _page(_list_all(), 1)
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in cats],
            'list': _cards(items),
        }

    def homeVideoContent(self):
        items, _, _, _ = _page(_list_all(), 1)
        return {'list': _cards(items), 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        tid = str(tid or 'all')
        if tid == 'all':
            items = _list_all()
        else:
            items = _list_all(category_id=tid)
        part, pg, pages, total = _page(items, pg)
        return {'list': _cards(part), 'page': pg, 'pagecount': pages, 'total': total, 'limit': PAGE_SIZE}

    def detailContent(self, ids):
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        d = _detail(nid)
        if not d or not d.get('title'):
            return {'list': []}
        cover = _fix(d.get('coverUrl') or '')
        desc = (d.get('intro') or d.get('shareDesc') or d.get('shareTitle') or '').strip()
        cat = (d.get('categoryName') or '').strip()
        eps = []
        locked = 0
        for ep in d.get('episodes') or []:
            if not isinstance(ep, dict):
                continue
            eid = ep.get('id')
            if eid is None:
                continue
            try:
                no = int(ep.get('episodeNo') or 0)
            except Exception:
                no = 0
            label = ep.get('title') or ('第%s集' % no if no else '第%s集' % eid)
            is_locked = not ep.get('isUnlocked', True)
            if is_locked:
                locked += 1
                label = label + '·需解锁'
            eps.append('%s$sexaix:%s:%s' % (label, nid, eid))
        if not eps and d.get('currentEpisode'):
            ce = d.get('currentEpisode')
            if isinstance(ce, dict) and ce.get('id') is not None:
                eps = ['第1集$sexaix:%s:%s' % (nid, ce.get('id'))]
        if not eps:
            eps = ['第1集$sexaix:%s:1' % nid]
        remark_bits = []
        if cat:
            remark_bits.append(cat)
        total = d.get('totalEpisodes')
        if total:
            remark_bits.append('共%s集' % total)
        if locked:
            remark_bits.append('%s集需解锁' % locked)
        views = d.get('viewCount')
        if views:
            remark_bits.append('播放%s' % views)
        stills = []
        car = _fix(d.get('carouselImageUrl') or '')
        if car and car != cover:
            stills.append(car)
        for ep in d.get('episodes') or []:
            if isinstance(ep, dict):
                th = _fix(ep.get('coverUrl') or '')
                if th and th != cover and th not in stills:
                    stills.append(th)
        return {'list': [{
            'vod_id': nid,
            'vod_name': d.get('title') or '',
            'vod_pic': cover,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': ' · '.join(remark_bits),
            'vod_year': '',
            'vod_area': '',
            'vod_content': desc,
            'type_name': cat,
            'vod_tag': cat,
            'vod_play_from': '在线播放',
            'vod_play_url': '#'.join(eps),
            'stills': stills,
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        key = (key or '').strip()
        items = _list_all()
        if key:
            kl = key.lower()
            items = [d for d in items if isinstance(d, dict) and kl in str(d.get('title') or '').lower()]
        part, pg, pages, total = _page(items, pg)
        return {'list': _cards(part), 'page': pg, 'pagecount': pages, 'total': total, 'limit': PAGE_SIZE}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        if raw.startswith('sexaix:'):
            raw = raw[len('sexaix:'):]
        header = {'User-Agent': UA, 'Referer': HOST + '/'}
        url = ''
        if '.m3u8' in raw or '.mp4' in raw:
            url = _fix(raw)
        else:
            parts = raw.split(':')
            if len(parts) >= 2:
                did, eid = parts[0], parts[1]
            else:
                did, eid = raw, ''
            d = _detail(did)
            ep = None
            for e in d.get('episodes') or []:
                if isinstance(e, dict) and str(e.get('id')) == str(eid):
                    ep = e
                    break
            if ep is None and d.get('currentEpisode'):
                ce = d.get('currentEpisode')
                if isinstance(ce, dict) and str(ce.get('id')) == str(eid):
                    ep = ce
            if ep is not None:
                if ep.get('isUnlocked', True) and ep.get('videoUrl'):
                    url = _fix(ep.get('videoUrl'))
                    if url:
                        variant = _pick_variant(url, referer=HOST + '/')
                        if variant:
                            url = variant
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
