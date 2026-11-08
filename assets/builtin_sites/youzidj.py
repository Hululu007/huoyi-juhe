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


BASE = 'https://youzidj.com'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

CATS = [
    ('dramas', '全部短剧'),
    ('dramas/category/cultivation', '修仙'),
    ('dramas/category/wealthy-family', '豪门'),
    ('dramas/category/urban', '都市'),
    ('dramas/category/costume', '古装'),
    ('dramas/category/family-ethics', '家庭伦理'),
    ('dramas/category/martial-arts', '武侠'),
    ('dramas/category/campus', '校园'),
    ('ai-adult', 'AI成人视频'),
    ('ai-adult/real', 'AI真人'),
    ('ai-adult/anime', 'AI动漫'),
    ('ai-adult/remix', 'AI魔改'),
    ('ai-face-swap', 'AI换脸'),
]

CARD_RE = re.compile(r'<article class="drama-card[^>]*>(.*?)</article>', re.S)
LINK_RE = re.compile(r'<a class="home-drama-card-link"[^>]*aria-label="查看详情：([^"]*)"[^>]*href="([^"]+)"')
LINK_RE2 = re.compile(r'<a class="home-drama-card-link"[^>]*href="([^"]+)"[^>]*aria-label="查看详情：([^"]*)"')
IMG_RE = re.compile(r'<img[^>]*src="([^"]+)"')
TITLE_RE = re.compile(r'<p class="drama-card-title"[^>]*>([^<]+)</p>')
REMARKS_RE = re.compile(r'更新至(\d+)集')
OG_IMG_RE = re.compile(r'<meta property="og:image" content="([^"]+)"')
META_DESC_RE = re.compile(r'<meta name="description" content="([^"]+)"')
TITLE_TAG_RE = re.compile(r'<title[^>]*>(.*?)</title>', re.S)
LD_RE = re.compile(r'<script type="application/ld\+json">(.*?)</script>', re.S)
EP_RE = re.compile(r'<a[^>]*class="series-episode-link"[^>]*title="([^"]*)"[^>]*aria-label="第 (\d+) 集[^"]*"[^>]*data-paid="([^"]*)"[^>]*href="([^"]+)"')
EP_RE2 = re.compile(r'<a[^>]*class="series-episode-link"[^>]*href="([^"]+)"[^>]*title="([^"]*)"[^>]*aria-label="第 (\d+) 集[^"]*"[^>]*data-paid="([^"]*)"')
EP_NUM_RE = re.compile(r'更新至(\d+)集')
YEAR_RE = re.compile(r'发布年份[^<]*</[^>]+>\s*(\d{4})')
TAG_RE = re.compile(r'aria-label="查看“([^”]+)”标签下')
PLAYER_RE = re.compile(r'<div class="watch-player"[^>]*data-video="([^"]+)"[^>]*data-work="([^"]*)"[^>]*data-version="([^"]*)"[^>]*data-price="([^"]*)"')
PLAYER_RE2 = re.compile(r'data-video="([^"]+)"[^>]*data-version="([^"]*)"[^>]*data-price="([^"]*)"')
PLAYER_RE3 = re.compile(r'id="player"[^>]*data-video="([^"]+)"[^>]*data-version="([^"]*)"[^>]*data-price="([^"]*)"')
CONTENT_URL_RE = re.compile(r'"contentUrl":"([^"]+)"')
ART_RE = re.compile(r'/catalogue-art/[0-9a-f-]+-960\.webp')


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _unescape(s):
    if not s:
        return ''
    return _html.unescape(s).strip()


def _fix_url(raw):
    u = (raw or '').strip()
    if not u:
        return ''
    if u.startswith('//'):
        return 'https:' + u
    if u.startswith('/'):
        return BASE + u
    return u


def _http_get(url, referer=None, timeout=30):
    h = {
        'User-Agent': UA,
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9',
        'Accept-Encoding': 'gzip, deflate',
    }
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


