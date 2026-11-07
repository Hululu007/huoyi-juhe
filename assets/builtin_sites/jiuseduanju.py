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

BASE = 'https://www.jiuseai.top/aa'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

CATS = [
    ('2', '精品推荐'),
    ('3', '国产精品'),
    ('4', '主播秀色'),
    ('5', '日本无码'),
    ('6', '欧美情色'),
    ('7', '自拍偷拍'),
    ('8', '日本片商'),
    ('9', '剧情介绍'),
    ('10', '网曝系列'),
    ('11', '同性恋'),
    ('12', '探花嫖娼'),
    ('13', '国产人妻'),
    ('14', '国产SM'),
    ('15', '国产丝袜'),
    ('16', '麻豆传媒'),
    ('17', '国产乱伦'),
    ('62', '国产主播'),
    ('63', '欧美劲爆'),
    ('64', '自拍偷拍'),
    ('65', '群P换妻'),
    ('66', '吃瓜黑料'),
    ('67', '酒店探花'),
    ('68', '直播裸聊'),
    ('69', '反差母狗'),
    ('70', '国产传媒'),
    ('71', '野战车震'),
    ('72', 'SM调教'),
    ('73', '家庭乱伦'),
    ('74', '百合女同'),
    ('75', '学生空姐'),
    ('76', '撸管必看'),
    ('77', '偷情少妇'),
    ('44', '偷拍自拍'),
    ('45', '国产大制作'),
    ('46', '乱伦毁三观'),
    ('47', '主播女网红'),
    ('48', '黑料网曝'),
    ('49', '淫乱学生妹'),
    ('50', 'FC2'),
    ('51', '会所技师'),
    ('52', '国产推荐'),
    ('53', '探花约炮'),
    ('54', '韩国直播'),
    ('55', '国产直播'),
    ('56', '淫妻绿帽'),
    ('57', '重口猎奇'),
    ('58', '东京热'),
    ('59', '一本道'),
    ('19', '精品推荐'),
    ('20', '国产色情'),
    ('21', '主播直播'),
    ('22', '自拍偷拍'),
    ('23', 'Cosplay'),
    ('24', '素人自拍'),
    ('25', '台湾辣妹'),
    ('26', '韩国御姐'),
    ('27', '唯美港姐'),
    ('28', '剧情介绍'),
    ('29', '多人多P'),
    ('30', '91探花'),
    ('31', '网红流出'),
    ('32', '野外露出'),
    ('33', '古装扮演'),
    ('34', '女优系列'),
    ('35', '可爱学生'),
    ('36', '风情旗袍'),
    ('37', '兽耳系列'),
    ('38', '瑜伽裤'),
    ('39', '闷骚护士'),
    ('40', '网曝门'),
    ('41', '传媒出品'),
    ('42', '女同性恋'),
]


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _http_get(url, referer=None, timeout=25):
    h = {'User-Agent': UA, 'Referer': BASE + '/'}
    if referer:
        h['Referer'] = referer
    for _ in range(3):
        if _HAS_REQ:
            try:
                r = requests.get(url, headers=h, timeout=timeout)
                if r.status_code == 200 and r.text and r.text.strip():
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
                txt = data.decode('utf-8', 'replace')
                if txt.strip():
                    return txt
        except urllib.error.HTTPError as e:
            try:
                txt = e.read().decode('utf-8', 'ignore')
                if txt.strip():
                    return txt
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


def _unescape(s):
    return _html.unescape((s or '').replace('&nbsp;', ' ')).strip()


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


def _cards(html):
    out = []
    seen = set()
    pat = re.compile(r'(?s)<a href="/aa/index\.php/vod/play/id/(\d+)/sid/1/nid/1\.html"[^>]*>\s*<img[^>]*data-original="([^"]+)"')
    title_re = re.compile(r'(?s)<h3 class="video-title">.*?<text>([^<]+)</text>')
    for m in pat.finditer(html or ''):
        vid = m.group(1)
        if vid in seen:
            continue
        cover = m.group(2).strip()
        tail = html[m.end():m.end() + 3000]
        tm = title_re.search(tail)
        title = _unescape(tm.group(1).strip()) if tm else ''
        if not title:
            continue
        seen.add(vid)
        out.append({'vod_id': vid, 'vod_name': title, 'vod_pic': cover, 'vod_remarks': ''})
    return out


