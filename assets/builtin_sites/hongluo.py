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

HOST = 'https://hongluo.co'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

CATS = [
    ('all', '全部', ''),
    ('xianxia-fantasy', '仙侠玄幻', '仙俠玄幻'),
    ('urban-romance', '都市情感', '都市情感'),
    ('fantasy-superpowers', '奇幻异能', '奇幻異能'),
    ('costume-palace', '古装宫廷', '古裝宮廷'),
    ('mystery-crime', '悬疑犯罪', '懸疑犯罪'),
    ('college-life', '大学校园', '大學校園'),
    ('family-drama', '家庭剧情', '家庭劇情'),
    ('workplace-business', '职场商战', '職場商戰'),
    ('supernatural-thriller', '灵异惊悚', '靈異驚悚'),
]

_JAR = http.cookiejar.CookieJar()


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


_OPENER = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(_JAR), urllib.request.HTTPSHandler(context=_ctx()))


def _http(url, headers=None, timeout=30):
    h = {'User-Agent': UA, 'Accept': 'application/json', 'Referer': HOST + '/zh-hans/'}
    if headers:
        h.update(headers)
    for _ in range(3):
        try:
            req = urllib.request.Request(url, headers=h)
            with _OPENER.open(req, timeout=timeout) as resp:
                raw = resp.read()
                enc = (resp.headers.get('Content-Encoding') or '').lower()
                if enc == 'gzip' or raw[:2] == b'\x1f\x8b':
                    try:
                        raw = gzip.decompress(raw)
                    except Exception:
                        pass
                return raw.decode('utf-8', 'replace'), resp.status
        except urllib.error.HTTPError as e:
            try:
                return e.read().decode('utf-8', 'ignore'), e.code
            except http.client.IncompleteRead as ie:
                return ie.partial.decode('utf-8', 'ignore'), 0
        except Exception:
            time.sleep(1)
    return '', 0


def _get_json(url):
    txt, _ = _http(url)
    try:
        return json.loads(txt or '{}')
    except Exception:
        return {}


def _get_html(url):
    h = {'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'}
    txt, _ = _http(url, headers=h)
    return txt


def _strip_tags(s):
    if not s:
        return ''
    t = re.sub(r'<[^>]+>', ' ', s)
    return _html.unescape(re.sub(r'\s+', ' ', t)).strip()


def _abs_url(u):
    if not u:
        return ''
    u = u.strip().replace('&amp;', '&')
    if u.startswith('http://') or u.startswith('https://'):
        return u
    if u.startswith('/'):
        return HOST + u
    return HOST + '/' + u


def _cover_of(poster):
    u = _abs_url(poster)
    if not u:
        return u
    return u + ('&w=240' if '?' in u else '?w=240')


def _api_category(cid):
    for c in CATS:
        if c[0] == cid:
            return c[2]
    return ''


def _display_genre(api_genre):
    for c in CATS:
        if c[2] == api_genre:
            return c[1]
    return api_genre or ''


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


def _parse_series_items(data):
    out = []
    series = data.get('series') if isinstance(data, dict) else None
    if not isinstance(series, list):
        return out
    for s in series:
        slug = (s.get('slug') or '').strip()
        if not slug:
            continue
        title = s.get('originalTitle') or s.get('title') or ''
        if not title:
            continue
        cover = _cover_of(s.get('posterUrl') or '')
        genre = _display_genre(s.get('category') or '')
        total = s.get('totalEpisodes') or 0
        free = s.get('freeEpisodes') or 0
        bits = []
        if genre:
            bits.append(genre)
        if total:
            bits.append('%d集' % total)
        if free:
            bits.append('免费%d集' % free)
        out.append({'vod_id': slug, 'vod_name': title, 'vod_pic': cover, 'vod_remarks': ' · '.join(bits)})
    return out


def _catalog_url(cid):
    api = _api_category(cid)
    if not api:
        return HOST + '/api/catalog'
    return HOST + '/api/catalog?category=%s' % urllib.parse.quote(api)


