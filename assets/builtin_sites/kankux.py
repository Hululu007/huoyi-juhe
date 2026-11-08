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


BASE = 'https://kankux.com'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

CATS = [
    ('1', '国产厂牌'), ('2', 'SM调教'), ('3', '强奸迷奸'), ('4', '乱伦'),
    ('5', '丝袜制服'), ('6', '网曝黑料'), ('7', '主播网红'), ('8', '自拍偷拍'),
    ('9', '素人特摄'), ('10', '无码高清'), ('11', '经典有码'), ('12', '性感网红'),
    ('13', '激情H漫'), ('14', '学生萝莉'), ('15', '伦理三级'), ('16', '日韩精选'),
    ('17', '国产精选'), ('18', '欧美精选'), ('19', 'VR专区'), ('20', '中文字幕'),
    ('21', '口交自慰'), ('22', '3D'), ('23', '群交多P'), ('24', '重口调教'),
    ('25', 'AI换脸'), ('60', '91视频'), ('61', '麻豆视频'), ('62', '成人头条'),
    ('63', '蜜桃传媒'), ('64', '皇家华人'), ('65', '星空传媒'), ('66', '精东影业'),
    ('67', '海角社区'), ('68', '91制片厂'), ('69', '乌鸦传媒'), ('70', '兔子先生'),
    ('71', '杏吧原创'), ('72', '玩偶姐姐'), ('73', 'mini传媒'), ('74', '天美传媒'),
    ('75', '大象传媒'), ('76', '萝莉社'), ('77', 'PsychoPorn'), ('78', '糖心Vlog'),
    ('79', '性视界'), ('80', '日韩精品'), ('81', '国产主播'), ('82', '强奸乱伦'),
    ('83', '人妻系列'), ('85', '巨乳尤物'), ('86', '自慰系列'), ('88', '群P换妻'),
    ('89', '教师学生'), ('90', '制服诱惑'), ('91', '日韩无码'), ('92', '口交视频'),
    ('93', 'AV明星'), ('94', '成人动漫'), ('95', '颜值正义'), ('96', '颜射系列'),
    ('97', '吃瓜黑料'), ('98', 'SM重味'), ('99', '直播裸聊'), ('100', '酒店探花'),
    ('101', '国产传媒'), ('102', '欧美劲爆'), ('103', '反差母狗'), ('104', 'AV解说'),
    ('105', '熟女少妇'), ('107', '伦理影片'), ('108', '撸管必看'), ('109', '学生空姐'),
    ('111', '野战车震'), ('112', '家庭乱伦'), ('113', '偷情少妇'), ('114', '百合女同'),
    ('116', 'AI短剧'),
]

NODES = [('global', '全球加速节点'), ('asia', '亚洲加速节点'), ('china', '中国大陆加速节点')]
NODE_NAMES = dict(NODES)