def _http_post_json(url, referer=None, timeout=30):
    body = b'{}'
    h = {
        'User-Agent': UA,
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'Origin': BASE,
        'Sec-Fetch-Site': 'same-origin',
        'Sec-Fetch-Mode': 'cors',
        'Sec-Fetch-Dest': 'empty',
    }
    if referer:
        h['Referer'] = referer
    for _ in range(2):
        if _HAS_REQ:
            try:
                r = requests.post(url, headers=h, data=body, timeout=timeout)
                if r.status_code == 200 and r.text:
                    return r.text
                if r.status_code in (402, 403):
                    return r.text
            except Exception:
                pass
        try:
            req = urllib.request.Request(url, data=body, headers=h, method='POST')
            with urllib.request.urlopen(req, timeout=timeout, context=_ctx()) as resp:
                return resp.read().decode('utf-8', 'replace')
        except urllib.error.HTTPError as e:
            try:
                return e.read().decode('utf-8', 'ignore')
            except Exception:
                return ''
        except Exception:
            pass
        time.sleep(1)
    return ''


def _parse_cards(html):
    out = []
    seen = set()
    for cm in CARD_RE.finditer(html or ''):
        block = cm.group(1)
        lm = LINK_RE.search(block) or LINK_RE2.search(block)
        if not lm:
            continue
        if lm.re is LINK_RE:
            title, href = lm.group(1), lm.group(2)
        else:
            href, title = lm.group(1), lm.group(2)
        title = _unescape(title)
        if not title:
            tm = TITLE_RE.search(block)
            title = _unescape(tm.group(1)) if tm else ''
        if not title:
            continue
        path = href.replace(BASE, '').strip('/')
        if not path or path in seen:
            continue
        seen.add(path)
        im = IMG_RE.search(block)
        pic = _fix_url(im.group(1)) if im else ''
        rm = REMARKS_RE.search(block)
        remarks = ('更新至%s集' % rm.group(1)) if rm else ''
        out.append({
            'vod_id': path,
            'vod_name': title,
            'vod_pic': pic,
            'vod_remarks': remarks,
        })
    return out


def _norm_id(ids):
    if isinstance(ids, (list, tuple)):
        ids = ids[0] if ids else ''
    return str(ids or '').strip().strip('/')


def _norm_pg(pg):
    try:
        pg = int(pg)
    except Exception:
        pg = 1
    return pg if pg >= 1 else 1


