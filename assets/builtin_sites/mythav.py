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


HOST = 'https://sdyoof.asia'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

CATS = [
    ('chinese-subtitle', '中文字幕'),
    ('bdsm', '主奴调教'),
    ('sex-only', '直接开啪'),
    ('insult', '凌辱快感'),
    ('uniform', '制服诱惑'),
    ('roleplay', '角色剧情'),
    ('private-cam', '盗摄偷拍'),
    ('uncensored', '无码解放'),
    ('pov', '男友视角'),
    ('groupsex', '多P群交'),
    ('pantyhose', '丝袜美腿'),
    ('lesbian', '女同性恋'),
]


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _decode_page(body):
    best_start = 0
    best_len = 0
    i = 0
    n = len(body)
    hexchars = set('0123456789abcdefABCDEF')
    while i < n:
        if body[i] in hexchars:
            start = i
            while i < n and body[i] in hexchars:
                i += 1
            if i - start > best_len:
                best_len = i - start
                best_start = start
        else:
            i += 1
    if best_len >= 1000 and best_len % 2 == 0:
        try:
            raw = bytes.fromhex(body[best_start:best_start + best_len])
            return raw.decode('utf-8')
        except Exception:
            pass
    return body


def _http_get(url, timeout=25):
    h = {'User-Agent': UA, 'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8', 'Referer': HOST + '/zh/'}
    for _ in range(3):
        if _HAS_REQ:
            try:
                r = requests.get(url, headers=h, timeout=timeout)
                if r.status_code == 200 and r.text:
                    return _decode_page(r.text)
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
                return _decode_page(data.decode('utf-8', 'replace'))
        except urllib.error.HTTPError as e:
            try:
                return _decode_page(e.read().decode('utf-8', 'ignore'))
            except http.client.IncompleteRead as ie:
                return _decode_page(ie.partial.decode('utf-8', 'ignore'))
        except Exception:
            pass
        time.sleep(1)
    return ''


def _decode_entities(s):
    out = (s or '').replace('&nbsp;', ' ').replace('&amp;', '&').replace('&#039;', "'").replace('&#39;', "'").replace('&quot;', '"').replace('&lt;', '<').replace('&gt;', '>').replace('&ndash;', '–').replace('&mdash;', '—')
    while True:
        m = re.search(r'&#(\d{1,7});', out)
        if not m:
            break
        try:
            out = out[:m.start()] + chr(int(m.group(1))) + out[m.end():]
        except Exception:
            break
    return out.strip()


def _strip_tags(s):
    out = re.sub(r'<[^>]+>', '', s or '')
    return _decode_entities(out)


