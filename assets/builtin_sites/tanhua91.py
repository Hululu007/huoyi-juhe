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


HOSTS = ['https://www.91tanhua196.sbs', 'https://www.91tanhua301.sbs', 'https://www.91tanhua326.sbs']
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
PREVIEW_URL = 'https://cdn2.jiuse2.cloud/hlsd/js10/index.m3u8'

CATS = [
    ('v-latest', '最近更新'),
    ('v-hd', '高清视频'),
    ('v-recent-favorite', '最近加精'),
    ('v-hot-list', '当前最热'),
    ('v-recent-rating', '最近得分'),
    ('v-ori', '91原创'),
    ('v-long-list', '10分钟以上'),
    ('v-longer-list', '20分钟以上'),
    ('v-month-discuss', '本月讨论'),
    ('v-top-favorite', '本月收藏'),
    ('v-most-favorite', '收藏最多'),
    ('v-top-list', '本月最热'),
    ('v-top-last', '上月最热'),
    ('k-top-rated', '最高评分'),
    ('k-latest-updates', '最近更新'),
    ('k-most-popular', '最受欢迎'),
    ('k-europe-america', '欧美'),
    ('k-chinese', '国产'),
    ('k-fornication', '乱伦'),
    ('k-japan-korea', '日韩'),
    ('k-anime', '动漫'),
    ('k-homosexual', '同性'),
    ('k-hd', '高清AV'),
    ('k-sm', 'SM专区'),
    ('k-jijin', '片商集锦'),
    ('k-guodong', '果冻传媒'),
    ('k-xingkong', '星空传媒'),
    ('k-madou', '麻豆传媒'),
    ('k-tianmei', '天美传媒'),
    ('k-jingdong', '精东影业'),
    ('k-swag', '台湾SWAG'),
    ('k-tuzi', '兔子先生'),
    ('k-mitao', '蜜桃传媒'),
    ('k-huangjia', '皇家华人'),
    ('d-all', '精品'),
    ('d-orig', '原创'),
    ('d-repost', '转发'),
    ('d-sponsor', '赞助'),
    ('s-swag', 'SWAG'),
    ('s-madou', '麻豆'),
]

K_SORTS = ['top-rated', 'latest-updates', 'most-popular']


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _fetch_once(url, timeout=25):
    h = {'User-Agent': UA, 'Referer': HOSTS[0], 'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8', 'Accept-Language': 'zh-CN,zh;q=0.9', 'Accept-Encoding': 'gzip, deflate'}
    if _HAS_REQ:
        try:
            r = requests.get(url, headers=h, timeout=timeout)
            if r.status_code == 200 and r.text:
                return r.text
        except Exception:
            pass
    req = urllib.request.Request(url, headers=h)
    with urllib.request.urlopen(req, timeout=timeout, context=_ctx()) as resp:
        if resp.status != 200:
            raise Exception('HTTP %s' % resp.status)
        data = resp.read()
        enc = (resp.headers.get('Content-Encoding') or '').lower()
        if enc == 'gzip' or data[:2] == b'\x1f\x8b':
            try:
                data = gzip.decompress(data)
            except Exception:
                pass
        return data.decode('utf-8', 'replace')


def _http_get(path, timeout=25):
    for host in HOSTS:
        url = host + path
        for _ in range(2):
            try:
                return _fetch_once(url, timeout=timeout)
            except urllib.error.HTTPError as e:
                try:
                    return e.read().decode('utf-8', 'ignore')
                except http.client.IncompleteRead as ie:
                    return ie.partial.decode('utf-8', 'ignore')
            except Exception:
                time.sleep(1)
    return ''


def _http_get_abs(url, timeout=25):
    h = {'User-Agent': UA, 'Referer': HOSTS[0]}
    for _ in range(2):
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
                return resp.read().decode('utf-8', 'replace')
        except Exception:
            time.sleep(1)
    return ''


def _fix_url(raw):
    u = _html.unescape((raw or '').strip())
    if not u:
        return ''
    if u.startswith('http://') or u.startswith('https://'):
        return u
    if u.startswith('//'):
        return 'https:' + u
    if u.startswith('/'):
        return HOSTS[0] + u
    return u