class Spider(BaseSpider):
    def getName(self):
        return '红裸短剧（成人）'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=''):
        data = _get_json(_catalog_url('all'))
        return {
            'class': [{'type_id': c[0], 'type_name': c[1]} for c in CATS],
            'list': _parse_series_items(data),
        }

    def homeVideoContent(self):
        data = _get_json(_catalog_url('all'))
        return {'list': _parse_series_items(data), 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        if pg > 1:
            return {'list': [], 'page': pg, 'pagecount': 0, 'total': 0}
        tid = _norm_id(tid) or 'all'
        data = _get_json(_catalog_url(tid))
        items = _parse_series_items(data)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': len(items)}

    def detailContent(self, ids):
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        html = _get_html(HOST + '/zh-hans/series/%s' % urllib.parse.quote(nid))
        title = ''
        m = re.search(r'<h1[^>]*>([^<]+)</h1>', html or '')
        if m:
            title = _strip_tags(m.group(1))
        if not title:
            p = (html or '').find('<title>')
            if p >= 0:
                after = html[p + 7:]
                e = after.find('</title>')
                if e >= 0:
                    title = _strip_tags(after[:e])
                    for sep in ('｜', '|'):
                        q = title.find(sep)
                        if q >= 0:
                            title = title[:q].strip()
                            break
        if not title:
            return {'list': []}
        cover = ''
        m = re.search(r'property="og:image" content="([^"]+)"', html or '')
        if m:
            cover = m.group(1)
        desc = ''
        m = re.search(r'name="description" content="([^"]*)"', html or '')
        if m:
            desc = m.group(1)
        genre = ''
        m = re.search(r'"genre":"([^"]+)"', html or '')
        if m:
            genre = _display_genre(m.group(1))
        eps = []
        seen = []
        free_count = 0
        ep_re = re.compile(r'<a href="[^"]*/ep-(\d+)">第\s*\d+\s*集：([^<]+)</a>\s*·\s*<!-- -->([^<]+)<!-- -->\s*·\s*约\s*(\d+)\s*分钟')
        for cap in ep_re.finditer(html or ''):
            try:
                n = int(cap.group(1))
            except Exception:
                continue
            if n in seen:
                continue
            seen.append(n)
            ep_title = cap.group(2).strip()
            access = cap.group(3).strip()
            try:
                minutes = int(cap.group(4))
            except Exception:
                minutes = 0
            is_free = '免费' in access
            if is_free:
                free_count += 1
            label = '第%d集：%s' % (n, ep_title)
            if minutes > 0:
                label += '·约%d分钟' % minutes
            if not is_free:
                label += '·VIP'
            eps.append((n, '%s$%s:%d' % (label, nid, n)))
        eps.sort(key=lambda x: x[0])
        if not eps:
            eps = [(1, '第1集$%s:1' % nid)]
        bits = []
        if genre:
            bits.append(genre)
        bits.append('共 %d 集' % len(eps))
        if free_count > 0:
            bits.append('免费 %d 集' % free_count)
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': ' · '.join(bits),
            'vod_year': '',
            'vod_area': '',
            'vod_content': desc,
            'type_name': genre,
            'vod_tag': genre,
            'vod_play_from': '在线播放',
            'vod_play_url': '#'.join(e[1] for e in eps),
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        url = HOST + '/api/catalog?q=%s' % urllib.parse.quote(str(key or ''))
        data = _get_json(url)
        items = _parse_series_items(data)
        return {'list': items, 'page': _norm_pg(pg), 'pagecount': 0, 'total': len(items)}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        header = {'User-Agent': UA, 'Referer': HOST + '/zh-hans/'}
        if '.mp4' in raw:
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
        ep_url = HOST + '/zh-hans/series/%s/ep-%d' % (urllib.parse.quote(sid), ep)
        html = _get_html(ep_url)
        src = ''
        m = re.search(r'<video[^>]*src="([^"]+)"', html or '')
        if m:
            src = m.group(1)
        if not src:
            m = re.search(r'"contentUrl":"([^"]+)"', html or '')
            if m:
                src = m.group(1)
        if not src:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        url = _abs_url(src)
        return {'parse': 0, 'playUrl': url, 'url': url, 'header': {'User-Agent': UA, 'Referer': ep_url}}

    def localProxy(self, param):
        return [404, 'text/plain', '']

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
