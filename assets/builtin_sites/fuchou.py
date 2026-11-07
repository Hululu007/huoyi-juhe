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


BASE = 'https://kkb1.sixnicefczlm.cc'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

CATS = [
    ('1', '热播片库'),
    ('6', '禁忌母子'),
    ('7', '兄弟姐妹'),
    ('8', '爱上嫂子'),
    ('9', '狂操小姨'),
    ('10', '换夫换妻'),
    ('11', '淫荡儿媳'),
    ('12', '爷爷奶奶'),
    ('20', '乱伦精选'),
    ('2', '精品资源'),
    ('13', 'JK少女'),
    ('14', '黑丝白丝'),
    ('15', '女仆'),
    ('16', 'cosplay'),
    ('21', 'OL制服'),
    ('22', '旗袍'),
    ('23', '空姐制服'),
    ('24', '护士医生'),
    ('3', '特色仓库'),
    ('25', '学生少女'),
    ('26', '技师风采'),
    ('27', '熟女少妇'),
    ('28', '国产热播'),
    ('29', '反差母狗'),
    ('30', '美脚丝足'),
    ('31', '情侣自拍'),
    ('32', '私房俱乐部'),
    ('4', '网曝黑料'),
    ('33', '偷情约炮'),
    ('34', '真实偷拍'),
    ('35', '高潮喷水'),
    ('36', '强奸迷奸'),
    ('37', '户外露出'),
    ('38', 'SM调教'),
    ('39', '情趣内衣'),
    ('40', '精选探花'),
    ('41', '国产剧情'),
    ('42', '网曝门事件'),
    ('43', '校园猛料'),
    ('44', '网红流出'),
    ('45', '明星黑料'),
    ('46', '裸贷肉偿'),
    ('47', '婚闹恶俗'),
    ('48', '抓奸名场面'),
    ('49', '男同女同'),
    ('50', '国产传媒'),
    ('51', '人兽性交'),
    ('52', 'SM性虐'),
    ('53', '人妖伪娘'),
    ('54', '孕妇内射'),
    ('55', '吃屎喝尿'),
    ('56', '扩阴拳交'),
    ('57', '阳具巨物'),
    ('58', '动漫'),
    ('59', '必射精选'),
    ('60', '日本中文'),
    ('61', '无码流出'),
    ('62', '网红主播'),
    ('63', '主播网黄'),
    ('64', '国产AV'),
    ('65', '车震直播'),
    ('66', '自慰诱惑'),
    ('67', '欧美重口'),
]

CARD_RE = re.compile(r'<a class="dx-card" href="/index\.php/vod/play/id/(\d+)/sid/1/nid/1\.html"[^>]*title="([^"]*)".*?<img src="([^"]+)"', re.S)
CAT_RE = re.compile(r'<a href="/index\.php/vod/type/id/(\d+)\.html"[^>]*>([^<]+)</a>')
TITLE_RE = re.compile(r'<title[^>]*>(.*?)</title>', re.S)
DESC_RE = re.compile(r'<meta name="description"[^>]*content="([^"]+)"')
PLAYER_RE = re.compile(r'player_(?:data|aaaa)=.*?"url":"([^"]+)"', re.S)


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _unescape(s):
    if not s:
        return ''
    return _html.unescape(s).replace('\\/', '/').strip()


def _http_get(url, referer=None, timeout=25):
    h = {'User-Agent': UA, 'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8', 'Accept-Language': 'zh-CN,zh;q=0.9', 'Accept-Encoding': 'gzip, deflate'}
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


def _fix_url(raw):
    u = (raw or '').strip()
    if not u:
        return ''
    if u.startswith('//'):
        return 'https:' + u
    if u.startswith('/'):
        return BASE + u
    return u


def _parse_cards(html):
    out = []
    seen = set()
    for m in CARD_RE.finditer(html or ''):
        vid = m.group(1).strip()
        if not vid or vid in seen:
            continue
        title = _unescape(m.group(2))
        if not title:
            continue
        seen.add(vid)
        out.append({
            'vod_id': vid,
            'vod_name': title,
            'vod_pic': _fix_url(m.group(3)),
            'vod_remarks': '',
        })
    return out


def _parse_categories(html):
    out = []
    seen = set()
    for m in CAT_RE.finditer(html or ''):
        cid = m.group(1)
        name = m.group(2).strip()
        if not name or '查看' in name or '67E5' in name or cid in seen:
            continue
        seen.add(cid)
        out.append((cid, name))
    return out


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
        return '妇愁者联盟'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cats(self):
        cats = _parse_categories(_http_get(BASE + '/', referer=BASE + '/'))
        return cats or list(CATS)

    def _catalog(self, tid, pg):
        if pg <= 1:
            url = '%s/index.php/vod/type/id/%s.html' % (BASE, tid)
        else:
            url = '%s/index.php/vod/type/id/%s/page/%s.html' % (BASE, tid, pg)
        return _parse_cards(_http_get(url, referer=BASE + '/'))

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
        nid = _norm_id(ids).strip().lstrip('/')
        if not nid:
            return {'list': []}
        play_path = '/index.php/vod/play/id/%s/sid/1/nid/1.html' % nid
        html = _http_get(BASE + play_path, referer=BASE + '/')
        if not html:
            return {'list': []}
        tm = TITLE_RE.search(html)
        title = _unescape(tm.group(1)) if tm else ''
        if title.endswith(' - 妇愁者联盟'):
            title = title[:-len(' - 妇愁者联盟')]
        if not title:
            return {'list': []}
        dm = DESC_RE.search(html)
        synopsis = _unescape(dm.group(1)) if dm else ''
        ep_re = re.compile(r'/index\.php/vod/play/id/%s/sid/1/nid/(\d+)\.html' % re.escape(nid))
        eps = []
        seen = set()
        for m in ep_re.finditer(html):
            n = m.group(1)
            if n in seen:
                continue
            seen.add(n)
            href = '/index.php/vod/play/id/%s/sid/1/nid/%s.html' % (nid, n)
            eps.append('第%s集$fuchou:%s' % (n, _fix_url(href)))
        if not eps:
            eps = ['第1集$fuchou:%s' % _fix_url(play_path)]
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': '',
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': '',
            'vod_year': '',
            'vod_area': '',
            'vod_content': synopsis,
            'type_name': '',
            'vod_tag': '',
            'vod_play_from': '在线播放',
            'vod_play_url': '#'.join(eps),
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        url = '%s/index.php/vod/search.html?wd=%s' % (BASE, urllib.parse.quote(key or ''))
        items = _parse_cards(_http_get(url, referer=BASE + '/'))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        if raw.startswith('fuchou:'):
            raw = raw[len('fuchou:'):]
        url = _fix_url(raw)
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        m3u8 = ''
        if '/vod/play/' in url:
            path = url[url.find('/index.php'):] if '/index.php' in url else url
            html = _http_get(BASE + path if path.startswith('/') else path, referer=BASE + '/')
            if html:
                m = PLAYER_RE.search(html)
                if m:
                    m3u8 = _unescape(m.group(1))
        elif url.startswith('http') and url.endswith('.m3u8'):
            m3u8 = url
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