CARD_RE = re.compile(r'<a\s+href="/video/(\d+)\.html">\s*<img[^>]*src="([^"]+)"[^>]*alt="([^"]*)"', re.S)
CAT_RE = re.compile(r'<a[^>]*href="/list/(\d+)\.html"[^>]*>\s*([^<]+?)\s*</a>', re.S)
TITLE_RE = re.compile(r'<title[^>]*>(.*?)</title>', re.S)
OGIMG_RE = re.compile(r'<meta[^>]*property="og:image"[^>]*content="([^"]+)"', re.S)
PLAYLINK_RE = re.compile(r'<a[^>]*href="/play/(\d+)\.html\?node=([a-z]+)"[^>]*>(.*?)</a>', re.S)
M3U8_RE = re.compile(r'"(https?://[^"\s]+\.m3u8(?:\?[^"\s]*)?)"')
M3U8_RE2 = re.compile(r"'(https?://[^'\s]+\.m3u8(?:\?[^'\s]*)?)'")
SRC_RE = re.compile(r'<(?:source|video)[^>]+src="([^"]+)"', re.S)
URLVAR_RE = re.compile(r'(?:videoUrl|playUrl|m3u8|source|url)\s*[:=]\s*"([^"]+)"', re.S)


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
    if not html:
        return out
    matches = list(CARD_RE.finditer(html))
    for idx, m in enumerate(matches):
        vid = m.group(1).strip()
        if not vid or vid in seen:
            continue
        title = _unescape(m.group(3))
        if not title:
            continue
        seen.add(vid)
        end = matches[idx + 1].start() if idx + 1 < len(matches) else m.end() + 900
        seg = html[m.end():min(end, m.end() + 900)]
        remarks = ''
        vm = re.search(r'([\d,]+)\s*次观看', seg)
        if vm:
            remarks = vm.group(1) + '次观看'
        else:
            dm = re.search(r'(\d{4}-\d{2}-\d{2})', seg)
            if dm:
                remarks = dm.group(1)
        out.append({
            'vod_id': vid,
            'vod_name': title,
            'vod_pic': _fix_url(m.group(2)),
            'vod_remarks': remarks,
        })
    return out


def _parse_categories(html):
    out = []
    seen = set()
    for m in CAT_RE.finditer(html or ''):
        cid = m.group(1)
        name = m.group(2).strip()
        if not name or cid in seen:
            continue
        seen.add(cid)
        out.append((cid, name))
    return out


