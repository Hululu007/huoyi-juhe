try:
    from base.spider import BaseSpider
except Exception:
    try:
        from base import BaseSpider
    except Exception:
        class BaseSpider:
            pass


import base64
import gzip
import html as _html
import http.client
import http.cookiejar
import json
import re
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = 'https://sjgyoptiq.hjfwoz.com'
S3 = 'https://soost.hnxyjws.com'
UA = 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36'
INVITE_CODE = 'UYJQFG'
PAGE_SIZE = 20
PAGE_ITEMS = 10

CATS = [
    (6, '国产传媒'), (1, '日本有码'), (3, '中文字幕'), (17, '黑料吃瓜'),
    (4, '欧美性爱'), (9, '网红主播'), (15, '探花'), (2, '日本无码'),
    (5, '自拍偷拍'), (7, '动漫卡通'), (8, '强奸乱伦'), (14, 'AV解说'),
    (16, '热舞'), (10, '重口猎奇'), (11, '同性专区'), (12, '其他'),
    (13, '短视频'),
]

_JAR = http.cookiejar.CookieJar()
_OPENER = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(_JAR))
_SESSION = {'token': '', 'invite_code': ''}


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _caesar_decode(text):
    try:
        shifted = ''.join(chr(ord(c) - 8) for c in text)
        clean = ''.join(ch for ch in shifted if not ch.isspace())
        clean = clean.replace('-', '+').replace('_', '/')
        pad = (-len(clean)) % 4
        clean += '=' * pad
        raw = base64.b64decode(clean)
        return json.loads(raw.decode('utf-8', 'replace'))
    except Exception:
        return None


def _call_once(method, path, body=None, token=None):
    url = BASE + path
    h = {'User-Agent': UA, 'Accept': 'application/json, text/plain, */*', 'Vue-Path': '/', 'Referer': BASE + '/'}
    data = None
    if method == 'POST':
        h['Content-Type'] = 'application/json'
        data = (body if body is not None else '{}').encode('utf-8')
    if token:
        h['token'] = token
    req = urllib.request.Request(url, data=data, headers=h, method=method)
    with _OPENER.open(req, timeout=30, context=_ctx()) as resp:
        raw = resp.read()
        ct = (resp.headers.get('Content-Type') or '').lower()
        text = raw.decode('utf-8', 'replace')
    if resp.status != 200:
        raise Exception('欢爱请求 HTTP %d' % resp.status)
    if 'text/plain' in ct:
        v = _caesar_decode(text)
        if v is not None:
            return v
    return json.loads(text)


def _call(method, path, body=None, token=None):
    last = ''
    for _ in range(3):
        try:
            return _call_once(method, path, body, token)
        except Exception as e:
            last = str(e)
            time.sleep(1)
    raise Exception(last)


def _check(v):
    if not isinstance(v, dict):
        raise Exception('欢爱返回非对象')
    if v.get('code') != 0:
        raise Exception('欢爱接口错误 code %s' % v.get('code'))
    return v.get('data')


def _register():
    body = json.dumps({'inviteCode': INVITE_CODE, 'sourceUrl': None})
    v = _call('POST', '/api/user/register', body, None)
    data = _check(v)
    token = (data or {}).get('token') or ''
    invite = (data or {}).get('inviteCode') or ''
    if not token:
        raise Exception('欢爱自动注册未返回 token')
    return {'token': token, 'invite_code': invite}


def _session():
    if _SESSION.get('token'):
        return dict(_SESSION)
    s = _register()
    _SESSION['token'] = s['token']
    _SESSION['invite_code'] = s['invite_code']
    return s


def _clear_session():
    _SESSION['token'] = ''
    _SESSION['invite_code'] = ''


def _balance(token):
    v = _call('GET', '/api/user/home', None, token)
    data = _check(v) or {}
    ca = data.get('readCoinAccount') or {}
    try:
        return float(ca.get('availableAmount') or 0)
    except Exception:
        return 0.0


def _farm_invite(sess):
    if not sess.get('invite_code'):
        raise Exception('欢爱本号无邀请码')
    body = json.dumps({'inviteCode': sess['invite_code'], 'sourceUrl': None})
    v = _call('POST', '/api/user/register', body, None)
    _check(v)
    v = _call('POST', '/api/task/receive-reward?serialNum=1&taskId=1', '{}', sess['token'])
    _check(v)


