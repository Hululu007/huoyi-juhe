import gzip
import json
import re
import ssl
import time
import urllib.parse
import urllib.request

try:
    from base.spider import BaseSpider
except Exception:
    try:
        from base import BaseSpider
    except Exception:
        class BaseSpider:
            pass

try:
    import requests as _requests
except Exception:
    _requests = None

BASE = 'https://asextv.xyz'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

CATS = [
    ('1/20', '大奶子·精品推荐'),
    ('1/21', '大奶子·国产主播'),
    ('1/22', '大奶子·国产乱伦'),
    ('1/23', '大奶子·自拍偷拍'),
    ('1/24', '大奶子·制服丝袜'),
    ('1/25', '大奶子·网曝事件'),
    ('1/26', '大奶子·传媒探花'),
    ('1/27', '大奶子·清纯学生'),
    ('1/28', '大奶子·A V 解说'),
    ('1/29', '大奶子·淫妻作乐'),
    ('1/30', '大奶子·港台辣妹'),
    ('1/31', '大奶子·足浴撩妹'),
    ('1/32', '大奶子·反差母狗'),
    ('1/33', '大奶子·A I 换脸'),
    ('1/34', '大奶子·V R 视角'),
    ('1/35', '大奶子·重口性癖'),
    ('1/36', '大奶子·制服诱惑'),
    ('1/37', '大奶子·丝袜美腿'),
    ('1/38', '大奶子·中文字幕'),
    ('1/39', '大奶子·无码流出'),
    ('1/40', '大奶子·多人群交'),
    ('1/41', '大奶子·凌辱快感'),
    ('1/42', '大奶子·角色剧情'),
    ('1/43', '大奶子·强奸乱伦'),
    ('1/44', '大奶子·韩国三级'),
    ('1/45', '大奶子·欧美激情'),
    ('1/46', '大奶子·人妻熟女'),
    ('1/47', '大奶子·主奴调教'),
    ('1/48', '大奶子·动漫卡通'),
    ('1/49', '大奶子·变性伪娘'),
    ('1/50', '大奶子·女同性恋'),
    ('1/51', '大奶子·野外露出'),
    ('2/54', '极品·日韩无码'),
    ('2/55', '极品·国产精品'),
    ('2/57', '极品·日韩精品'),
    ('2/58', '极品·欧美精品'),
    ('2/59', '极品·动漫精品'),
    ('2/60', '极品·自拍偷拍'),
    ('2/61', '极品·伦理影片'),
    ('2/62', '极品·中文字幕'),
    ('2/63', '极品·人妻系列'),
    ('2/64', '极品·制服诱惑'),
    ('2/65', '极品·强奸乱伦'),
    ('2/66', '极品·AV明星'),
    ('2/68', '极品·SM重味'),
    ('2/70', '极品·巨乳系列'),
    ('2/71', '极品·颜射系列'),
    ('2/72', '极品·口交视频'),
    ('2/73', '极品·自慰系列'),
    ('2/74', '极品·教师学生'),
    ('2/75', '极品·大秀视频'),
    ('2/76', '极品·明星换脸'),
    ('2/78', '极品·AV解说'),
    ('2/80', '极品·黑料网曝'),
    ('2/81', '极品·精品探花'),
    ('2/82', '极品·精品网红'),
    ('2/83', '极品·反差母狗'),
    ('2/84', '极品·颜值正义'),
    ('2/85', '极品·熟女少妇'),
    ('2/86', '极品·人兽乱交'),
    ('2/89', '极品·国产传媒'),
    ('2/90', '极品·野战车震'),
    ('2/91', '极品·SM调教'),
    ('2/92', '极品·家庭乱伦'),
    ('2/93', '极品·百合女同'),
    ('2/94', '极品·学生空姐'),
    ('2/95', '极品·撸管必看'),
    ('2/97', '极品·偷情少妇'),
    ('3/21', '红楼·原创乱伦'),
    ('3/22', '红楼·鬼父操女'),
    ('3/23', '红楼·中文字幕'),
    ('3/24', '红楼·制服诱惑'),
    ('3/25', '红楼·嫂子诱惑'),
    ('3/26', '红楼·姐夫小姨子'),
    ('3/27', '红楼·兄弟姐妹'),
    ('3/28', '红楼·风韵岳母'),
    ('3/32', '红楼·吃瓜黑料'),
    ('3/33', '红楼·酒店探花'),
    ('3/34', '红楼·儿媳献穴'),
    ('3/35', '红楼·SM调教'),
    ('3/36', '红楼·师生迷情'),
    ('3/37', '红楼·AI换脸'),
    ('3/38', '红楼·国产主播'),
    ('3/39', '红楼·AV解说'),
    ('3/40', '红楼·家族淫趴'),
    ('3/41', '红楼·淫母兽儿'),
    ('3/42', '红楼·近亲相奸'),
    ('3/59', '红楼·欧美劲爆'),
    ('3/60', '红楼·SM重味'),
    ('3/61', '红楼·伦理影片'),
    ('3/64', '红楼·日韩无码'),
    ('3/65', '红楼·强奸乱伦'),
    ('3/66', '红楼·强奸迷奸'),
    ('3/67', '红楼·野战车震'),
    ('3/68', '红楼·熟女少妇'),
    ('3/69', '红楼·反差母狗'),
    ('3/70', '红楼·巨乳尤物'),
    ('3/71', '红楼·人妻巨乳'),
    ('3/72', '红楼·站长推荐'),
    ('3/73', '红楼·自拍偷拍'),
    ('3/74', '红楼·教师学生'),
    ('3/75', '红楼·3D动漫'),
    ('3/76', '红楼·人妻系列'),
    ('3/77', '红楼·日韩精品'),
    ('3/78', '红楼·撸管必看'),
    ('3/79', '红楼·短视频'),
    ('3/80', '红楼·兄妹姐弟'),
    ('3/81', '红楼·叔嫂乱伦'),
    ('3/82', '红楼·姐夫小姨'),
    ('3/83', '红楼·家庭乱伦'),
    ('3/84', '红楼·母子乱伦'),
    ('3/87', '红楼·母子乱伦'),
    ('3/88', '红楼·母子乱伦'),
    ('3/89', '红楼·母子乱伦'),
    ('3/90', '红楼·国产传媒'),
    ('3/91', '红楼·直播裸聊'),
]

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE


