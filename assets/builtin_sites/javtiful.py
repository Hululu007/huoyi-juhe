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

HOST = 'https://javtiful.com'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

CATS = [
    ('latest', '最新影片'),
    ('censored', '有码'),
    ('uncensored', '无码'),
    ('reducing-mosaic', '减码'),
    ('actresses', '女优'),
    ('cat:female-investigator', 'Female Investigator'),
    ('cat:chinese-av', 'Chinese AV'),
    ('cat:female-boss', 'Female Boss'),
    ('cat:mature-woman', 'Mature Woman'),
    ('cat:cosplay', 'Cosplay'),
    ('cat:amateur', 'Amateur'),
    ('cat:housekeeper', 'Housekeeper'),
    ('cat:nurse', 'Nurse'),
    ('cat:female-student', 'Female Student'),
    ('cat:school-girls', 'School Girls'),
    ('cat:office-lady', 'Office Lady'),
    ('cat:sister-in-law', 'Sister-in-law'),
    ('cat:hypnosis', 'Hypnosis'),
    ('cat:beautiful-girl', 'Beautiful Girl'),
    ('cat:bbw', 'BBW'),
    ('cat:drama', 'Drama'),
    ('cat:married-woman', 'Married Woman'),
    ('cat:milf', 'Milf'),
    ('cat:female-teacher', 'Female Teacher'),
    ('cat:affair', 'Affair'),
    ('cat:big-tits', 'Big Tits'),
    ('actress:hatano-yui', 'Hatano Yui'),
    ('actress:iioka-kanako', 'Iioka Kanako'),
    ('actress:misono-waka', 'Misono Waka'),
    ('actress:yayoi-mizuki', 'Yayoi Mizuki'),
    ('actress:minatsuki-hikaru', 'Minatsuki Hikaru'),
    ('actress:hanazawa-himari', 'Hanazawa Himari'),
    ('actress:kuramoto-sumire', 'Kuramoto Sumire'),
    ('actress:tenma-yui', 'Tenma Yui'),
    ('actress:shinoda-yuu', 'Shinoda Yuu'),
    ('actress:kitano-mina', 'Kitano Mina'),
]


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _http_get(url, referer=None, timeout=25):
    h = {'User-Agent': UA, 'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8', 'Accept-Language': 'en-US,en;q=0.9', 'Accept-Encoding': 'gzip, deflate'}
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
            except Exception:
                pass
        except Exception:
            pass
        time.sleep(1)
    return ''


def _http_post(url, body, referer=None, timeout=25):
    h = {'User-Agent': UA, 'Accept': 'application/json, */*', 'Content-Type': 'application/x-www-form-urlencoded'}
    if referer:
        h['Referer'] = referer
    data = body.encode('utf-8') if isinstance(body, str) else body
    for _ in range(3):
        if _HAS_REQ:
            try:
                r = requests.post(url, data=data, headers=h, timeout=timeout)
                if r.status_code == 200 and r.text:
                    return r.text
            except Exception:
                pass
        try:
            req = urllib.request.Request(url, data=data, headers=h, method='POST')
            with urllib.request.urlopen(req, timeout=timeout, context=_ctx()) as resp:
                return resp.read().decode('utf-8', 'replace')
        except urllib.error.HTTPError as e:
            try:
                return e.read().decode('utf-8', 'ignore')
            except Exception:
                pass
        except Exception:
            pass
        time.sleep(1)
    return ''


def _clean(t):
    if not t:
        return ''
    t = re.sub(r'<[^>]+>', ' ', t)
    return _html.unescape(re.sub(r'\s+', ' ', t)).strip()


def _strip_tags(s):
    out = []
    in_tag = False
    for c in (s or ''):
        if c == '<':
            in_tag = True
        elif c == '>':
            in_tag = False
        elif not in_tag:
            out.append(c)
    return _decode_entities(''.join(out))


def _decode_entities(s):
    return _html.unescape(s or '').replace('&nbsp;', ' ').strip()


def _trunc(s, n):
    s = s or ''
    return s[:n] if len(s) > n else s


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


def _abs_url(path):
    if not path:
        return ''
    if path.startswith('http'):
        return path
    if path.startswith('/'):
        return HOST + path
    return HOST + '/' + path