def _buy(token, vod_id):
    v = _call('GET', '/api/film-b/buy?vodId=%s' % vod_id, None, token)
    _check(v)


def _ensure_full(vod_id):
    sess = _session()
    for _ in range(2):
        try:
            if _balance(sess['token']) >= 1000.0:
                _buy(sess['token'], vod_id)
                return sess
        except Exception:
            pass
        try:
            _farm_invite(sess)
        except Exception:
            _clear_session()
            sess = _session()
            continue
        try:
            if _balance(sess['token']) >= 1000.0:
                _buy(sess['token'], vod_id)
                return sess
        except Exception:
            pass
        _clear_session()
        sess = _session()
    raise Exception('欢爱解锁失败：邀请奖励未到账，完整版拿不到')


def _cover_url(p):
    p = (p or '').strip()
    if not p:
        return ''
    if p.startswith('http://') or p.startswith('https://'):
        return p
    if p.startswith('//'):
        return 'https:' + p
    if p.startswith('/'):
        return S3 + p
    return S3 + '/' + p


def _card(v):
    try:
        vid = int(v.get('vodId') or 0)
    except Exception:
        return None
    if vid == 0:
        return None
    title = v.get('vodName') or ''
    if not title:
        return None
    return {'vod_id': str(vid), 'vod_name': title, 'vod_pic': _cover_url(v.get('vodPic') or ''), 'vod_remarks': v.get('vodDuration') or ''}


def _parse_duration(text):
    total = 0.0
    for p in (text or '').strip().split(':'):
        try:
            total = total * 60.0 + float(p)
        except Exception:
            total = total * 60.0
    return total


def _playlist_seconds(text):
    total = 0.0
    for line in (text or '').splitlines():
        if line.startswith('#EXTINF:'):
            rest = line[8:]
            num = ''
            for c in rest:
                if c.isdigit() or c == '.':
                    num += c
                else:
                    break
            try:
                total += float(num)
            except Exception:
                pass
    return total


def _fetch_text(url, referer=None):
    h = {'User-Agent': UA}
    if referer:
        h['Referer'] = referer
    try:
        req = urllib.request.Request(url, headers=h)
        with _OPENER.open(req, timeout=30, context=_ctx()) as resp:
            raw = resp.read()
            enc = (resp.headers.get('Content-Encoding') or '').lower()
            if enc == 'gzip' or raw[:2] == b'\x1f\x8b':
                try:
                    raw = gzip.decompress(raw)
                except Exception:
                    pass
            return raw.decode('utf-8', 'replace')
    except Exception:
        return ''


def _playlist_is_preview(url, card_secs):
    if card_secs <= 0:
        return False
    text = _fetch_text(url, referer=BASE + '/')
    total = _playlist_seconds(text)
    return total > 0 and total < card_secs / 2.0


def _watch_lines(play_url):
    out = []
    for part in (play_url or '').split('$$$'):
        part = part.strip()
        if not part:
            continue
        if '$' in part:
            name, url = part.split('$', 1)
            if url.strip():
                out.append((name.strip(), url.strip()))
        else:
            out.append(('在线播放', part))
    if not out:
        out.append(('在线播放', ''))
    return out


def _abs_play_url(u):
    u = (u or '').strip()
    if not u:
        return ''
    if u.startswith('http://') or u.startswith('https://'):
        return u
    if u.startswith('/'):
        return BASE + u
    return BASE + '/' + u


