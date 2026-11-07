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
import http.cookiejar
import json
import re
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = 'https://hohoj.tv'
UA = 'Mozilla/5.0 (Linux; Android 14; HarmonyOS; HUAWEI) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36'

CATS = [
    ('m1', '絲襪美腿', 'main', '1'),
    ('m2', '強姦凌辱', 'main', '2'),
    ('m3', '主奴調教', 'main', '3'),
    ('m4', '制服誘惑', 'main', '4'),
    ('m5', '多P群交', 'main', '5'),
    ('m6', '角色劇情', 'main', '6'),
    ('m7', '出軌', 'main', '7'),
    ('m8', '亂倫', 'main', '8'),
    ('m9', '巨乳美乳', 'main', '9'),
    ('m10', '潮吹放尿', 'main', '10'),
    ('m11', '走後門', 'main', '11'),
    ('m12', '內射受孕', 'main', '12'),
    ('t_censored', '有碼', 'type', 'censored'),
    ('t_uncensored', '無碼', 'type', 'uncensored'),
    ('t_chinese', '中文字幕', 'type', 'chinese'),
    ('t_europe', '歐美', 'type', 'europe'),
]

_JAR = http.cookiejar.CookieJar()
_OPENER = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(_JAR))


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _get(url, referer=None, timeout=60):
    h = {'User-Agent': UA}
    if referer:
        h['Referer'] = referer
    for _ in range(3):
        try:
            req = urllib.request.Request(url, headers=h)
            with _OPENER.open(req, timeout=timeout, context=_ctx()) as resp:
                raw = resp.read()
                enc = (resp.headers.get('Content-Encoding') or '').lower()
                if enc == 'gzip' or raw[:2] == b'\x1f\x8b':
                    try:
                        raw = gzip.decompress(raw)
                    except Exception:
                        pass
                return raw.decode('utf-8', 'replace')
        except urllib.error.HTTPError as e:
            try:
                return e.read().decode('utf-8', 'ignore')
            except http.client.IncompleteRead as ie:
                return ie.partial.decode('utf-8', 'ignore')
        except Exception:
            time.sleep(1)
    return ''


def _unescape(s):
    return _html.unescape(s or '').replace('&amp;', '&').replace('&quot;', '"').replace('&#39;', "'").replace('&nbsp;', ' ').replace('&lt;', '<').replace('&gt;', '>')


def _clean(t):
    if not t:
        return ''
    t = re.sub(r'<[^>]+>', ' ', t)
    return _html.unescape(re.sub(r'\s+', ' ', t)).strip()


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


def _find_cat(cid):
    for c in CATS:
        if c[0] == cid:
            return c
    return ('m8', '亂倫', 'main', '8')


def _parse_cards(html):
    card_re = re.compile(r'(?s)<a[^>]*href="/video\?id=(\d+)"[^>]*>(.*?)</a>')
    img_re = re.compile(r'<img[^>]*src="([^"]+)"[^>]*alt="([^"]*)"')
    title_re = re.compile(r'video-item-title[^>]*>([^<]+)<')
    badge_re = re.compile(r'video-item-badge">([^<]+)<')
    out = []
    seen = set()
    for m in card_re.finditer(html or ''):
        vid = '/video?id=%s' % m.group(1)
        if vid in seen:
            continue
        seen.add(vid)
        body = m.group(2)
        title = ''
        tm = title_re.search(body)
        if tm:
            title = _unescape(tm.group(1).strip())
        cover = ''
        im = img_re.search(body)
        if im:
            if not title:
                title = _unescape(im.group(2).strip())
            cover = im.group(1).strip()
        if not title:
            continue
        remark = ''
        bm = badge_re.search(body)
        if bm:
            remark = bm.group(1).strip()
        out.append({'vod_id': vid, 'vod_name': title, 'vod_pic': cover, 'vod_remarks': remark})
    return out


def _page_total(html):
    m = re.search(r'changePage\((\d+)\);">最後', html or '')
    if not m:
        return None
    try:
        return int(m.group(1))
    except Exception:
        return None


class Spider(BaseSpider):
    def getName(self):
        return '好好J'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=''):
        cid, name, kind, arg = _find_cat('m8')
        url = BASE + '/main_ctg?id=%s&name=%s' % (arg, urllib.parse.quote(name))
        html = _get(url, referer=BASE + '/')
        return {
            'class': [{'type_id': c[0], 'type_name': c[1]} for c in CATS],
            'list': _parse_cards(html),
        }

    def homeVideoContent(self):
        url = BASE + '/main_ctg?id=8&name=%s' % urllib.parse.quote('亂倫')
        html = _get(url, referer=BASE + '/')
        return {'list': _parse_cards(html), 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        tid = _norm_id(tid) or 'm8'
        cid, name, kind, arg = _find_cat(tid)
        if kind == 'main':
            base = BASE + '/main_ctg?id=%s&name=%s' % (arg, urllib.parse.quote(name))
            url = base if pg <= 1 else base + '&p=%d' % pg
        else:
            url = BASE + '/search?type=%s' % arg if pg <= 1 else BASE + '/search?type=%s&p=%d' % (arg, pg)
        html = _get(url, referer=BASE + '/')
        items = _parse_cards(html)
        total = _page_total(html)
        has_more = bool(total and pg < total)
        return {'list': items, 'page': pg, 'pagecount': total or 0, 'total': len(items) if not has_more else 0}

    def detailContent(self, ids):
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        if nid.startswith('http'):
            url = nid
        elif nid.startswith('/'):
            url = BASE + nid
        else:
            url = BASE + '/' + nid
        html = _get(url, referer=BASE + '/')
        title = ''
        tm = re.search(r'(?s)<title[^>]*>(.*?)</title>', html or '')
        if tm:
            title = _unescape(tm.group(1).strip())
            p = title.find(' HoHoJ ')
            if p >= 0:
                title = title[:p].strip()
        cover = ''
        cm = re.search(r'<meta property="og:image"[^>]*content="([^"]+)"', html or '')
        if cm:
            cover = cm.group(1).strip()
        synopsis = ''
        dm = re.search(r'<meta name="description"[^>]*content="([^"]+)"', html or '')
        if dm:
            synopsis = _unescape(dm.group(1).strip())
        if not title:
            return {'list': []}
        return {'list': [{
            'vod_id': nid,
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
            'vod_play_url': '播放$%s' % nid,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        url = BASE + '/search?text=%s' % urllib.parse.quote(str(key or ''))
        html = _get(url, referer=BASE + '/')
        items = _parse_cards(html)
        return {'list': items, 'page': _norm_pg(pg), 'pagecount': 0, 'total': len(items)}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        if raw.startswith('http') and '.m3u8' in raw:
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        vid = ''
        if 'id=' in raw:
            vid = raw.split('id=', 1)[1].split('&')[0]
        if not vid:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        detail_url = BASE + '/video?id=%s' % vid
        embed_url = BASE + '/embed?id=%s' % vid
        html = _get(embed_url, referer=detail_url)
        m3u8 = ''
        m = re.search(r'<video[^>]*src="([^"]+\.m3u8[^"]*)"', html or '')
        if m:
            m3u8 = m.group(1).strip()
        if not m3u8:
            m = re.search(r'videoSrc\s*=\s*"([^"]+\.m3u8[^"]*)"', html or '')
            if m:
                m3u8 = m.group(1).strip()
        if not m3u8:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        return {'parse': 0, 'playUrl': m3u8, 'url': m3u8, 'header': {'User-Agent': UA, 'Referer': detail_url}}

    def localProxy(self, param):
        return [404, 'text/plain', '']

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
