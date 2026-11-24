import gzip
import html as _html
import re
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

try:
    from base.spider import BaseSpider
except Exception:
    class BaseSpider:
        def init(self, extend=""):
            pass


BASE = 'https://qipaosp.com'
CDN = 'https://dfdf.tjacq.com'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

RE_ITEM = re.compile(r'<li class="stui-vodlist__item[^>]*>([\s\S]*?)</li>', re.S)
RE_HREF = re.compile(r'href="/video/(\d+)/"')
RE_TITLE = re.compile(r'title="([^"]+)"')
RE_IMG = re.compile(r'data-original="([^"]+)"')
RE_SRC = re.compile(r'<img[^>]+src="([^"]+)"')
RE_STRONG = re.compile(r'<strong>([^<]+)</strong>')
RE_CAT = re.compile(r'href="/category/(cate\d+)/"[^>]*>([^<]+)</a>')
RE_OGIMG = re.compile(r'property="og:image" content="([^"]+)"')
RE_DESC = re.compile(r'name="description" content="([^"]+)"')
RE_M3U8 = re.compile(r'data-url="([^"]+\.m3u8[^"]*)"')
BLOCKED_CAT_IDS = {'cate36'}
FLAG_WORDS = ('loli', 'lolita', '幼女', '幼齿', '初中生', '小学生', '未成年', '未满', '萝莉', '童颜', '幼态', '处女', '小萝莉')


def _blocked(text):
    low = str(text or '').lower()
    return any(w.lower() in low for w in FLAG_WORDS)


def _http_get(url, referer=None, timeout=25):
    hdr = {
        'User-Agent': UA,
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9',
        'Accept-Encoding': 'gzip, deflate',
    }
    if referer:
        hdr['Referer'] = referer
    for attempt in range(3):
        try:
            req = urllib.request.Request(url, headers=hdr)
            with urllib.request.urlopen(req, timeout=timeout, context=CTX) as resp:
                data = resp.read()
                enc = (resp.headers.get('Content-Encoding') or '').lower()
            if enc == 'gzip' or data[:2] == b'\x1f\x8b':
                try:
                    data = gzip.decompress(data)
                except Exception:
                    pass
            for cs in ('utf-8', 'gbk', 'gb18030'):
                try:
                    return data.decode(cs)
                except Exception:
                    continue
            return data.decode('utf-8', 'replace')
        except urllib.error.HTTPError as e:
            try:
                return e.read().decode('utf-8', 'ignore')
            except Exception:
                return ''
        except Exception:
            if attempt < 2:
                try:
                    time.sleep(1)
                except Exception:
                    pass
    return ''


def _txt(s):
    if not s:
        return ''
    s = re.sub(r'<[^>]+>', ' ', s)
    s = _html.unescape(s)
    return re.sub(r'\s+', ' ', s).strip()


def _parse_cards(html):
    out = []
    if not html:
        return out
    seen = set()
    for m in RE_ITEM.finditer(html):
        block = m.group(1)
        hm = RE_HREF.search(block)
        if not hm:
            continue
        vid = hm.group(1)
        if vid in seen:
            continue
        seen.add(vid)
        tm = RE_TITLE.search(block)
        name = _txt(tm.group(1)) if tm else ''
        if not name:
            hm2 = re.search(r'stui-vodlist__title">[\s\S]*?>([^<]+)<', block)
            name = _txt(hm2.group(1)) if hm2 else ''
        if not name:
            continue
        if _blocked(name):
            continue
        im = RE_IMG.search(block)
        pic = im.group(1) if im else ''
        if not pic:
            sm = RE_SRC.search(block)
            pic = sm.group(1) if sm else ''
        if pic and 'loading.jpg' in pic:
            pic = ''
        if pic.startswith('//'):
            pic = 'https:' + pic
        sm2 = RE_STRONG.search(block)
        remarks = _txt(sm2.group(1)) if sm2 else ''
        out.append({'vod_id': vid, 'vod_name': name, 'vod_pic': pic, 'vod_remarks': remarks})
    return out