def _now():
    return time.time()


def _http_get(url, referer=None, timeout=25):
    hdr = {
        'User-Agent': UA,
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9',
        'Accept-Encoding': 'gzip, deflate',
        'Connection': 'keep-alive',
    }
    if referer:
        hdr['Referer'] = referer
    for attempt in range(3):
        text = None
        if _requests is not None:
            try:
                resp = _requests.get(url, headers=hdr, timeout=timeout)
                if resp.status_code == 200:
                    text = resp.content.decode('utf-8', 'replace')
            except Exception:
                text = None
        if text is None:
            try:
                req = urllib.request.Request(url, headers=hdr)
                with urllib.request.urlopen(req, timeout=timeout, context=CTX) as resp:
                    if resp.status == 200:
                        data = resp.read()
                        enc = (resp.headers.get('Content-Encoding') or '').lower()
                        if enc == 'gzip' or data[:2] == b'\x1f\x8b':
                            try:
                                data = gzip.decompress(data)
                            except Exception:
                                pass
                        text = data.decode('utf-8', 'replace')
            except Exception:
                text = None
        if text is not None:
            return text
        if attempt < 2:
            try:
                time.sleep(2)
            except Exception:
                pass
    return None


def _fetch(path, referer=None):
    return _http_get(BASE + path, referer=referer or (BASE + '/'))


def _unescape(s):
    if not s:
        return ''
    return (s.replace('&nbsp;', ' ')
             .replace('&amp;', '&')
             .replace('&#039;', "'")
             .replace('&#39;', "'")
             .replace('&quot;', '"')
             .replace('&lt;', '<')
             .replace('&gt;', '>')
             .strip())


def _fix_url(raw):
    u = (raw or '').strip()
    if not u:
        return ''
    if u.startswith('http://') or u.startswith('https://'):
        return u
    if u.startswith('//'):
        return 'https:' + u
    if u.startswith('/'):
        return BASE + u
    return BASE + '/' + u


def _strip_tags(s):
    if not s:
        return ''
    s = re.sub(r'<[^>]+>', ' ', s)
    s = _unescape(s)
    s = re.sub(r'\s+', ' ', s)
    return s.strip()


def _parse_cards(html):
    out = []
    if not html:
        return out
    seen = set()
    for block in html.split('<a class="movie-card"')[1:]:
        end = block.find('<a class="movie-card"')
        if end >= 0:
            block = block[:end]
        hp = block.find('href="/video/')
        if hp < 0:
            continue
        s = hp + 13
        e = block[s:].find('"')
        if e < 0:
            continue
        vid = block[s:s + e].strip()
        if not vid or not vid.isdigit() or vid in seen:
            continue
        seen.add(vid)
        title = ''
        p = block.find('<h3')
        if p >= 0:
            after = block[p:]
            gt = after.find('>')
            if gt >= 0:
                e2 = after[gt + 1:].find('</h3>')
                if e2 >= 0:
                    title = _unescape(after[gt + 1:gt + 1 + e2])
        cover = ''
        p = block.find('<img ')
        if p >= 0:
            img = block[p:]
            s2 = img.find('src="')
            if s2 >= 0:
                s2 += 5
                e2 = img[s2:].find('"')
                if e2 >= 0:
                    cover = _fix_url(img[s2:s2 + e2])
            if not title:
                s2 = img.find('alt="')
                if s2 >= 0:
                    s2 += 5
                    e2 = img[s2:].find('"')
                    if e2 >= 0:
                        title = _unescape(img[s2:s2 + e2])
        if not title:
            continue
        if len(title) > 90:
            title = title[:90]
        remark = ''
        p = block.find('movie-caption')
        if p >= 0:
            after = block[p:]
            gt = after.find('>')
            if gt >= 0:
                e2 = after[gt + 1:].find('</div>')
                if e2 >= 0:
                    raw = after[gt + 1:gt + 1 + e2]
                    parts = [t.strip() for t in re.split(r'<[^>]+>', raw) if t.strip()]
                    remark = ' · '.join(parts)
                    remark = _unescape(remark)
        out.append({
            'vod_id': vid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_remarks': remark,
        })
    return out