class Spider(BaseSpider):
    def getName(self):
        return '柚子短剧'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _list_url(self, tid, pg):
        tid = (tid or 'dramas').strip().strip('/')
        if pg <= 1:
            return '%s/%s/' % (BASE, tid)
        return '%s/%s/page/%d/' % (BASE, tid, pg)

    def _catalog(self, tid, pg):
        return _parse_cards(_http_get(self._list_url(tid, pg), referer=BASE + '/'))

    def homeContent(self, filter=''):
        items = self._catalog(CATS[0][0], 1)
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in CATS],
            'list': items,
        }

    def homeVideoContent(self):
        items = self._catalog(CATS[0][0], 1)
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        items = self._catalog(tid, pg)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        url = '%s/%s/' % (BASE, nid)
        html = _http_get(url, referer=BASE + '/')
        if not html:
            return {'list': []}
        title = ''
        synopsis = ''
        pic = ''
        year = ''
        total = 0
        for lm in LD_RE.finditer(html):
            try:
                data = json.loads(lm.group(1))
            except Exception:
                continue
            if not isinstance(data, dict):
                continue
            t = data.get('@type', '')
            if t == 'TVSeason' or t == 'TVSeries':
                title = title or _unescape(data.get('name', ''))
                synopsis = synopsis or _unescape(data.get('description', ''))
                pic = pic or _fix_url(data.get('image', ''))
                total = total or int(data.get('numberOfEpisodes') or 0)
            elif t == 'VideoObject':
                title = title or _unescape(data.get('name', ''))
                synopsis = synopsis or _unescape(data.get('description', ''))
                pic = pic or _fix_url((data.get('thumbnailUrl') or [''])[0])
        if not pic:
            om = OG_IMG_RE.search(html)
            pic = _fix_url(om.group(1)) if om else ''
        if not synopsis:
            dm = META_DESC_RE.search(html)
            synopsis = _unescape(dm.group(1)) if dm else ''
        if not title:
            tm = TITLE_TAG_RE.search(html)
            title = _unescape(tm.group(1)) if tm else ''
            title = re.sub(r'\s*[|｜].*$', '', title).strip()
        ym = YEAR_RE.search(html)
        year = ym.group(1) if ym else '2026'
        tags = sorted(set(_unescape(t) for t in TAG_RE.findall(html.split('相关推荐')[0])))
        eps = []
        seen_ep = set()
        for m in EP_RE.finditer(html):
            ep_title, num, paid, href = m.group(1), m.group(2), m.group(3), m.group(4)
            if num in seen_ep:
                continue
            seen_ep.add(num)
            name = '第%s集' % num
            if paid == 'true':
                name += '·需解锁'
            eps.append('%s$youzidj:%s' % (name, _fix_url(href)))
        if not eps:
            for m in EP_RE2.finditer(html):
                href, ep_title, num, paid = m.group(1), m.group(2), m.group(3), m.group(4)
                if num in seen_ep:
                    continue
                seen_ep.add(num)
                name = '第%s集' % num
                if paid == 'true':
                    name += '·需解锁'
                eps.append('%s$youzidj:%s' % (name, _fix_url(href)))
        if not eps:
            pm = PLAYER_RE.search(html) or PLAYER_RE2.search(html) or PLAYER_RE3.search(html)
            if pm:
                eps = ['正片$youzidj:%s' % url]
        if not eps:
            eps = ['正片$youzidj:%s' % url]
        if not total:
            nm = EP_NUM_RE.search(html)
            total = int(nm.group(1)) if nm else len(eps)
        remarks = ('更新至%d集' % total) if total else ''
        stills = []
        seen_pic = set([pic])
        for m in ART_RE.finditer(html):
            u = _fix_url(m.group(0))
            if u and u not in seen_pic:
                seen_pic.add(u)
                stills.append(u)
            if len(stills) >= 8:
                break
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': pic,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': remarks,
            'vod_year': year,
            'vod_area': '',
            'vod_content': synopsis,
            'type_name': '',
            'vod_tag': ' '.join(tags),
            'vod_play_from': '在线播放',
            'vod_play_url': '#'.join(eps),
            'stills': stills,
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        url = '%s/search/?q=%s' % (BASE, urllib.parse.quote(key or ''))
        if pg > 1:
            url = '%s/search/?q=%s&page=%d' % (BASE, urllib.parse.quote(key or ''), pg)
        items = _parse_cards(_http_get(url, referer=BASE + '/'))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        if raw.startswith('youzidj:'):
            raw = raw[len('youzidj:'):]
        url = raw if raw.startswith('http') else _fix_url(raw)
        header = {'User-Agent': UA, 'Referer': url, 'Origin': BASE}
        html = _http_get(url, referer=BASE + '/')
        video_id = ''
        price = '0'
        pm = None
        if html:
            pm = PLAYER_RE.search(html) or PLAYER_RE3.search(html) or PLAYER_RE2.search(html)
            if pm:
                video_id = pm.group(1)
                price = pm.group(4) if pm.re is PLAYER_RE else (pm.group(3) if len(pm.groups()) >= 3 else '0')
        play_url = ''
        if video_id:
            api = '%s/api/playback/%s?mode=native' % (BASE, video_id)
            if price == '0':
                api += '&startup=1'
            resp = _http_post_json(api, referer=url)
            if resp:
                try:
                    data = json.loads(resp)
                    play_url = (data.get('url') or '').strip()
                except Exception:
                    play_url = ''
        return {'parse': 0, 'playUrl': play_url, 'url': play_url, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', '']

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