def _video_cards(html):
    out = []
    seen = set()
    for block in (html or '').split('<article')[1:]:
        end = block.find('</article>')
        block = block[:end] if end >= 0 else block
        if 'video-card' not in block:
            continue
        p = block.find('<a href="/video/')
        if p < 0:
            continue
        s = p + 9
        e = block[s:].find('"')
        if e < 0:
            continue
        href = block[s:s + e]
        vid = _abs_url(href)
        if vid in seen:
            continue
        title = ''
        marker = 'video-card__title" title="'
        p = block.find(marker)
        if p >= 0:
            s = p + len(marker)
            e = block[s:].find('"')
            if e >= 0:
                title = _decode_entities(block[s:s + e])
        if not title:
            p = block.find('alt="Thumbnail for ')
            if p >= 0:
                s = p + 19
                e = block[s:].find('"')
                if e >= 0:
                    title = _decode_entities(block[s:s + e])
        if not title:
            continue
        cover = ''
        p = block.find('data-front-lazy-src="')
        if p >= 0:
            s = p + 21
            e = block[s:].find('"')
            if e >= 0:
                cover = block[s:s + e]
        remark = ''
        p = block.find('video-card__details')
        if p >= 0:
            after = block[p:]
            gt = after.find('>')
            if gt >= 0:
                s = gt + 1
                e = after[s:].find('</span>')
                raw = _strip_tags(after[s:s + e] if e >= 0 else after[s:])
                remark = raw.lstrip('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ').strip()
        seen.add(vid)
        out.append({'vod_id': vid, 'vod_name': _trunc(title, 90), 'vod_pic': _abs_url(cover), 'vod_remarks': remark})
    return out


def _actress_cards(html):
    out = []
    for block in (html or '').split('<article')[1:]:
        end = block.find('</article>')
        block = block[:end] if end >= 0 else block
        if 'directory-card--actress' not in block:
            continue
        marker = '<a class="directory-card__link" href="/actress/'
        p = block.find(marker)
        if p < 0:
            continue
        s = p + len(marker)
        e = block[s:].find('"')
        if e < 0:
            continue
        slug = block[s:s + e]
        name = ''
        p = block.find('directory-card__name">')
        if p >= 0:
            s = p + 22
            e = block[s:].find('<')
            if e >= 0:
                name = _decode_entities(block[s:s + e])
        if not name:
            continue
        cover = ''
        p = block.find('<img src="')
        if p >= 0:
            s = p + 10
            e = block[s:].find('"')
            if e >= 0:
                cover = block[s:s + e]
        count = ''
        p = block.find('directory-card__count">')
        if p >= 0:
            s = p + 23
            e = block[s:].find('<')
            if e >= 0:
                count = block[s:s + e].strip()
        out.append({'vod_id': 'actress:' + slug, 'vod_name': name, 'vod_pic': _abs_url(cover), 'vod_remarks': count})
    return out


def _catalog_url(tid, pg):
    def with_page(base):
        if pg <= 1:
            return base
        return '%s?page=%d' % (base, pg)
    if tid == 'latest':
        return with_page(HOST + '/videos')
    if tid in ('censored', 'uncensored', 'reducing-mosaic'):
        return with_page(HOST + '/' + tid)
    if tid == 'actresses':
        return with_page(HOST + '/actresses')
    if tid.startswith('cat:'):
        return with_page(HOST + '/category/' + tid[4:])
    if tid.startswith('actress:'):
        return with_page(HOST + '/actress/' + tid[8:])
    return with_page(HOST + '/videos')


def _meta(html, attr, key):
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
    if e < 0:
        return ''
    return _decode_entities(after[s:s + e])


def _tag_title(html):
    p = html.find('<title>')
    if p < 0:
        return ''
    s = p + 7
    e = html[s:].find('</title>')
    t = _decode_entities(html[s:s + e] if e >= 0 else html[s:])
    i = t.rfind(' | ')
    if i >= 0:
        return t[:i].strip()
    return t