def _field(html, label, pattern):
    m = re.search(label + r'[:：]\s*(?:</[^>]+>\s*)?' + pattern, html or '')
    return _unescape(m.group(1)) if m else ''


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
        return '看裤X'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cats(self):
        cats = _parse_categories(_http_get(BASE + '/list.php', referer=BASE + '/'))
        if len(cats) < 50:
            more = _parse_categories(_http_get(BASE + '/', referer=BASE + '/'))
            have = set(c for c, _ in cats)
            for c in more:
                if c[0] not in have:
                    cats.append(c)
                    have.add(c[0])
        if len(cats) < 50:
            return list(CATS)
        return cats

    def _catalog(self, tid, pg):
        if tid in ('all', '0', ''):
            url = BASE + '/list.php?sort=hot' if pg <= 1 else BASE + '/list.php?sort=hot&page=%d' % pg
        elif pg <= 1:
            url = '%s/list/%s.html' % (BASE, tid)
        else:
            url = '%s/list/%s.html?sort=new&page=%d' % (BASE, tid, pg)
        return _parse_cards(_http_get(url, referer=BASE + '/'))

    def homeContent(self, filter=''):
        cats = self._cats()
        items = _parse_cards(_http_get(BASE + '/list.php?sort=hot', referer=BASE + '/'))
        return {
            'class': [{'type_id': 'all', 'type_name': '全部'}] + [{'type_id': tid, 'type_name': name} for tid, name in cats],
            'list': items,
        }

    def homeVideoContent(self):
        items = _parse_cards(_http_get(BASE + '/list.php?sort=hot', referer=BASE + '/'))
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        items = self._catalog(str(tid or 'all'), pg)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        nid = _norm_id(ids).strip().lstrip('/')
        nid = re.sub(r'\D', '', nid)
        if not nid:
            return {'list': []}
        html = _http_get(BASE + '/video/%s.html' % nid, referer=BASE + '/')
        if not html:
            return {'list': []}
        tm = TITLE_RE.search(html)
        title = _unescape(tm.group(1)) if tm else ''
        for suf in (' - 看裤X', ' - 看裤', ' - 在线播放'):
            if title.endswith(suf):
                title = title[:-len(suf)]
        title = title.strip()
        if not title:
            return {'list': []}
        pic = ''
        om = OGIMG_RE.search(html)
        if om:
            pic = _fix_url(om.group(1))
        if not pic:
            im = re.search(r'<img[^>]*src="([^"]+)"[^>]*alt="%s"' % re.escape(title), html, re.S)
            if im:
                pic = _fix_url(im.group(1))
        if not pic:
            im = re.search(r'<img[^>]*src="([^"]+)"', html, re.S)
            if im:
                pic = _fix_url(im.group(1))
        cat = _field(html, '分类', r'([^<\s]+)')
        views = _field(html, '播放', r'([\d,]+)')
        duration = _field(html, '时长', r'([\d:]+)')
        pubdate = _field(html, '发布时间', r'(\d{4}-\d{2}-\d{2})')
        year = _field(html, '年份', r'(\d{4})')
        score = _field(html, '评分', r'([\d.]+)')
        tags = []
        ti = html.find('标签')
        if ti >= 0:
            tj = html.find('视频简介', ti)
            seg = html[ti:tj] if tj > ti else html[ti:ti + 2000]
            tags = [_unescape(t).strip() for t in re.findall(r'<a[^>]*href="/tag/[^"]*"[^>]*>\s*([^<]+?)\s*</a>', seg) if _unescape(t).strip() and '更多' not in t]
        synopsis = title
        si = html.find('视频简介')
        if si >= 0:
            sm = re.search(r'<div[^>]*>\s*([^<]{4,500}?)\s*</div>', html[si:si + 1500], re.S)
            if sm:
                synopsis = _unescape(sm.group(1)).strip() or title
        eps = []
        seen = set()
        for m in PLAYLINK_RE.finditer(html):
            if m.group(1) != nid:
                continue
            node = m.group(2)
            if node in seen:
                continue
            seen.add(node)
            label = re.sub(r'<[^>]+>', '', m.group(3))
            label = _unescape(label).replace('▶', '').strip()
            if not label:
                label = NODE_NAMES.get(node, node)
            eps.append('%s$kankux:%s:%s' % (label, nid, node))
        if not eps:
            eps = ['%s$kankux:%s:%s' % (name, nid, node) for node, name in NODES]
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': pic,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': duration or views,
            'vod_year': year,
            'vod_score': score,
            'vod_area': '',
            'vod_content': synopsis,
            'type_name': cat,
            'vod_tag': ','.join(tags),
            'vod_play_from': '在线播放',
            'vod_play_url': '#'.join(eps),
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        kw = urllib.parse.quote((key or '').strip())
        if not kw:
            return {'list': [], 'page': pg, 'pagecount': 0, 'total': 0}
        url = '%s/search/%s.html' % (BASE, kw)
        if pg > 1:
            url += '?page=%d' % pg
        items = _parse_cards(_http_get(url, referer=BASE + '/'))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def _extract_play(self, html):
        if not html:
            return ''
        for pat in (M3U8_RE, M3U8_RE2):
            m = pat.search(html)
            if m:
                return _unescape(m.group(1))
        for m in SRC_RE.finditer(html):
            u = _unescape(m.group(1))
            if '.m3u8' in u or '.mp4' in u:
                return u
        for m in URLVAR_RE.finditer(html):
            u = _unescape(m.group(1))
            if '.m3u8' in u or '.mp4' in u:
                return u
        return ''

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        if raw.startswith('kankux:'):
            raw = raw[len('kankux:'):]
        parts = raw.split(':')
        vid = re.sub(r'\D', '', parts[0]) if parts else ''
        node = parts[1] if len(parts) > 1 and parts[1] in NODE_NAMES else 'global'
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        order = [node] + [n for n, _ in NODES if n != node]
        play = ''
        for nd in order:
            html = _http_get(BASE + '/play/%s.html?node=%s' % (vid, nd), referer=BASE + '/video/%s.html' % vid)
            play = self._extract_play(html)
            if play:
                break
        if play.startswith('//'):
            play = 'https:' + play
        elif play.startswith('/'):
            play = BASE + play
        return {'parse': 0, 'playUrl': play, 'url': play, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', '']

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