def _unescape(s):
    if not s:
        return ''
    return _html.unescape(s).replace('&nbsp;', ' ')


def _strip_tags(s):
    if not s:
        return ''
    return re.sub(r'<[^>]+>', '', s).strip()


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
    href_re = re.compile(r'<a[^>]*class="display d-block"[^>]*href="([^"]+)"')
    cover_re = re.compile(r'background-image:\s*url\(["\']?([^)\'"]+)')
    dur_re = re.compile(r'<small class="layer">([^<]+)</small>')
    title_re = re.compile(r'<a[^>]*class="title[^"]*"[^>]*href="[^"]+">([^<]+)</a>', re.S)
    for block in (html or '').split('<div class="video-elem">')[1:]:
        hm = href_re.search(block)
        href = hm.group(1).strip() if hm else ''
        if not href or href in seen:
            continue
        seen.add(href)
        if not (href.startswith('/video/') or href.startswith('/videos/') or href.startswith('/vod/')):
            continue
        tm = title_re.search(block)
        title = _unescape(tm.group(1).strip()) if tm else ''
        if not title:
            continue
        cm = cover_re.search(block)
        cover = _fix_url(cm.group(1)) if cm else ''
        dm = dur_re.search(block)
        remark = dm.group(1).strip() if dm else ''
        out.append({'vod_id': href, 'vod_name': title, 'vod_pic': cover, 'vod_remarks': remark})
    return out


def _strip_comments(html):
    return re.sub(r'<!--.*?-->', '', html or '', flags=re.S)


def _parse_tabs(html, prefix):
    out = []
    seen = set()
    pat = re.compile(r'data-href="([^"]+)"[^>]*>([^<]+)</div>')
    for m in pat.finditer(html or ''):
        href, name = m.group(1).strip(), m.group(2).strip()
        if not href.startswith(prefix) or not name or href in seen:
            continue
        seen.add(href)
        out.append((href, name))
    return out


def _parse_k_sorts(html):
    out = []
    seen = set()
    pat = re.compile(r'<a[^>]*href="/videos/([a-z-]+)/\d+"[^>]*>([^<]+)</a>')
    for m in pat.finditer(html or ''):
        slug, name = m.group(1).strip(), m.group(2).strip()
        if slug not in K_SORTS or not name or slug in seen:
            continue
        seen.add(slug)
        out.append((slug, name))
    return out


def _catalog_route(tid, pg):
    pg = max(pg, 1)
    if tid.startswith('v-'):
        slug = tid[2:]
        base = '/video/category/%s' % slug
        path = base if pg <= 1 else '%s/%s' % (base, pg)
        return path, '%s/%s' % (base, pg + 1)
    if tid.startswith('k-'):
        slug = tid[2:]
        if slug in K_SORTS:
            base = '/videos/%s' % slug
            return '%s/%s' % (base, pg), '%s/%s' % (base, pg + 1)
        base = '/videos/categories/%s' % slug
        path = base if pg <= 1 else '%s/%s' % (base, pg)
        return path, '%s/%s' % (base, pg + 1)
    if tid.startswith('d-'):
        slug = tid[2:]
        if slug == 'all':
            filt = ''
        elif slug == 'orig':
            filt = '/%E5%8E%9F%E5%88%9B'
        elif slug == 'repost':
            filt = '/%E8%BD%AC%E5%8F%91'
        elif slug == 'sponsor':
            filt = '/%E8%B5%9E%E5%8A%A9'
        else:
            return None
        path = '/vod%s' % filt if pg <= 1 else '/vod%s?page=%s' % (filt, pg)
        return path, '/vod%s?page=%s' % (filt, pg + 1)
    if tid.startswith('s-'):
        slug = tid[2:]
        if slug not in ('swag', 'madou'):
            return None
        path = '/%s?keywords=%s&page=%s' % (slug, slug, pg)
        return path, '/%s?keywords=%s&page=%s' % (slug, slug, pg + 1)
    return None


