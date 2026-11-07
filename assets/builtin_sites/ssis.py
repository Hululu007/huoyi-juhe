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


BASE = 'https://ssis1.cc'
UA = 'Mozilla/5.0 (Linux; Android 14; HarmonyOS; HUAWEI) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36'
PAGE_SIZE = 24

CATS = [
    ('t14', '中文字幕'),
    ('t11', '亚洲有码'),
    ('t40', '制服丝袜'),
    ('t18', '亚洲无码'),
    ('t6', '日本精品'),
    ('t5', '女优系列'),
    ('t7', '巨乳美乳'),
    ('t15', '欧美精品'),
    ('t47', '过膝袜'),
    ('t17', '男同性恋'),
    ('t19', '传媒出品'),
    ('t33', '兽耳系列'),
    ('t27', '古装扮演'),
    ('t32', '瑜伽裤'),
    ('t28', '野外露出'),
    ('t34', '女同性恋'),
    ('t13', '韩国御姐'),
    ('t31', '可爱学生'),
    ('t21', '台湾辣妹'),
    ('t26', '唯美港姐'),
    ('t41', '闷骚护士'),
    ('t29', '多人多P'),
    ('t20', '伦理三级'),
    ('t3', '东南亚AV'),
    ('t25', '剧情介绍'),
    ('t12', '风情旗袍'),
    ('t10', '欺辱凌辱'),
    ('t8', '恋腿狂魔'),
    ('t36', '素人自拍'),
    ('t37', '网红流出'),
    ('t38', '自拍偷拍'),
    ('t30', 'Cosplay'),
    ('t9', '口交颜射'),
    ('t24', '主播直播'),
    ('t43', '精品推荐'),
    ('t22', '网曝门'),
]


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _http_get(url, referer=None, timeout=25):
    h = {'User-Agent': UA, 'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8', 'Accept-Language': 'zh-CN,zh;q=0.9', 'Accept-Encoding': 'gzip, deflate'}
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


def _decrypt_page(html):
    km = re.search(r'CRYPT_KEY="([^"]+)"', html or '')
    if not km:
        return html or ''
    pm = re.search(r"h=decrypt\('([^']+)'\)", html)
    if not pm:
        return html or ''
    try:
        raw = base64.b64decode(pm.group(1))
    except Exception:
        return html or ''
    kb = km.group(1).encode('utf-8')
    if not kb:
        return html or ''
    plain = bytes(b ^ kb[i % len(kb)] for i, b in enumerate(raw))
    return plain.decode('utf-8', 'replace')


def _initial_data(html):
    marker = 'window.__INITIAL_DATA__ = '
    start = (html or '').find(marker)
    if start < 0:
        return None
    start += len(marker)
    depth = 0
    in_str = False
    esc = False
    i = start
    while i < len(html):
        ch = html[i]
        if in_str:
            if esc:
                esc = False
            elif ch == '\\':
                esc = True
            elif ch == '"':
                in_str = False
        elif ch == '"':
            in_str = True
        elif ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                try:
                    return json.loads(html[start:i + 1])
                except Exception:
                    return None
        i += 1
    return None


def _txt(v, keys):
    if not isinstance(v, dict):
        return ''
    for k in keys:
        val = v.get(k)
        if isinstance(val, str) and val:
            return val
        if isinstance(val, (int, float)):
            return str(val)
    return ''


def _videos_to_items(data):
    out = []
    if not isinstance(data, dict):
        return out
    videos = data.get('videos')
    if not isinstance(videos, list):
        return out
    for v in videos:
        if not isinstance(v, dict):
            continue
        title = _txt(v, ['title'])
        vid = _txt(v, ['id'])
        if not title or not vid:
            continue
        cover = _txt(v, ['thumb'])
        date = _txt(v, ['date'])
        tag = _txt(v, ['tag', 'code', 'category'])
        if date and tag:
            remark = date + ' · ' + tag
        else:
            remark = date or tag
        out.append({'vod_id': '/watch?id=%s' % vid, 'vod_name': title, 'vod_pic': cover, 'vod_remarks': remark})
    return out


def _parse_cards(html):
    out = []
    seen = set()
    pat = re.compile(r'<a[^>]*href="/watch\?id=(\d+)"[^>]*>(.*?)</a>', re.S)
    for m in pat.finditer(html or ''):
        vid = '/watch?id=%s' % m.group(1)
        if vid in seen:
            continue
        seen.add(vid)
        body = m.group(2)
        tm = re.search(r'alt="([^"]+)"', body)
        title = _html.unescape(tm.group(1).strip()) if tm else ''
        if not title:
            continue
        cm = re.search(r'<img[^>]*src="([^"]+)"', body)
        cover = cm.group(1) if cm else ''
        dm = re.search(r'(\d{4}-\d{2}-\d{2})', body)
        remark = dm.group(1) if dm else ''
        out.append({'vod_id': vid, 'vod_name': title, 'vod_pic': cover, 'vod_remarks': remark})
    return out