def _truncate(s, n):
    if len(s) > n:
        return s[:n]
    return s


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
        return 'MythAV'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cards(self, html):
        out = []
        seen = set()
        for block in (html or '').split('<article class="video-card">')[1:]:
            end = block.find('</article>')
            if end >= 0:
                block = block[:end]
            path = ''
            p = block.find('href="/zh/video?id=')
            if p >= 0:
                s = p + 6
                e = block[s:].find('"')
                if e >= 0:
                    path = block[s:s + e]
            if not path:
                p = block.find('href="/zh/guochan/play/')
                if p >= 0:
                    s = p + 6
                    e = block[s:].find('"')
                    if e >= 0:
                        path = block[s:s + e]
            if not path:
                continue
            vid = HOST + path
            if vid in seen:
                continue
            cover = ''
            p = block.find('<img src="')
            if p >= 0:
                s = p + 10
                e = block[s:].find('"')
                if e >= 0:
                    cover = block[s:s + e]
            remark = ''
            p = block.find('<span class="duration">')
            if p >= 0:
                s = p + 23
                e = block[s:].find('</span>')
                if e >= 0:
                    remark = block[s:s + e].strip()
            title = ''
            p = block.find('<h3>')
            if p >= 0:
                after = block[p:]
                e = after.find('</h3>')
                if e >= 0:
                    title = _strip_tags(after[:e])
            title = _truncate(title, 90)
            if not title:
                continue
            seen.add(vid)
            out.append({
                'vod_id': vid,
                'vod_name': title,
                'vod_pic': cover,
                'vod_remarks': remark,
            })
        return out

    def _tags(self, html):
        out = []
        seen = set()
        for block in (html or '').split('<a href="/zh/tags/')[1:]:
            e = block.find('"')
            if e < 0:
                continue
            slug = block[:e]
            if not slug or slug in seen:
                continue
            name = ''
            p = block.find('<b># ')
            if p >= 0:
                s = p + 5
                e2 = block[s:].find('</b>')
                if e2 >= 0:
                    name = _decode_entities(block[s:s + e2].strip())
            if not name:
                continue
            count = ''
            p = block.find('<small>')
            if p >= 0:
                s = p + 7
                e2 = block[s:].find('</small>')
                if e2 >= 0:
                    count = block[s:s + e2].strip()
            seen.add(slug)
            out.append({
                'vod_id': 'folder@/zh/tags/' + slug,
                'vod_name': name,
                'vod_pic': '',
                'vod_remarks': count + ' 部影片' if count else '',
                'vod_tag': 'folder',
            })
        return out

    def _catalog_url(self, category_id, page):
        def with_page(base):
            if page <= 1:
                return base
            if '?' in base:
                return '%s&p=%s' % (base, page)
            return '%s?p=%s' % (base, page)
        if category_id == 'latest':
            return with_page(HOST + '/zh/latest-updates')
        if category_id == 'guochan':
            return with_page(HOST + '/zh/guochan/category/43996?name=%E5%9B%BD%E4%BA%A7%E4%BC%A0%E5%AA%92')
        if category_id == 'tags':
            return HOST + '/zh/tags'
        if category_id.startswith('cat:'):
            return with_page(HOST + '/zh/categories/' + category_id[4:])
        if category_id.startswith('tag:'):
            return with_page(HOST + '/zh/tags/' + category_id[4:])
        return with_page(HOST + '/zh/latest-updates')

    def homeContent(self, filter=''):
        cats = [('latest', '最新上传')] + [('cat:' + s, n) for s, n in CATS] + [('guochan', '国产传媒'), ('tags', '标签')]
        items = self._cards(_http_get(HOST + '/zh/latest-updates'))
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in cats],
            'list': items,
        }

    def homeVideoContent(self):
        items = self._cards(_http_get(HOST + '/zh/latest-updates'))
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        if tid.startswith('folder@'):
            path = tid[7:]
            url = HOST + path
            if pg > 1:
                url = '%s?p=%s' % (url, pg)
            items = self._cards(_http_get(url))
            return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}
        if tid == 'tags':
            items = self._tags(_http_get(HOST + '/zh/tags'))
            return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}
        url = self._catalog_url(tid, pg)
        items = self._cards(_http_get(url))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        page_url = nid.split('$')[-1]
        html = _http_get(page_url)
        if not html:
            return {'list': []}
        title = ''
        p = html.find('<h1>')
        if p >= 0:
            after = html[p + 4:]
            e = after.find('</h1>')
            if e >= 0:
                title = _strip_tags(after[:e])
        if not title:
            return {'list': []}
        cover = ''
        m = re.search(r'property="og:image"[^>]*content="([^"]+)"', html)
        if not m:
            m = re.search(r'content="([^"]+)"[^>]*property="og:image"', html)
        if m:
            cover = _decode_entities(m.group(1))
        synopsis = ''
        m = re.search(r'"duration":"PT([0-9HMS]+)"', html)
        if m:
            secs = 0
            num = ''
            for c in m.group(1):
                if c.isdigit():
                    num += c
                else:
                    try:
                        v = int(num)
                    except Exception:
                        v = 0
                    if c == 'H':
                        secs += v * 3600
                    elif c == 'M':
                        secs += v * 60
                    elif c == 'S':
                        secs += v
                    num = ''
            synopsis = '时长：%02d:%02d:%02d' % (secs // 3600, (secs // 60) % 60, secs % 60)
        genres = []
        p = html.find('"genre":[')
        if p >= 0:
            rest = html[p + 9:]
            e = rest.find(']')
            if e >= 0:
                for t in rest[:e].split(','):
                    t = _decode_entities(t.strip().strip('"'))
                    if t:
                        genres.append(t)
        if genres:
            if synopsis:
                synopsis += '\n'
            synopsis += '标签：' + '、'.join(genres)
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
            'vod_tag': '、'.join(genres),
            'vod_play_from': '在线播放',
            'vod_play_url': '正片$%s' % page_url,
            'stills': [cover] if cover else [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        url = HOST + '/zh/search?text=' + urllib.parse.quote(key or '')
        items = self._cards(_http_get(url))[:60]
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        header = {'User-Agent': UA, 'Referer': HOST + '/zh/', 'Origin': HOST, 'Accept': '*/*'}
        if raw.startswith('http') and '.m3u8' in raw:
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        page_url = raw.split('$')[-1]
        html = _http_get(page_url)
        url = ''
        m = re.search(r'"url":"(https://[^"]+\.m3u8[^"]*)"', html or '')
        if m:
            url = m.group(1)
        if not url:
            m = re.search(r'"contentUrl":"([^"]+\.m3u8[^"]*)"', html or '')
            if m:
                url = m.group(1)
        if not url:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        header['Referer'] = page_url
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