def _parse_cats(html):
    out = []
    seen = set()
    if not html:
        return out
    for tid, name in RE_CAT.findall(html):
        if tid in seen:
            continue
        seen.add(tid)
        name = _txt(name)
        if not name:
            continue
        if tid in BLOCKED_CAT_IDS or _blocked(name):
            continue
        out.append({'type_id': tid, 'type_name': name})
    return out


def _norm_id(ids):
    if isinstance(ids, (list, tuple)):
        ids = ids[0] if ids else ''
    s = str(ids or '').strip()
    m = re.search(r'(\d{10,})', s)
    return m.group(1) if m else s


def _norm_pg(pg):
    try:
        pg = int(pg)
    except Exception:
        pg = 1
    return pg if pg >= 1 else 1


class Spider(BaseSpider):

    def getName(self):
        return '🔞气泡视频'

    def getDependence(self):
        return []

    def init(self, extend=None):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=False):
        html = _http_get(BASE + '/', referer=BASE + '/')
        cats = _parse_cats(html)
        items = _parse_cards(html)
        return {'class': cats, 'filters': {}, 'list': items}

    def homeVideoContent(self):
        items = _parse_cards(_http_get(BASE + '/', referer=BASE + '/'))
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        tid = str(tid or '').strip()
        pg = _norm_pg(pg)
        if tid in BLOCKED_CAT_IDS:
            return {'list': [], 'page': pg, 'pagecount': 0, 'total': 0}
        if pg <= 1:
            path = '/category/%s/' % tid
        else:
            path = '/category/%s/%d/' % (tid, pg)
        items = _parse_cards(_http_get(BASE + path, referer=BASE + '/'))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        vid = _norm_id(ids)
        if not vid:
            return {'list': []}
        html = _http_get('%s/video/%s/' % (BASE, vid), referer=BASE + '/')
        if not html:
            return {'list': []}
        title = ''
        tm = re.search(r'<title[^>]*>([\s\S]*?)</title>', html, re.S)
        if tm:
            title = _txt(tm.group(1))
            if title.endswith(' - 气泡视频'):
                title = title[:-len(' - 气泡视频')].strip()
        if not title:
            return {'list': []}
        if _blocked(title):
            return {'list': []}
        im = RE_OGIMG.search(html)
        pic = im.group(1) if im else ''
        dm = RE_DESC.search(html)
        content = _txt(dm.group(1)) if dm else ''
        play_url = '正片$qipaosp:%s' % vid
        return {'list': [{
            'vod_id': vid,
            'vod_name': title,
            'vod_pic': pic,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': '',
            'vod_year': '',
            'vod_area': '',
            'vod_content': content,
            'type_name': '',
            'vod_play_from': '在线播放',
            'vod_play_url': play_url,
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        kw = urllib.parse.quote(str(key or '').strip())
        if pg <= 1:
            path = '/search/%s/' % kw
        else:
            path = '/search/%s/%d/' % (kw, pg)
        items = _parse_cards(_http_get(BASE + path, referer=BASE + '/'))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        vid = _norm_id(id)
        header = {'User-Agent': UA, 'Referer': '%s/video/%s/' % (BASE, vid)}
        url = ''
        if vid:
            html = _http_get('%s/video/%s/' % (BASE, vid), referer=BASE + '/')
            mm = RE_M3U8.search(html or '')
            if mm:
                raw = mm.group(1).replace('&amp;', '&')
                if raw.startswith('http'):
                    url = raw
                elif raw.startswith('//'):
                    url = 'https:' + raw
                elif raw.startswith('/'):
                    url = CDN + raw
                else:
                    url = CDN + '/' + raw
        return {'parse': 0, 'playUrl': url, 'url': url, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', b'', {}]

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action, params=None):
        return None
