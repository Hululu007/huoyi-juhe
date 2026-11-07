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

HOST = 'https://huangguotv.com'
MEDIA = 'https://media.huangguotv.com'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
PAGE_SIZE = 24

CATS = [
    ('home', '首页'),
    ('33', '成人短剧'),
    ('ai', 'AI短剧'),
    ('latest', '最新短剧'),
    ('popular', '热门短剧'),
]

_JAR = http.cookiejar.CookieJar()
_OPENER = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(_JAR))


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _get(url, headers=None, timeout=30):
    h = {'User-Agent': UA, 'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8', 'Referer': HOST + '/'}
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


def _strip_tags(s):
    if not s:
        return ''
    t = re.sub(r'<[^>]+>', ' ', s)
    return _html.unescape(re.sub(r'\s+', ' ', t)).strip()


def _attr(block, name):
    marker = '%s="' % name
    p = block.find(marker)
    if p < 0:
        return ''
    s = p + len(marker)
    e = block[s:].find('"')
    return block[s:s + e] if e >= 0 else ''


def _tag_text(block, tag):
    p = block.find('<%s' % tag)
    if p < 0:
        return ''
    after = block[p:]
    s = after.find('>')
    if s < 0:
        return ''
    s += 1
    close = '</%s>' % tag
    e = after[s:].find(close)
    if e < 0:
        e = len(after) - s
    return _strip_tags(after[s:s + e])


def _clean_title(t):
    s = (t or '').strip()
    for sep in ('｜', '|'):
        p = s.find(sep)
        if p >= 0:
            s = s[:p].strip()
    return s


def _og(html, prop):
    marker = 'property="%s"' % prop
    p = html.find(marker)
    if p < 0:
        return ''
    after = html[p:]
    c = after.find('content="')
    if c < 0:
        return ''
    s = c + 9
    e = after[s:].find('"')
    return after[s:s + e] if e >= 0 else ''


def _meta_name(html, name):
    marker = 'name="%s"' % name
    p = html.find(marker)
    if p < 0:
        return ''
    after = html[p:]
    c = after.find('content="')
    if c < 0:
        return ''
    s = c + 9
    e = after[s:].find('"')
    return after[s:s + e] if e >= 0 else ''


def _parse_cards(html):
    out = []
    for block in (html or '').split('<article class="seo-fallback-card"')[1:]:
        end = block.find('</article>')
        if end >= 0:
            block = block[:end]
        m = re.search(r'href="/video/(\d+)"', block)
        if not m:
            continue
        vid = m.group(1)
        title = _clean_title(_tag_text(block, 'h2'))
        if not title:
            title = _clean_title(_attr(block, 'alt'))
        if not title:
            continue
        cover = _attr(block, 'src')
        remark = _tag_text(block, 'span')
        out.append({'vod_id': vid, 'vod_name': title, 'vod_pic': cover, 'vod_remarks': remark})
    return out


def _catalog_url(tid, pg):
    if tid in ('home', ''):
        base = HOST
    elif tid == '33':
        base = HOST + '/category/33'
    elif tid in ('ai', 'latest', 'popular'):
        base = HOST + '/videos/' + tid
    else:
        base = HOST
    if pg > 1:
        return base + '?page=%d' % pg
    return base


def _hls_url(sid, ep):
    return '%s/hls/%s/ep%03d/master.m3u8' % (MEDIA, sid, max(ep, 1))


def _reep(content_url, ep):
    if not content_url:
        return ''
    new = re.sub(r'/ep\d{3}/', '/ep%03d/' % max(ep, 1), content_url)
    return new


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
        return '黄果TV短剧'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=''):
        html = _get(HOST)
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in CATS],
            'list': _parse_cards(html),
        }

    def homeVideoContent(self):
        html = _get(HOST)
        return {'list': _parse_cards(html), 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        tid = _norm_id(tid) or 'home'
        html = _get(_catalog_url(tid, pg))
        items = _parse_cards(html)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': len(items)}

    def detailContent(self, ids):
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        html = _get(HOST + '/video/%s' % nid)
        title = _tag_text(html, 'h1')
        if not title:
            title = _clean_title(_og(html, 'og:title'))
        if not title:
            title = _clean_title(_tag_text(html, 'title'))
        if not title:
            return {'list': []}
        cover = _og(html, 'og:image')
        desc = _meta_name(html, 'description') or _og(html, 'og:description')
        eps = []
        seen = set()
        for m in re.finditer(r'href="/video/(\d+)\?ep=(\d+)"', html):
            if m.group(1) == nid:
                n = int(m.group(2))
                if n not in seen:
                    seen.add(n)
                    eps.append(n)
        if not eps:
            eps = [1]
        eps.sort()
        play_url = '#'.join('第%d集$%s:%d' % (n, nid, n) for n in eps)
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': '共 %d 集' % len(eps),
            'vod_year': '',
            'vod_area': '',
            'vod_content': desc,
            'type_name': '',
            'vod_tag': '',
            'vod_play_from': '在线播放',
            'vod_play_url': play_url,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        url = HOST + '/api/search?keyword=%s&page=1&pageSize=24&sortBy=created_at&sortOrder=desc' % urllib.parse.quote(str(key or ''))
        txt = _get(url, headers={'Accept': 'application/json, text/plain, */*'})
        try:
            value = json.loads(txt or '{}')
        except Exception:
            return {'list': [], 'page': _norm_pg(pg), 'pagecount': 0, 'total': 0}
        if not isinstance(value, dict) or value.get('code') != 1:
            return {'list': [], 'page': _norm_pg(pg), 'pagecount': 0, 'total': 0}
        data = value.get('data') or {}
        lst = []
        if isinstance(data, dict):
            lst = data.get('list') or []
        elif isinstance(data, list):
            lst = data
        items = []
        for v in lst:
            if not isinstance(v, dict):
                continue
            vid = v.get('id') or v.get('videoId') or 0
            if not vid:
                continue
            title = _clean_title(v.get('title') or v.get('name') or '')
            if not title:
                continue
            cover = v.get('coverUrl') or v.get('cover') or v.get('image') or v.get('pic') or ''
            total = v.get('episodeCount') or v.get('totalEpisodes') or v.get('episodes') or 0
            views = v.get('viewsCount') or v.get('viewCount') or v.get('plays') or 0
            remark = ''
            if total and views:
                remark = '%s集 · %s播放' % (total, views)
            elif total:
                remark = '%s集' % total
            items.append({'vod_id': str(vid), 'vod_name': title, 'vod_pic': cover, 'vod_remarks': remark})
        return {'list': items, 'page': _norm_pg(pg), 'pagecount': 0, 'total': len(items)}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        header = {'User-Agent': UA, 'Referer': HOST + '/'}
        if '.m3u8' in raw:
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        if ':' in raw:
            sid, ep = raw.split(':', 1)
        else:
            sid, ep = raw, '1'
        try:
            ep = int(ep)
        except Exception:
            ep = 1
        if not sid:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        url = ''
        html = _get(HOST + '/video/%s' % sid)
        m = re.search(r'https?://[^\s"\'<>]+\.m3u8', html or '')
        if m:
            url = _reep(m.group(0), ep)
        if not url:
            url = _hls_url(sid, ep)
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
