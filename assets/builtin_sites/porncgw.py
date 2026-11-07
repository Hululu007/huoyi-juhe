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


BASE = 'https://porncgw.com'
UA = 'Mozilla/5.0 (Linux; Android 14; HarmonyOS; HUAWEI) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36'

CATS = [
    ('recommend', '推荐吃瓜', '/recommend/'),
    ('today', '今日吃瓜', '/today/'),
    ('hot', '热门爆料', '/hot/'),
    ('hot-xsxy', '学生校园', '/hot/xsxy/'),
    ('hot-whhl', '网红黑料', '/hot/whhl/'),
    ('hot-snsf', '熟女少妇', '/hot/snsf/'),
    ('hot-cgbd', '吃瓜榜单', '/hot/cgbd/'),
    ('shrd', '社会热点', '/shrd/'),
    ('shrd-ylbg', '娱乐八卦', '/shrd/ylbg/'),
    ('shrd-wybl', '网友爆料', '/shrd/wybl/'),
    ('ent', '热门短片', '/entertainment/'),
    ('ent-cgtq', '出轨偷情', '/entertainment/cgtq/'),
    ('ent-zplc', '自拍流出', '/entertainment/zplc/'),
    ('door', '门事件', '/door/'),
    ('door-jiudian', '酒店', '/door/jiudian/'),
    ('door-chezhen', '车震', '/door/chezhen/'),
    ('ai', 'AI成人', '/ai/'),
    ('ai-aidj', 'AI短剧', '/ai/aidj/'),
    ('ai-AImj', 'AI漫剧', '/ai/AImj/'),
    ('long-video', '长视频', '/long-video/'),
    ('ntxl', '女同系列', '/ntxl/'),
    ('omxl', '欧美系列', '/omxl/'),
    ('jqyy', '剧情演绎', '/jqyy/'),
    ('yzcm', '亚洲传媒', '/yzcm/'),
    ('list', '短视频', '/list'),
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


def _unescape(s):
    return (s or '').replace('\\u0026', '&').replace('\\/', '/').replace('&amp;', '&').replace('&quot;', '"').replace('&#39;', "'").replace('&lt;', '<').replace('&gt;', '>')


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


class Spider(BaseSpider):
    def getName(self):
        return 'Porn吃瓜网'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cards(self, html):
        out = []
        seen = set()
        for mm in re.finditer(r'(?s)<article[^>]*?data-title="([^"]*)"[^>]*?data-time="([^"]*)"[^>]*?>(.*?)</article>', html or ''):
            title = _unescape(mm.group(1).strip())
            if not title:
                continue
            body = mm.group(3)
            m = re.search(r'href="/(video|drama)/(\d+)/"', body)
            if not m:
                continue
            vid = '%s/%s' % (m.group(1), m.group(2))
            if vid in seen:
                continue
            seen.add(vid)
            cover = ''
            m2 = re.search(r'data-src="(https://[^"]+)"', body)
            if m2:
                cover = m2.group(1)
            remark = mm.group(2).strip()
            if m.group(1) == 'drama':
                m2 = re.search(r'更新至(\d+)集', body)
                if m2:
                    remark = '更新至%s集' % m2.group(1)
            out.append({
                'vod_id': vid,
                'vod_name': title,
                'vod_pic': cover,
                'vod_remarks': remark,
            })
        return out

    def _catalog(self, tid, pg):
        path = ''
        for c in CATS:
            if c[0] == tid:
                path = c[2]
                break
        if not path:
            return []
        if pg <= 1:
            url = BASE + path
        elif path.endswith('/'):
            url = '%s%s%s/' % (BASE, path, pg)
        else:
            url = '%s%s/%s/' % (BASE, path, pg)
        html = _http_get(url)
        return self._cards(html)

    def homeContent(self, filter=''):
        items = self._catalog('recommend', 1)
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name, _ in CATS],
            'list': items,
        }

    def homeVideoContent(self):
        items = self._catalog('recommend', 1)
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
        else:
            url = BASE + '/' + nid.lstrip('/')
        html = _http_get(url)
        if not html:
            return {'list': []}
        title = ''
        m = re.search(r'<meta property="og:title"[^>]*content="([^"]+)"', html)
        if m:
            title = _unescape(m.group(1).strip())
        if not title:
            m = re.search(r'(?s)<title[^>]*>(.*?)</title>', html)
            if m:
                title = _unescape(_clean(m.group(1)))
        if title.endswith(' - porn吃瓜网'):
            title = title[:-len(' - porn吃瓜网')].strip()
        cover = ''
        m = re.search(r'<meta property="og:image"[^>]*content="([^"]+)"', html)
        if m:
            cover = _unescape(m.group(1).strip())
        synopsis = ''
        m = re.search(r'<meta name="description"[^>]*content="([^"]+)"', html)
        if m:
            synopsis = _unescape(m.group(1).strip())
        if not title:
            return {'list': []}
        episodes = []
        if nid.startswith('drama/'):
            id_part = nid[len('drama/'):].strip('/')
            nums = []
            for mm in re.finditer(r'href="/drama/%s/(\d+)/"' % re.escape(id_part), html):
                try:
                    n = int(mm.group(1))
                except Exception:
                    continue
                if n not in nums:
                    nums.append(n)
            nums.sort()
            if not nums:
                return {'list': []}
            for n in nums:
                vid = 'drama/%s/%s' % (id_part, n)
                episodes.append('第%s集$%s' % (n, vid))
        else:
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
        enc = urllib.parse.quote((key or '').strip(), safe='')
        items = self._cards(_http_get('%s/search/%s/' % (BASE, enc)))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        header = {'User-Agent': UA, 'Referer': BASE}
        if raw.startswith('http'):
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        html = _http_get(BASE + '/' + raw.lstrip('/'))
        m3u8 = ''
        m = re.search(r'"videoSrc":"([^"]+)"', html or '')
        if m:
            m3u8 = _unescape(m.group(1))
        if not m3u8:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
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
