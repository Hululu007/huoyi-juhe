try:
    from base.spider import BaseSpider
except Exception:
    try:
        from base import BaseSpider
    except Exception:
        class BaseSpider:
            pass


import gzip
import hashlib
import html as _html
import http.client
import http.cookiejar
import json
import random
import re
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

HOST = 'https://en.javfun.me'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

TOKEN_STR = 'n1sqcua67bcq9826avrbi6m49vd7shxkn985mhodk06twz87wwxtp3dqiicks2dfyud213k6ygiomq01s94e4tr9v0k887bkyud213k6ygiomq01s94e4tr9v0k887bkqocxzw39esdyfhvtkpzq9n4e7at4kc6k8sxom08bl4dukp16h09oplu7zov4m5f8'
MD5_SALT = '9826avrbi6m49vd7shxkn9815'

CATS = [
    ('movie', '全部'),
    ('studio:1pondo', '1PONDO'),
    ('studio:caribbeancom', 'CARIBBEANCOM'),
    ('studio:10musume', '10MUSUME'),
    ('studio:pacopacomama', 'PACOPACOMAMA'),
    ('studio:heyzo', 'HEYZO'),
    ('studio:tokyo-hot', 'Tokyo Hot'),
    ('studio:japanhdv', 'JapanHDV'),
    ('studio:asiansexdiary', 'AsianSexDiary'),
    ('category:uncensored', 'Jav Uncensored'),
]

_JAR = http.cookiejar.CookieJar()
_OPENER = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(_JAR))


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _get(url, referer=None, headers=None, timeout=30):
    h = {'User-Agent': UA, 'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'}
    if referer:
        h['Referer'] = referer
    if headers:
        h.update(headers)
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


def _decode_entities(s):
    return _html.unescape(s or '').replace('&nbsp;', ' ').replace('&ndash;', '–').replace('&mdash;', '—').strip()


def _truncate(s, n):
    s = s or ''
    if len(s) > n:
        return s[:n]
    return s


def _parse_cards(html):
    card_re = re.compile(r"""(?s)<a href="/movies/([A-Za-z0-9._-]+)"[^>]*class="ml-mask jt"[^>]*title="([^"]+)"[^>]*>.*?<img data-original='([^']+)'""")
    qual_re = re.compile(r'<span class="mli-quality">([^<]+)</span>')
    out = []
    seen = set()
    for m in card_re.finditer(html or ''):
        slug = m.group(1)
        vid = HOST + '/movies/' + slug
        if vid in seen:
            continue
        seen.add(vid)
        title = _decode_entities(m.group(2))
        if not title:
            continue
        cover = m.group(3)
        start = m.start()
        tail = html[start:start + 3000]
        qm = qual_re.search(tail)
        remark = qm.group(1) if qm else ''
        out.append({'vod_id': vid, 'vod_name': _truncate(title, 90), 'vod_pic': cover, 'vod_remarks': remark})
    return out


def _catalog_url(tid, pg):
    page_part = '' if pg <= 1 else '/page-%d' % pg
    if tid == 'movie':
        return HOST + '/japanese-porn-videos' + page_part
    if tid.startswith('studio:'):
        return HOST + '/studio/' + tid[len('studio:'):] + page_part
    if tid.startswith('category:'):
        return HOST + '/category/' + tid[len('category:'):] + page_part
    return HOST + '/japanese-porn-videos' + page_part


def _meta_content(html, attr, key):
    marker = '%s="%s"' % (attr, key)
    p = html.find(marker)
    if p < 0:
        return ''
    after = html[p:]
    c = after.find('content="')
    if c < 0:
        return ''
    s = c + 9
    e = after[s:].find('"')
    return _decode_entities(after[s:s + e]) if e >= 0 else ''


def _tag_title(html):
    p = html.find('<title>')
    if p < 0:
        return ''
    s = p + 7
    e = html[s:].find('</title>')
    if e < 0:
        e = len(html) - s
    return _decode_entities(html[s:s + e])


def _md5_hex(data):
    return hashlib.md5(data.encode('utf-8')).hexdigest()


def _random_b():
    chars = '0123456789abcdefghijklmnopqrstuvwxyz'
    return ''.join(random.choice(chars) for _ in range(6))


def _cookie_name(episode_id):
    chars = list(TOKEN_STR)
    head = ''.join(chars[13:37])
    tail = ''.join(chars[40:64])
    return head + episode_id + tail


def _sources_url(episode_id, b):
    md5 = _md5_hex(episode_id + b + MD5_SALT)
    return HOST + '/ajax/get_sources/%s/%s?count=1&mobile=false' % (episode_id, md5)


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
        return 'JJavFun'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=''):
        html = _get(HOST + '/japanese-porn-videos', referer=HOST + '/')
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in CATS],
            'list': _parse_cards(html),
        }

    def homeVideoContent(self):
        html = _get(HOST + '/japanese-porn-videos', referer=HOST + '/')
        return {'list': _parse_cards(html), 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        tid = _norm_id(tid) or 'movie'
        html = _get(_catalog_url(tid, pg), referer=HOST + '/')
        items = _parse_cards(html)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': len(items)}

    def detailContent(self, ids):
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        html = _get(nid, referer=HOST + '/')
        title = _tag_title(html)
        if not title:
            return {'list': []}
        cover = _meta_content(html, 'property', 'og:image')
        desc = _meta_content(html, 'name', 'description')
        ep_ids = []
        for m in re.finditer(r'loadEpisode\(\d+,"([A-Za-z0-9]+)"\)', html or ''):
            if m.group(1) not in ep_ids:
                ep_ids.append(m.group(1))
        if not ep_ids:
            return {'list': []}
        eps = []
        for i, ep in enumerate(ep_ids):
            name = '正片' if len(ep_ids) == 1 else '线路%d' % (i + 1)
            eps.append('%s$%s$%s' % (name, ep, nid))
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': '',
            'vod_year': '',
            'vod_area': '',
            'vod_content': _truncate(desc, 400),
            'type_name': '',
            'vod_tag': '',
            'vod_play_from': '在线播放',
            'vod_play_url': '#'.join(eps),
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        specials = "`~!@#$%^&*()_|=?;:'\",.<>{}[]\\/"
        cleaned = ''.join(c for c in (key or '') if c not in specials and c not in '<>')
        enc = urllib.parse.quote(cleaned.strip(), safe='').replace('+', '%20')
        html = _get(HOST + '/search/%s' % enc, referer=HOST + '/')
        items = _parse_cards(html)[:60]
        return {'list': items, 'page': _norm_pg(pg), 'pagecount': 0, 'total': len(items)}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        header = {'User-Agent': UA, 'Referer': HOST + '/'}
        if '.m3u8' in raw:
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        parts = raw.split('$')
        episode_id = parts[0] if parts else ''
        referer = parts[2] if len(parts) > 2 else HOST
        if not episode_id:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        b = _random_b()
        url = _sources_url(episode_id, b)
        cookie = '%s=%s' % (_cookie_name(episode_id), b)
        txt = _get(url, referer=referer, headers={'Accept': 'application/json, */*', 'Cookie': cookie})
        try:
            v = json.loads(txt or '{}')
        except Exception:
            v = {}
        file = ''
        try:
            file = v['playlist'][0]['sources'][0]['file']
        except Exception:
            file = ''
        if not file:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        return {'parse': 0, 'playUrl': file, 'url': file, 'header': {'User-Agent': UA, 'Referer': referer}}

    def localProxy(self, param):
        return [404, 'text/plain', '']

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