def _meta_content(html, attr, value):
    pat = re.compile(r'<meta[^>]*%s="%s"[^>]*content="([^"]+)"' % (attr, value))
    m = pat.search(html or '')
    return _unescape(m.group(1).strip()) if m else ''


def _iso_duration_secs(html):
    m = re.search(r'"duration":\s*"PT(?:(\d+)H)?(?:(\d+)M)?(?:([\d.]+)S)?"', html or '')
    if not m:
        return None
    total = 0.0
    try:
        if m.group(1):
            total += float(m.group(1)) * 3600
        if m.group(2):
            total += float(m.group(2)) * 60
        if m.group(3):
            total += float(m.group(3))
    except Exception:
        return None
    return total if total > 0 else None


def _parse_playlist(text):
    if not text or '#EXTM3U' not in text:
        return None
    notice = '__vnotice' in text
    total = 0.0
    n = 0
    for m in re.finditer(r'#EXTINF:([\d.]+)', text):
        try:
            total += float(m.group(1))
            n += 1
        except Exception:
            pass
    if n == 0:
        if '.m3u8' in text:
            return (None, notice)
        return (0.0, notice)
    return (total, notice)


def _playlist_info(url):
    txt = _http_get_abs(url)
    if not txt:
        return None
    return _parse_playlist(txt)


def _playlist_playable(info, claimed):
    if info is None:
        return True
    total, notice = info
    if notice:
        return False
    if total is not None and claimed is not None:
        return total >= claimed * 0.5
    return True


def _play_url_of(html):
    m = re.search(r'data-src="([^"]+)"', html or '')
    return _fix_url(m.group(1)) if m else ''


def _embed_play_url(detail_path):
    hexid = detail_path.strip('/').rsplit('/', 1)[-1]
    if not hexid:
        return ''
    if '/video/view' in detail_path:
        embed = '/video/embed/%s' % hexid
    elif '/vod/view/' in detail_path:
        embed = '/vod/embed/%s' % hexid
    else:
        return ''
    html = _http_get(embed)
    return _play_url_of(html) if html else ''


def _resolve_hls(url, detail_path, claimed):
    if '/hlsd/js10/' in url:
        return url
    info = _playlist_info(url)
    if info is None:
        return url
    if _playlist_playable(info, claimed):
        return url
    alt = _embed_play_url(detail_path)
    if alt and alt != url:
        info2 = _playlist_info(alt)
        if info2 is None:
            return alt
        if _playlist_playable(info2, claimed):
            return alt
    return None


def _preview_fallback():
    info = _playlist_info(PREVIEW_URL)
    if info is not None and _playlist_playable(info, None):
        return PREVIEW_URL
    return None


def _mp4_alive(url):
    h = {'User-Agent': UA, 'Referer': HOSTS[0], 'Range': 'bytes=0-0'}
    for _ in range(2):
        if _HAS_REQ:
            try:
                r = requests.get(url, headers=h, timeout=15)
                return r.status_code not in (404, 410)
            except Exception:
                return True
        try:
            req = urllib.request.Request(url, headers=h)
            with urllib.request.urlopen(req, timeout=15, context=_ctx()) as resp:
                return resp.status not in (404, 410)
        except urllib.error.HTTPError as e:
            return e.code not in (404, 410)
        except Exception:
            return True
    return True