def _parse_categories(html):
    out = []
    seen = set()
    pat = re.compile(r'href="/aa/index\.php/vod/type/id/(\d+)\.html"[^>]*>\s*<text>([^<]+)</text>')
    for m in pat.finditer(html or ''):
        cid = m.group(1)
        name = _unescape(m.group(2).strip())
        if not name or name == '更多' or cid in seen:
            continue
        seen.add(cid)
        out.append((cid, name))
    return out


def _parse_player_aaaa(html):
    start = (html or '').find('player_aaaa=')
    if start < 0:
        return None
    rest = html[start + len('player_aaaa='):]
    brace = rest.find('{')
    if brace < 0:
        return None
    depth = 0
    end = None
    for i in range(brace, len(rest)):
        ch = rest[i]
        if ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                end = i + 1
                break
    if end is None:
        return None
    try:
        return json.loads(rest[brace:end])
    except Exception:
        return None


def _play_page_url(video_id):
    s = (video_id or '').strip()
    if '/vod/play/id/' in s:
        pos = s.find('/vod/play/id/') + len('/vod/play/id/')
        rest = s[pos:]
        digits = ''
        for ch in rest:
            if ch.isdigit():
                digits += ch
            else:
                break
        vid = digits or s
    else:
        vid = s.replace('/aa/index.php/vod/play/id/', '').replace('/vod/play/id/', '').rstrip('.html').rstrip('/')
        vid = vid.split('/sid/')[0]
    return '%s/index.php/vod/play/id/%s/sid/1/nid/1.html' % (BASE, vid)


class Spider(BaseSpider):
    def getName(self):
        return '九色短剧'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cats(self):
        html = _http_get(BASE + '/index.php/index/index.html', referer=BASE + '/')
        lst = _parse_categories(html)
        return lst or list(CATS)

    def homeContent(self, filter=''):
        cats = self._cats()
        tid = cats[0][0] if cats else '2'
        items = _cards(_http_get('%s/index.php/vod/type/id/%s.html' % (BASE, tid), referer=BASE + '/'))
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in cats],
            'list': items,
        }

    def homeVideoContent(self):
        cats = self._cats()
        tid = cats[0][0] if cats else '2'
        items = _cards(_http_get('%s/index.php/vod/type/id/%s.html' % (BASE, tid), referer=BASE + '/'))
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        tid = _norm_id(tid)
        if pg <= 1:
            url = '%s/index.php/vod/type/id/%s.html' % (BASE, tid)
        else:
            url = '%s/index.php/vod/type/id/%s/page/%d.html' % (BASE, tid, pg)
        html = _http_get(url, referer=BASE + '/')
        items = _cards(html)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        url = _play_page_url(nid)
        html = _http_get(url, referer=BASE + '/')
        if not html:
            return {'list': []}
        player = _parse_player_aaaa(html)
        if not player:
            return {'list': []}
        vod = player.get('vod_data') if isinstance(player, dict) else None
        if not isinstance(vod, dict):
            vod = {}
        title = vod.get('vod_name') or ''
        if not title:
            return {'list': []}
        genre = vod.get('vod_class') or ''
        m = re.search(r'data-original="([^"]*?/upload/vod/[^"]+)"', html)
        cover = m.group(1) if m else ''
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': vod.get('vod_actor') or '',
            'vod_director': vod.get('vod_director') or '',
            'vod_remarks': '',
            'vod_year': '',
            'vod_area': '',
            'vod_content': '',
            'type_name': genre,
            'vod_tag': genre,
            'vod_play_from': '在线播放',
            'vod_play_url': '立即播放$%s' % url,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        url = '%s/index.php/vod/search.html?wd=%s' % (BASE, urllib.parse.quote(str(key or '')))
        html = _http_get(url, referer=BASE + '/')
        return {'list': _cards(html), 'page': _norm_pg(pg), 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        header = {'User-Agent': UA}
        if raw.endswith('.m3u8'):
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        url = _play_page_url(raw.split('$')[-1].strip())
        html = _http_get(url, referer=BASE + '/')
        player = _parse_player_aaaa(html) if html else None
        stream = ''
        if isinstance(player, dict):
            stream = player.get('url') or ''
        if stream:
            header['Referer'] = url
            return {'parse': 0, 'playUrl': stream, 'url': stream, 'header': header}
        return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', '']

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