def _pick_source(body):
    try:
        obj = json.loads(body or '{}')
    except Exception:
        return ''
    sources = obj.get('sources') if isinstance(obj, dict) else None
    if not isinstance(sources, list):
        return ''
    best = None
    best_size = -1
    for s in sources:
        if not isinstance(s, dict):
            continue
        src = s.get('src') or ''
        if not src:
            continue
        try:
            size = int(s.get('size') or 0)
        except Exception:
            size = 0
        if size > best_size:
            best_size = size
            best = src
    return best or ''


class Spider(BaseSpider):
    def getName(self):
        return 'Javtiful'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _catalog(self, tid, pg):
        html = _http_get(_catalog_url(tid, pg), referer=HOST + '/')
        if tid == 'actresses':
            return _actress_cards(html)
        return _video_cards(html)

    def homeContent(self, filter=''):
        cats = list(CATS)
        items = self._catalog(cats[0][0], 1) if cats else []
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in cats],
            'list': items,
        }

    def homeVideoContent(self):
        cats = list(CATS)
        items = self._catalog(cats[0][0], 1) if cats else []
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        items = self._catalog(_norm_id(tid), pg)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        if nid.startswith('actress:'):
            slug = nid[8:]
            url = HOST + '/actress/' + slug
            html = _http_get(url, referer=HOST + '/')
            cards = _video_cards(html)
            if not cards:
                return {'list': []}
            eps = []
            for c in cards:
                eps.append('%s$%s' % (_trunc(c['vod_name'], 60), c['vod_id']))
            return {'list': [{
                'vod_id': nid,
                'vod_name': _tag_title(html) or slug,
                'vod_pic': cards[0]['vod_pic'],
                'vod_actor': '',
                'vod_director': '',
                'vod_remarks': '',
                'vod_year': '',
                'vod_area': '',
                'vod_content': '',
                'type_name': '',
                'vod_tag': '',
                'vod_play_from': '在线播放',
                'vod_play_url': '#'.join(eps),
                'stills': [],
            }]}
        page_url = nid if nid.startswith('http') else HOST + nid
        html = _http_get(page_url, referer=HOST + '/')
        if not html:
            return {'list': []}
        title = _tag_title(html)
        if not title:
            return {'list': []}
        cover = _abs_url(_meta(html, 'property', 'og:image'))
        desc = _meta(html, 'name', 'description')
        actresses = []
        rest = html
        while len(actresses) < 6:
            p = rest.find('<a href="/actress/')
            if p < 0:
                break
            after = rest[p:]
            gt = after.find('>')
            if gt >= 0:
                s = gt + 1
                e = after[s:].find('</a>')
                if e >= 0:
                    name = _strip_tags(after[s:s + e])
                    if name and name not in actresses:
                        actresses.append(name)
            rest = rest[p + 1:]
        if actresses:
            if desc:
                desc += '\n'
            desc += '女优：' + '、'.join(actresses)
        desc = _trunc(desc, 400)
        play_title = _trunc(title, 60)
        return {'list': [{
            'vod_id': page_url,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': ' / '.join(actresses),
            'vod_director': '',
            'vod_remarks': '',
            'vod_year': '',
            'vod_area': '',
            'vod_content': desc,
            'type_name': '',
            'vod_tag': '、'.join(actresses),
            'vod_play_from': '在线播放',
            'vod_play_url': '%s$%s' % (play_title, page_url),
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        url = '%s/search?q=%s' % (HOST, urllib.parse.quote(str(key or '')))
        html = _http_get(url, referer=HOST + '/')
        return {'list': _video_cards(html)[:60], 'page': _norm_pg(pg), 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        header = {'User-Agent': UA, 'Referer': HOST + '/'}
        if raw.startswith('http') and ('.mp4' in raw or '.m3u8' in raw):
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        page_url = raw.split('$')[-1].strip()
        html = _http_get(page_url, referer=HOST + '/')
        if not html:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        m = re.search(r'"playback":\{"endpoint":"([^"]+)","ticket":"([^"]+)"', html)
        if not m:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        endpoint, ticket = m.group(1), m.group(2)
        body = 'ticket=' + urllib.parse.quote(ticket, safe='')
        text = _http_post(_abs_url(endpoint), body, referer=page_url)
        src = _pick_source(text)
        if not src:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        url = _abs_url(src)
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