def _detail_cover(html, nid):
    if not html or not nid:
        return ''
    pat = re.compile(r'\\"id\\":\\"' + re.escape(nid) + r'\\"[^}]*?\\"cover\\":\\"(/covers/[^"\\]+)\\"')
    m = pat.search(html)
    if m:
        return _fix_url(m.group(1))
    return ''


def _extract_m3u8(html):
    if not html:
        return ''
    m = re.search(r'https://[^\s"\\]+\.m3u8', html)
    return m.group(0) if m else ''


def _norm_id(ids):
    if isinstance(ids, (list, tuple)):
        return str(ids[0]) if ids else ''
    return str(ids)


def _norm_pg(pg):
    try:
        return int(pg)
    except Exception:
        try:
            return int(str(pg).strip())
        except Exception:
            return 1


def _empty_detail(vod_id):
    return {'list': [{
        'vod_id': vod_id,
        'vod_name': '',
        'vod_pic': '',
        'vod_actor': '',
        'vod_director': '',
        'vod_remarks': '',
        'vod_year': '',
        'vod_area': '',
        'vod_content': '',
        'type_name': '',
        'vod_tag': '',
        'vod_play_from': '在线播放',
        'vod_play_url': '',
        'stills': [],
    }]}


class Spider(BaseSpider):

    def getName(self):
        return 'A色TV'

    def getDependence(self):
        return []

    def init(self, extend=None):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=False):
        cats = [{'type_id': cid, 'type_name': name} for cid, name in CATS]
        return {'class': cats, 'filters': {}}

    def homeVideoContent(self):
        html = _fetch('/')
        items = _parse_cards(html)
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        tid = _norm_id(tid).strip()
        pg = _norm_pg(pg)
        if pg < 1:
            pg = 1
        if not tid or tid == 'all':
            tid = '1/20'
        if pg <= 1:
            path = '/category/%s' % tid
        else:
            path = '/category/%s?page=%d' % (tid, pg)
        html = _fetch(path)
        items = _parse_cards(html)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        raw = _norm_id(ids)
        nid = ''.join([ch for ch in raw if ch.isdigit()])
        if not nid:
            return _empty_detail(raw)
        html = _fetch('/video/%s' % nid)
        if not html:
            return _empty_detail(nid)
        title = ''
        tm = re.search(r'<title>(.*?)</title>', html, re.S)
        if tm:
            title = _unescape(tm.group(1))
            for sep in (' - A-SEX-TV', ' - A色TV'):
                if sep in title:
                    title = title.rsplit(sep, 1)[0].strip()
                    break
        if not title:
            return _empty_detail(nid)
        cover = _detail_cover(html, nid)
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': '',
            'vod_year': '',
            'vod_area': '',
            'vod_content': '',
            'type_name': '',
            'vod_tag': '',
            'vod_play_from': '在线播放',
            'vod_play_url': '正片$asextv:%s' % nid,
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        if pg < 1:
            pg = 1
        kw = urllib.parse.quote_plus(str(key).strip())
        html = _fetch('/search?q=' + kw)
        items = _parse_cards(html)[:60]
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        if raw.startswith('asextv:'):
            raw = raw.split(':', 1)[1].strip()
        if raw.startswith('http') and '.m3u8' in raw:
            header = {'User-Agent': UA, 'Referer': BASE + '/'}
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        nid = ''.join([ch for ch in raw if ch.isdigit()])
        if not nid:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        page_url = BASE + '/video/' + nid
        html = _fetch('/video/%s' % nid, referer=page_url)
        url = _extract_m3u8(html)
        header = {'User-Agent': UA, 'Referer': page_url}
        if not url:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        return {'parse': 0, 'playUrl': url, 'url': url, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', b'', {}]

    def isVideoFormat(self, url):
        u = str(url or '').lower().split('?')[0]
        return u.endswith(('.m3u8', '.mp4', '.mkv', '.webm', '.flv', '.ts'))

    def manualVideoCheck(self):
        return True

    def action(self, action, params=None):
        return {'code': 0, 'msg': 'ok'}