def _live_cats(html):
    out = []
    seen = set()
    nav = re.compile(r'<a href="/topic\?id=(\d+)"[^>]*>([^<]+)</a>')
    for m in nav.finditer(html or ''):
        name = m.group(2).strip()
        if not name or name in ('首页', '分类', '公告', '搜索'):
            continue
        cid = 't%s' % m.group(1)
        if cid in seen:
            continue
        seen.add(cid)
        out.append((cid, name))
    grid = re.compile(r'<a class="iw-cat-card" href="/topic\?id=(\d+)".*?<span class="iw-cat-name">([^<]+)</span>', re.S)
    for m in grid.finditer(html or ''):
        name = m.group(2).strip()
        cid = 't%s' % m.group(1)
        if not name or cid in seen:
            continue
        seen.add(cid)
        out.append((cid, name))
    return out


def _topic_num(tid):
    t = (tid or '').strip()
    if t.startswith('t'):
        t = t[1:]
    return t


def _watch_id(sid):
    s = (sid or '').strip()
    m = re.search(r'id=(\d+)', s)
    if m:
        return m.group(1)
    return s.lstrip('/').lstrip('watch').lstrip('?')


class Spider(BaseSpider):
    def getName(self):
        return 'ssisJAV'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cats(self):
        html = _http_get(BASE + '/genres', referer=BASE + '/')
        if html:
            inner = _decrypt_page(html)
            live = _live_cats(inner)
            if live:
                return live
        return list(CATS)

    def homeContent(self, filter=''):
        cats = self._cats()
        items = []
        try:
            items = self.categoryContent(cats[0][0], 1).get('list') or []
        except Exception:
            items = []
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in cats],
            'list': items,
        }

    def homeVideoContent(self):
        try:
            items = self.categoryContent(self._cats()[0][0], 1).get('list') or []
        except Exception:
            items = []
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        num = _topic_num(tid)
        url = '%s/topic?id=%s&page=%s' % (BASE, urllib.parse.quote(num), pg)
        html = _http_get(url, referer=BASE + '/')
        inner = _decrypt_page(html)
        data = _initial_data(inner)
        total = 0
        if data is not None:
            items = _videos_to_items(data)
            try:
                total = int(data.get('total') or 0)
            except Exception:
                total = 0
            if total > 0:
                has_more = pg * PAGE_SIZE < total
            else:
                has_more = bool(items) and ('page=%s' % (pg + 1)) in inner
        else:
            items = _parse_cards(inner)
            has_more = bool(items) and ('page=%s' % (pg + 1)) in inner
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': total}

    def detailContent(self, ids):
        vid = _watch_id(_norm_id(ids))
        if not vid:
            return {'list': []}
        url = '%s/watch?id=%s' % (BASE, urllib.parse.quote(vid))
        html = _http_get(url, referer=BASE + '/')
        inner = _decrypt_page(html)
        data = _initial_data(inner)
        if not isinstance(data, dict):
            return {'list': []}
        video = data.get('video')
        if not isinstance(video, dict):
            return {'list': []}
        title = _txt(video, ['title'])
        m3u8 = _txt(video, ['videoUrl']) or _txt(video, ['magnet'])
        if not m3u8:
            m = re.search(r'data-video-url="([^"]+\.m3u8[^"]*)"', inner)
            if m:
                m3u8 = m.group(1)
        if not title or not m3u8:
            return {'list': []}
        cover = _txt(video, ['thumb'])
        synopsis = _txt(video, ['desc'])
        return {'list': [{
            'vod_id': '/watch?id=%s' % vid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': '',
            'vod_year': '',
            'vod_area': '',
            'vod_content': synopsis,
            'type_name': '',
            'vod_tag': '',
            'vod_play_from': '在线播放',
            'vod_play_url': '播放$%s' % m3u8,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        url = '%s/search?q=%s&page=1' % (BASE, urllib.parse.quote(str(key or '')))
        html = _http_get(url, referer=BASE + '/')
        inner = _decrypt_page(html)
        data = _initial_data(inner)
        if data is not None:
            items = _videos_to_items(data)
        else:
            items = _parse_cards(inner)
        return {'list': items, 'page': _norm_pg(pg), 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        if raw.startswith('http'):
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', b'', {}]

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