def _fetch_watch(vod_id, token):
    v = _call('GET', '/api/film-b/watch?vodId=%s' % vod_id, None, token)
    return _check(v) or {}


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
        return '欢爱'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=''):
        cats = []
        try:
            v = _call('GET', '/api/cache/common', None, None)
            data = _check(v) or {}
            types = data.get('filmBTypes') or []
            seen = set()
            for t in types:
                try:
                    tid = int(t.get('typeId') or 0)
                except Exception:
                    tid = 0
                name = t.get('typeName') or ''
                if tid and name and tid not in seen:
                    seen.add(tid)
                    cats.append((tid, name))
        except Exception:
            cats = []
        if len(cats) < 10:
            cats = list(CATS)
        items = []
        try:
            items = self.categoryContent(str(cats[0][0]), 1).get('list') or []
        except Exception:
            items = []
        return {
            'class': [{'type_id': str(tid), 'type_name': name} for tid, name in cats],
            'list': items,
        }

    def homeVideoContent(self):
        try:
            return {'list': self.categoryContent('6', 1).get('list') or [], 'page': 1, 'pagecount': 0, 'total': 0}
        except Exception:
            return {'list': [], 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        try:
            type_id = int(_norm_id(tid))
        except Exception:
            return {'list': [], 'page': pg, 'pagecount': 0, 'total': 0}
        if type_id not in [c[0] for c in CATS]:
            return {'list': [], 'page': pg, 'pagecount': 0, 'total': 0}
        sess = _session()
        body = json.dumps({'orderBy': 'hits_day', 'typeId': type_id, 'current': pg, 'size': PAGE_SIZE})
        v = _call('POST', '/api/film-b/paginate', body, sess['token'])
        data = _check(v) or {}
        total = data.get('total') or 0
        records = data.get('records') or []
        items = []
        for r in records:
            c = _card(r)
            if c:
                items.append(c)
        has_more = bool(items) and (pg - 1) * PAGE_ITEMS + len(items) < total
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': total if not has_more else 0}

    def detailContent(self, ids):
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        try:
            int(nid)
        except Exception:
            return {'list': []}
        sess = _session()
        data = _fetch_watch(nid, sess['token'])
        title = data.get('vodName') or ''
        if not title:
            return {'list': []}
        cover = _cover_url(data.get('vodPic') or '')
        tag = data.get('vodTag') or ''
        blurb = data.get('vodBlurb') or ''
        duration = data.get('vodDuration') or ''
        hits = data.get('vodHits') or 0
        synopsis = blurb if blurb else title
        if tag:
            synopsis += '\n标签：' + tag
        if hits:
            synopsis += '\n播放：%d次' % hits
        if duration:
            synopsis += '\n片长：' + duration
        try:
            price = float(data.get('vodCoinPrice') or 0)
        except Exception:
            price = 0.0
        if price > 0:
            synopsis += '\n价格：%.0f金币/片' % price
        play_url = data.get('vodPlayUrl') or ''
        eps = []
        for i, (name, _u) in enumerate(_watch_lines(play_url)):
            eps.append('%s$%s#%d' % (name, nid, i))
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': duration,
            'vod_year': '',
            'vod_area': '',
            'vod_content': synopsis,
            'type_name': '',
            'vod_tag': tag,
            'vod_play_from': '在线播放',
            'vod_play_url': '#'.join(eps),
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        sess = _session()
        q = (key or '').replace('\\', '\\\\').replace('"', '\\"')
        body = json.dumps({'currentPage': 1, 'words': q})
        v = _call('POST', '/api/film-b/search', body, sess['token'])
        data = _check(v)
        items = []
        if isinstance(data, list):
            for r in data:
                c = _card(r)
                if c:
                    items.append(c)
        elif isinstance(data, dict):
            for r in data.get('records') or []:
                c = _card(r)
                if c:
                    items.append(c)
        return {'list': items, 'page': _norm_pg(pg), 'pagecount': 0, 'total': len(items)}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        if '#' in raw:
            vod_id, line_idx = raw.split('#', 1)
        else:
            vod_id, line_idx = raw, '0'
        try:
            line_idx = int(line_idx)
        except Exception:
            line_idx = 0
        try:
            int(vod_id)
        except Exception:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        try:
            sess = _session()
            data = _fetch_watch(vod_id, sess['token'])
            card_secs = _parse_duration(data.get('vodDuration') or '')
            lines = _watch_lines(data.get('vodPlayUrl') or '')
            url = _abs_play_url(lines[line_idx][1]) if line_idx < len(lines) else ''
            if not url:
                return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
            if _playlist_is_preview(url, card_secs):
                sess = _ensure_full(vod_id)
                data = _fetch_watch(vod_id, sess['token'])
                lines = _watch_lines(data.get('vodPlayUrl') or '')
                url = _abs_play_url(lines[line_idx][1]) if line_idx < len(lines) else ''
                if not url:
                    return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
                card_secs = _parse_duration(data.get('vodDuration') or '')
                if _playlist_is_preview(url, card_secs):
                    return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
            return {'parse': 0, 'playUrl': url, 'url': url, 'header': header}
        except Exception:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', '']

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
