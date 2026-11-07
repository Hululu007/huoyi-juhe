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


BASE = 'https://pachub.net'
UA = 'Mozilla/5.0 (Linux; Android 14; HarmonyOS; HUAWEI) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36'

CATS = [
    ('av-all', '全部国产', ''),
    ('av-kxgc', '开心鬼传媒', '开心鬼传媒'),
    ('av-mdsp', '麻豆视频', '麻豆视频'),
    ('av-crtt', '成人头条', '成人头条'),
    ('av-mini', 'mini传媒', 'mini传媒'),
    ('av-lbsc', '乐播传媒', '乐播传媒'),
    ('av-wjcm', '乌鸦传媒', '乌鸦传媒'),
    ('av-txvlog', '糖心Vlog', '糖心vlog'),
    ('av-91sp', '91视频', '91视频'),
    ('av-dxcm', '大象传媒', '大象传媒'),
    ('av-xkcm', '星空传媒', '星空传媒'),
    ('av-mtcm', '蜜桃传媒', '蜜桃传媒'),
    ('av-jdyy', '精东影业', '精东影业'),
    ('av-tmcm', '天美传媒', '天美传媒'),
    ('av-91zpc', '91制片厂', '91制片厂'),
    ('av-xbzc', '杏吧原创', '杏吧原创'),
    ('av-xsj', '性视界', '性视界'),
    ('av-hjhr', '皇家华人', '皇家华人'),
    ('av-tzxs', '兔子先生', '兔子先生'),
    ('av-psycho', 'PsychoPorn', 'psychoporn'),
    ('av-hjsw', '海角社区', '海角社区'),
    ('av-wjjj', '玩偶姐姐', '玩偶姐姐'),
    ('ai-dj', 'AI成人短剧', 'AI成人短剧'),
]


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _http_get(url, timeout=25):
    h = {'User-Agent': UA, 'Referer': BASE}
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


def _http_post_json(url, referer, timeout=30):
    h = {'User-Agent': UA, 'Content-Type': 'application/json', 'Origin': BASE, 'Referer': referer}
    for _ in range(3):
        if _HAS_REQ:
            try:
                r = requests.post(url, headers=h, data='', timeout=timeout)
                if r.status_code == 200 and r.text:
                    return r.status_code, r.text
            except Exception:
                pass
        try:
            req = urllib.request.Request(url, data=b'', headers=h, method='POST')
            with urllib.request.urlopen(req, timeout=timeout, context=_ctx()) as resp:
                return resp.status, resp.read().decode('utf-8', 'replace')
        except urllib.error.HTTPError as e:
            try:
                return e.code, e.read().decode('utf-8', 'ignore')
            except Exception:
                return e.code, ''
        except Exception:
            pass
        time.sleep(1)
    return 0, ''


def _unescape(s):
    return (s or '').replace('&amp;', '&').replace('&quot;', '"').replace('&#39;', "'").replace('&lt;', '<').replace('&gt;', '>').replace('\\/', '/')


def _clean(t):
    if not t:
        return ''
    t = re.sub(r'<[^>]+>', ' ', t)
    return _html.unescape(re.sub(r'\s+', ' ', t)).strip()


def _fmt_duration(secs):
    try:
        secs = int(secs)
    except Exception:
        return ''
    if secs <= 0:
        return ''
    h = secs // 3600
    m = (secs % 3600) // 60
    s = secs % 60
    if h > 0:
        return '%s:%02d:%02d' % (h, m, s)
    return '%s:%02d' % (m, s)


def _direct_url(raw):
    u = (raw or '').strip()
    if u.startswith('/proxy/m3u8?u='):
        b64 = u[len('/proxy/m3u8?u='):].split('&')[0]
        padded = b64
        while len(padded) % 4 != 0:
            padded += '='
        try:
            decoded = base64.b64decode(padded).decode('utf-8').strip()
            if decoded.startswith('http'):
                return decoded
        except Exception:
            pass
        return BASE + u
    if u.startswith('/'):
        return BASE + u
    return u


def _text(v, keys):
    if not isinstance(v, dict):
        return ''
    for k in keys:
        x = v.get(k)
        if x is None or isinstance(x, bool):
            continue
        s = str(x)
        if s:
            return s
    return ''