class Spider(BaseSpider):
    def getName(self):
        return '九色'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cats(self):
        out = []
        seen = set()
        html = _http_get('/video')
        if html:
            for href, name in _parse_tabs(_strip_comments(html), '/video/category/'):
                slug = href[len('/video/category/'):].strip('/')
                if slug == 'nonpaid':
                    continue
                cid = 'v-%s' % slug
                if cid not in seen:
                    seen.add(cid)
                    out.append((cid, name))
        html = _http_get('/videos')
        if html:
            live = _strip_comments(html)
            for slug, name in _parse_k_sorts(live):
                cid = 'k-%s' % slug
                if cid not in seen:
                    seen.add(cid)
                    out.append((cid, name))
            for href, name in _parse_tabs(live, '/videos/categories/'):
                slug = href[len('/videos/categories/'):].strip('/')
                cid = 'k-%s' % slug
                if cid not in seen:
                    seen.add(cid)
                    out.append((cid, name))
        if len(out) < 10:
            return list(CATS)
        for cid, name in [('d-all', '精品'), ('d-orig', '原创'), ('d-repost', '转发'), ('d-sponsor', '赞助'), ('s-swag', 'SWAG'), ('s-madou', '麻豆')]:
            if cid not in seen:
                seen.add(cid)
                out.append((cid, name))
        return out

    def homeContent(self, filter=''):
        cats = self._cats()
        items = []
        try:
            items = self.categoryContent(cats[0][0], 1).get('list') or []
        except Exception:
            items = []
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in cats],
            'list': items,
        }

    def homeVideoContent(self):
        try:
            items = self.categoryContent(self._cats()[0][0], 1).get('list') or []
        except Exception:
            items = []
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        route = _catalog_route(tid, pg)
        if not route:
            return {'list': [], 'page': pg, 'pagecount': 0, 'total': 0}
        path, nxt = route
        html = _http_get(path)
        items = _cards(html)
        has_more = bool(items) and (nxt in (html or '') or nxt.replace('&', '&amp;') in (html or ''))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        sid = _norm_id(ids).strip().lstrip('/')
        if not sid:
            return {'list': []}
        html = _http_get('/%s' % sid)
        if not html:
            return {'list': []}
        claimed = _iso_duration_secs(html)
        title = _meta_content(html, 'property', 'og:title')
        if not title:
            tm = re.search(r'<title[^>]*>(.*?)</title>', html, re.S)
            if tm:
                title = _unescape(_strip_tags(tm.group(1)))
                if ' - ' in title:
                    title = title.split(' - ')[0].strip()
        cover = _meta_content(html, 'property', 'og:image:secure_url') or _meta_content(html, 'property', 'og:image')
        actor = _meta_content(html, 'name', 'twitter:creator')
        keywords = _meta_content(html, 'name', 'keywords')
        synopsis = _meta_content(html, 'property', 'og:description') or title
        if actor:
            synopsis += '\n作者：' + actor
        if keywords:
            synopsis += '\n标签：' + keywords
        play_url = _play_url_of(html)
        if not title or not play_url:
            return {'list': []}
        eps = []
        if sid.startswith('video/viewhd/'):
            eps.append('高清预览$%s' % play_url)
            hexid = sid.rsplit('/', 1)[-1]
            sd_html = _http_get('/video/view/%s' % hexid)
            if sd_html:
                sd_url = _play_url_of(sd_html)
                if sd_url:
                    sd_claimed = _iso_duration_secs(sd_html) or claimed
                    ok = _resolve_hls(sd_url, '/video/view/%s' % hexid, sd_claimed)
                    if ok:
                        eps.append('标清全片$%s' % ok)
        elif '.m3u8' in play_url:
            ok = _resolve_hls(play_url, '/' + sid, claimed)
            if ok:
                eps.append('在线播放$%s' % ok)
            else:
                pv = _preview_fallback()
                if pv:
                    eps.append('在线播放$%s' % pv)
                else:
                    return {'list': []}
        elif '.mp4' in play_url:
            if _mp4_alive(play_url):
                eps.append('在线播放$%s' % play_url)
            else:
                pv = _preview_fallback()
                if pv:
                    eps.append('在线播放$%s' % pv)
                else:
                    return {'list': []}
        else:
            eps.append('在线播放$%s' % play_url)
        return {'list': [{
            'vod_id': '/' + sid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': actor,
            'vod_director': '',
            'vod_remarks': '',
            'vod_year': '',
            'vod_area': '',
            'vod_content': synopsis,
            'type_name': '',
            'vod_tag': keywords,
            'vod_play_from': '在线播放',
            'vod_play_url': '#'.join(eps),
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        url = '/search?keywords=%s&page=1' % urllib.parse.quote(str(key or ''), safe='')
        html = _http_get(url)
        items = _cards(html)
        return {'list': items, 'page': _norm_pg(pg), 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        header = {'User-Agent': UA, 'Referer': HOSTS[0] + '/'}
        if raw.startswith('http'):
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', b'', {}]

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
