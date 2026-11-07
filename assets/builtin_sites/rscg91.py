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


BASE = 'https://jcyh-gvz-nigo.obbplmm26y102.cc'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

CATS = [
    ('307', '童颜巨乳'),
    ('305', '日本无码'),
    ('306', '中文字幕'),
    ('301', '精品推荐'),
    ('315', '日本片商'),
    ('313', '丝袜OL'),
    ('314', '自拍偷拍'),
    ('312', '卡通动漫'),
    ('311', '三级伦理'),
    ('309', '强奸乱伦'),
    ('308', '性感人妻'),
    ('302', '国产精品'),
    ('317', '网曝系列'),
    ('318', '麻豆传媒'),
    ('304', '日本有码'),
    ('320', '国产乱伦'),
    ('324', '探花嫖娼'),
    ('323', '国产人妻'),
    ('321', '国产丝袜'),
    ('303', '主播秀色'),
    ('401', 'AV解说'),
    ('402', 'cosplay'),
    ('413', '抖阴视频'),
    ('412', '门事件'),
    ('411', '素人搭讪'),
    ('410', '国产传媒'),
    ('409', 'VR视角'),
    ('408', '三级伦理'),
    ('407', '探花系列'),
    ('406', '网红主播'),
    ('405', '激情动漫'),
    ('404', '自拍偷拍'),
    ('403', 'SWAG'),
    ('201', '国产视频'),
    ('202', '中文字幕'),
    ('203', '国产传媒'),
    ('204', '日本有码'),
    ('205', '日本无码'),
    ('206', '欧美无码'),
    ('207', '强奸乱伦'),
    ('208', '制服诱惑'),
    ('209', '国产主播'),
    ('210', '激情动漫'),
    ('211', '明星换脸'),
    ('212', '抖阴视频'),
    ('213', '女优明星'),
    ('214', '网曝黑料'),
    ('215', '伦理三级'),
    ('216', 'AV解说'),
    ('217', 'SM调教'),
    ('218', '萝莉少女'),
    ('221', '网红头条'),
    ('224', 'VR视角'),
    ('520', '女同性恋'),
    ('521', 'VR视角'),
    ('518', '剧情动漫'),
    ('519', 'SM调教'),
    ('516', '重口激情'),
    ('517', '三级伦理'),
    ('514', '女优明星'),
    ('511', 'AV解说'),
    ('513', '强奸乱伦'),
    ('510', '中文字幕'),
    ('509', '日韩无码'),
    ('506', '抖阴短片'),
    ('507', '传媒剧情'),
    ('504', '偷拍偷窥'),
    ('505', '网曝吃瓜'),
    ('501', '国产自拍'),
    ('502', '主播诱惑'),
    ('503', '探花约炮'),
]


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _http_get(url, timeout=25):
    h = {'User-Agent': UA, 'Referer': BASE + '/mmmm/'}
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
        time.sleep(2)
    return ''


def _unescape(s):
    out = (s or '').replace('&amp;', '&').replace('&quot;', '"').replace('&#39;', "'").replace('&lt;', '<').replace('&gt;', '>').replace('&nbsp;', ' ').replace('\\/', '/')
    def repl(m):
        try:
            return chr(int(m.group(1)))
        except Exception:
            return m.group(0)
    return re.sub(r'&#(\d+);', repl, out)


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
        return '91人兽吃瓜'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cats(self):
        html = _http_get(BASE + '/mmmm/')
        out = []
        seen = set()
        for mm in re.finditer(r'href="/vodtype/(\d+)/" title="([^"]+)"', html or ''):
            cid = mm.group(1)
            name = _unescape(mm.group(2).strip())
            if name and cid not in seen:
                seen.add(cid)
                out.append((cid, name))
        return out or list(CATS)

    def _cards(self, html):
        out = []
        seen = set()
        for mm in re.finditer(r'(?s)<a href="/voddetail/(\d+)/" title="([^"]+)" data-original="([^"]+)"', html or ''):
            vid = mm.group(1)
            if vid in seen:
                continue
            title = _unescape(mm.group(2).strip())
            if not title:
                continue
            seen.add(vid)
            tail = html[mm.end():mm.end() + 1500]
            remark = ''
            m2 = re.search(r'pic-text-top[^>]*>([^<]+)<', tail)
            if m2:
                remark = _unescape(m2.group(1).strip())
            out.append({
                'vod_id': vid,
                'vod_name': title,
                'vod_pic': mm.group(3).strip(),
                'vod_remarks': remark,
            })
        return out

    def _catalog(self, tid, pg):
        if pg <= 1:
            url = '%s/vodtype/%s/' % (BASE, tid)
        else:
            url = '%s/vodtype/%s-%s.html' % (BASE, tid, pg)
        return self._cards(_http_get(url))

    def homeContent(self, filter=''):
        cats = self._cats()
        items = []
        if cats:
            items = self._catalog(cats[0][0], 1)
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in cats],
            'list': items,
        }

    def homeVideoContent(self):
        cats = self._cats()
        items = []
        if cats:
            items = self._catalog(cats[0][0], 1)
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        items = self._catalog(tid, pg)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        vid = nid.strip().lstrip('/').replace('voddetail/', '').rstrip('/')
        html = _http_get('%s/voddetail/%s/' % (BASE, vid))
        if not html:
            return {'list': []}
        title = ''
        m = re.search(r'(?s)<h1[^>]*>(.*?)</h1>', html)
        if m:
            title = _unescape(_clean(m.group(1)))
        cover = ''
        m = re.search(r'(?s)stui-content__thumb.*?<img[^>]*data-original="([^"]+)"', html)
        if m:
            cover = m.group(1)
        synopsis = ''
        m = re.search(r'(?s)<span class="left">简介：(.*?)</span>', html)
        if m:
            synopsis = _unescape(_clean(m.group(1)))
        genre = ''
        for mm in re.finditer(r'(?s)<p class="data">(.*?)</p>', html):
            line = _unescape(_clean(mm.group(1)))
            if line.startswith('类型：'):
                genre = line[len('类型：'):].strip()
                break
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
            'type_name': genre,
            'vod_tag': genre,
            'vod_play_from': '在线播放',
            'vod_play_url': '立即播放$%s-1-1' % vid,
            'stills': [cover] if cover else [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        enc = urllib.parse.quote(key or '')
        items = self._cards(_http_get('%s/vodsearch/%s-------------/' % (BASE, enc)))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        if raw.startswith('http'):
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        vid = raw.strip().lstrip('/').replace('vodplay/', '').rstrip('/')
        html = _http_get('%s/vodplay/%s/' % (BASE, vid))
        m3u8 = ''
        m = re.search(r'(?s)player_aaaa=.*?"url":"([^"]+)"', html or '')
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