def _int(v, keys):
    s = _text(v, keys)
    try:
        return int(float(s))
    except Exception:
        return 0


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
        return 'PacHub'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _api_items(self, body, ai):
        out = []
        if not isinstance(body, dict):
            return out
        for entry in body.get('items') or []:
            title = _text(entry, ['title'])
            if not title:
                continue
            cover = _text(entry, ['coverUrl'])
            remark = _fmt_duration(_int(entry, ['duration']))
            if ai:
                sid = _text(entry, ['sourceId'])
                if not sid:
                    continue
                vid = 'ai/' + sid
            else:
                num = _int(entry, ['id'])
                if num == 0:
                    continue
                vid = 'av/%s' % num
            out.append({
                'vod_id': vid,
                'vod_name': title,
                'vod_pic': cover,
                'vod_remarks': remark,
            })
        return out

    def _catalog(self, tid, pg):
        cat = None
        for c in CATS:
            if c[0] == tid:
                cat = c
                break
        if not cat:
            return []
        ai = tid == 'ai-dj'
        params = {'page': str(pg), 'page_size': '24'}
        if ai:
            params['category'] = cat[2]
            url = BASE + '/api/ai?' + urllib.parse.urlencode(params)
        elif not cat[2]:
            url = BASE + '/api/videos?' + urllib.parse.urlencode(params)
        else:
            params['category'] = cat[2]
            url = BASE + '/api/videos?' + urllib.parse.urlencode(params)
        try:
            body = json.loads(_http_get(url) or '{}')
        except Exception:
            body = {}
        return self._api_items(body, ai)

    def homeContent(self, filter=''):
        items = self._catalog('av-all', 1)
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name, _ in CATS],
            'list': items,
        }

    def homeVideoContent(self):
        items = self._catalog('av-all', 1)
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        items = self._catalog(tid, pg)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

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
        html = _http_get(url)
        if not html:
            return {'list': []}
        ai = '/ai/' in nid or '/ai/' in url
        title = ''
        m = re.search(r'<meta[^>]*content="([^"]+)"[^>]*property="og:title"|<meta[^>]*property="og:title"[^>]*content="([^"]+)"', html)
        if m:
            title = _unescape(m.group(1) or m.group(2) or '')
        suffix = ' · AI | PacHub' if ai else ' · 国产 | PacHub'
        if title.endswith(suffix):
            title = title[:-len(suffix)].strip()
        cover = ''
        m = re.search(r'<meta[^>]*content="([^"]+)"[^>]*property="og:image"|<meta[^>]*property="og:image"[^>]*content="([^"]+)"', html)
        if m:
            cover = _unescape(m.group(1) or m.group(2) or '')
        desc = ''
        m = re.search(r'<meta[^>]*content="([^"]+)"[^>]*name="description"|<meta[^>]*name="description"[^>]*content="([^"]+)"', html)
        if m:
            desc = _unescape(m.group(1) or m.group(2) or '')
        synopsis = desc.split(' — ')[0].strip()
        if not title:
            return {'list': []}
        episodes = []
        if ai:
            path = url[len(BASE):].lstrip('/')
            series = path[3:].split('-')[0] if path.startswith('ai/') else path.split('-')[0]
            nums = []
            for mm in re.finditer(r'href="/ai/%s(-ep-(\d+))?"' % re.escape(series), html):
                n = int(mm.group(2)) if mm.group(2) else 1
                if n not in nums:
                    nums.append(n)
            nums.sort()
            for n in nums:
                ep_id = 'ai/%s' % series if n == 1 else 'ai/%s-ep-%s' % (series, n)
                episodes.append('%s$%s' % ('第%s集' % n, ep_id))
        if not episodes:
            episodes.append('播放$%s' % nid)
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
            'vod_play_url': '#'.join(episodes),
            'stills': [cover] if cover else [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        url = BASE + '/search?' + urllib.parse.urlencode({'q': key or ''})
        html = _http_get(url)
        out = []
        seen = set()
        for mm in re.finditer(r'<a[^>]*href="/(av|ai)/([^"]+)"[^>]*aria-label="([^"]+)"', html or ''):
            vid = '%s/%s' % (mm.group(1), mm.group(2))
            if vid in seen:
                continue
            title = _unescape(mm.group(3).strip())
            if not title:
                continue
            seen.add(vid)
            tail = html[mm.end():mm.end() + 4000]
            cover = ''
            m2 = re.search(r'<img[^>]*src="(https://cdn\.pachub\.net/[^"]+)"', tail)
            if m2:
                cover = m2.group(1)
            remark = ''
            m2 = re.search(r'>(\d+:\d+(?::\d+)?)<', tail)
            if m2:
                remark = m2.group(1)
            out.append({
                'vod_id': vid,
                'vod_name': title,
                'vod_pic': cover,
                'vod_remarks': remark,
            })
        return {'list': out, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        header = {'User-Agent': UA, 'Referer': BASE}
        if raw.startswith('http'):
            url = raw
        elif raw.startswith('/'):
            url = BASE + raw
        else:
            url = BASE + '/' + raw
        html = _http_get(url)
        endpoint = ''
        m = re.search(r'apiEndpoint(?:&quot;|"):\[0,(?:&quot;|")(/api/[^&"]+/stream)', html or '')
        if m:
            endpoint = m.group(1)
        if not endpoint:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        status, text = _http_post_json(BASE + endpoint, url)
        if status != 200:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        try:
            body = json.loads(text or '{}')
        except Exception:
            body = {}
        raw_url = _text(body, ['m3u8Url'])
        if not raw_url:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        m3u8 = _direct_url(raw_url)
        header['Referer'] = url
        return {'parse': 0, 'playUrl': m3u8, 'url': m3u8, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', '']

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
