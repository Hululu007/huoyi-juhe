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
import http.cookiejar
import json
import re
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = 'https://jav188.net'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
PREVIEW_SERVER = 'https://msc1.vdosl.club'

CATS = [
    ('free', '免費', '/?cat=free'),
    ('jp', '日本', '/search.php?order=latest&s_type=jp&s_tid=37'),
    ('scate', '無碼', '/search.php?order=latest&s_type=scate&s_tid=35'),
    ('us', '歐美', '/search.php?order=latest&s_type=us&s_tid=33'),
    ('event', '獨家', '/search.php?s_type=event&s_tid=17'),
    ('vr', 'VR', '/search.php?s_type=tag&s_tid=488'),
    ('zone1', '國產', '/zone_index.php?zone=1'),
    ('zone2', '卡通', '/zone_index.php?zone=2'),
    ('leaks', '黑料', '/leaks_zone.php'),
    ('topic', '主題', '/special_topic.php'),
    ('cate1', '癖好', '/category.php?cate=1'),
    ('cate2', '動作', '/category.php?cate=2'),
    ('cate3', '身材', '/category.php?cate=3'),
    ('cate4', '羞恥', '/category.php?cate=4'),
    ('cate5', '強迫', '/category.php?cate=5'),
    ('cate6', '身份', '/category.php?cate=6'),
    ('actor', '女優', '/actor_list.php'),
]

LEAKS_LIST = '/ajax/site/get_tg_posts.php?format=json&page={page}&limit=12&sort=newest&featured=1&featured_pool=1&featured_default_sort=1'
LEAKS_ONE = '/ajax/site/get_tg_posts.php?format=json&page=1&limit=1&sort=newest&featured=1&featured_pool=1&uuid={uuid}'

_JAR = http.cookiejar.CookieJar()
_OPENER = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(_JAR))


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _cookies():
    return '; '.join('%s=%s' % (c.name, c.value) for c in _JAR)


def _raw(url, headers=None, data=None, method=None, timeout=30):
    h = {'User-Agent': UA, 'Referer': BASE + '/'}
    if headers:
        h.update(headers)
    ck = _cookies()
    if ck:
        h['Cookie'] = ck
    req = urllib.request.Request(url, data=data, headers=h, method=method)
    with _OPENER.open(req, timeout=timeout, context=_ctx()) as resp:
        raw = resp.read()
        enc = (resp.headers.get('Content-Encoding') or '').lower()
        if enc == 'gzip' or raw[:2] == b'\x1f\x8b':
            try:
                raw = gzip.decompress(raw)
            except Exception:
                pass
        return raw.decode('utf-8', 'replace'), resp.geturl(), dict(resp.headers)


def _get_page(path, timeout=30):
    url = path if path.startswith('http') else BASE + path
    last = ''
    for _ in range(3):
        try:
            txt, _u, _h = _raw(url, timeout=timeout)
            return txt
        except urllib.error.HTTPError as e:
            try:
                return e.read().decode('utf-8', 'ignore')
            except http.client.IncompleteRead as ie:
                return ie.partial.decode('utf-8', 'ignore')
        except Exception as e:
            last = str(e)
            time.sleep(1)
    return ''


def _leaks_api(path, timeout=30):
    url = BASE + path
    last = ''
    for _ in range(3):
        try:
            txt, _u, _h = _raw(url, headers={'Referer': BASE + '/leaks_zone.php', 'X-Requested-With': 'XMLHttpRequest'}, timeout=timeout)
            try:
                return json.loads(txt or '{}')
            except Exception:
                return {}
        except urllib.error.HTTPError as e:
            try:
                txt = e.read().decode('utf-8', 'ignore')
                try:
                    return json.loads(txt or '{}')
                except Exception:
                    return {}
            except http.client.IncompleteRead:
                return {}
        except Exception as e:
            last = str(e)
            time.sleep(1)
    return {}


def _clean(s):
    if not s:
        return ''
    out = s.replace('&amp;', '&').replace('&quot;', '"').replace('&#39;', "'").replace('&lt;', '<').replace('&gt;', '>').replace('&nbsp;', ' ')
    while '  ' in out:
        out = out.replace('  ', ' ')
    return out.strip()


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


def _parse_cards(html):
    block_re = re.compile(r'(?s)<div class="item [^"]*"[^>]*>(.*?)</div>\s*</div>')
    uuid_re = re.compile(r'href="/player\.php\?uuid=([A-Za-z0-9_-]{9,12})&cat=(\d+)"')
    uuid2_re = re.compile(r'data-uuid="([A-Za-z0-9_-]{9,12})"')
    cover_re = re.compile(r'(?:data-src|src)="(https://jav188\.net/preview/\d+/[sb]/[A-Za-z0-9_-]+-800\.jpg[^"]*)"')
    time_re = re.compile(r'video-time">([^<]+)<')
    title_re = re.compile(r'(?s)<span class="title"[^>]*>\s*<a[^>]*>\s*([^<]+?)\s*</a>')
    alt_re = re.compile(r"(?s)<img[^>]+alt='([^']+)'")
    out = []
    seen = set()
    for block in block_re.finditer(html or ''):
        b = block.group(1)
        m = uuid_re.search(b)
        if m:
            uuid, cat = m.group(1), m.group(2)
        else:
            m = uuid2_re.search(b)
            if not m:
                continue
            uuid, cat = m.group(1), '19'
        cm = cover_re.search(b)
        if not cm:
            continue
        cover = cm.group(1)
        tm = time_re.search(b)
        if not tm:
            continue
        time_s = _clean(tm.group(1))
        title = ''
        tm2 = title_re.search(b)
        if tm2:
            title = _clean(tm2.group(1))
        else:
            am = alt_re.search(b)
            if am:
                title = _clean(am.group(1))
        if not title or uuid in seen:
            continue
        seen.add(uuid)
        out.append({'vod_id': '%s|%s' % (uuid, cat), 'vod_name': title, 'vod_pic': cover, 'vod_remarks': time_s})
    return out


def _parse_actresses(html):
    link_re = re.compile(r"href='/search\.php\?s_type=actor&s_tid=(\d+)' title=\"([^\"]+)\"")
    pic_re = re.compile(r'src="\./resources/site_public/actor/([0-9a-f]+\.jpg)"')
    links = [(m.group(1), _clean(m.group(2))) for m in link_re.finditer(html or '')]
    pics = [m.group(1) for m in pic_re.finditer(html or '')]
    out = []
    for i in range(min(len(links), len(pics))):
        out.append({'tid': links[i][0], 'name': links[i][1], 'cover': BASE + '/resources/site_public/actor/' + pics[i]})
    return out


def _leaks_title(post):
    msg = _clean(post.get('message_content') or '').replace('\n', ' ').replace('\r', ' ')
    if msg:
        return msg
    return _clean(post.get('category_tag') or '')


def _parse_leaks_posts(data):
    out = []
    posts = (data or {}).get('posts') or []
    if not isinstance(posts, list):
        return out, False
    for post in posts:
        uuid = post.get('uuid') or ''
        cover = post.get('cover_url') or ''
        if not uuid or not cover:
            continue
        tag = _clean(post.get('category_tag') or '')
        views = post.get('view_count') or ''
        remark = ('%s %s' % (tag, views)).strip()
        out.append({'vod_id': 'leaks|%s' % uuid, 'vod_name': _leaks_title(post), 'vod_pic': cover, 'vod_remarks': remark})
    has_more = bool((data or {}).get('hasMore'))
    return out, has_more


def _cat_path(tid):
    for c in CATS:
        if c[0] == tid:
            return c[2]
    return '/?cat=free'


def _parse_segments(html):
    seg_re = re.compile(r'(?s)<li class="vdplay01[^>]*?index="(?P<index>\d+)" ms_id="(?P<ms_id>[^"]*)" file_prefix="(?P<fp>[^"]*)" start="(?P<start>\d+)"(?: start="(?P<start2>\d+)")? end="(?P<end>\d+)" cat_id="(?P<cat_id>\d+)" token="(?P<token>[0-9a-f]{32})"')
    out = []
    for m in seg_re.finditer(html or ''):
        out.append({
            'index': int(m.group('index') or 0),
            'ms_id': m.group('ms_id') or '',
            'start': m.group('start') or '',
            'end': m.group('end') or '',
            'cat_id': m.group('cat_id') or '',
            'token': m.group('token') or '',
        })
    return out


def _get_mv(uuid, page_cat, ms_id, start, end, token, cat_id):
    _get_page('/player.php?uuid=%s&cat=%s' % (uuid, page_cat))
    url = BASE + '/subpage/getMv.php?num=%s&ms_id=%s&file_prefix=&start=%s&end=%s&cat_id=%s&quality=1&token=%s&playall=0' % (uuid, ms_id, start, end, cat_id, token)
    try:
        txt, _u, _h = _raw(url, headers={'Referer': BASE + '/player.php?uuid=%s&cat=%s' % (uuid, page_cat)})
    except urllib.error.HTTPError as e:
        try:
            txt = e.read().decode('utf-8', 'ignore')
        except Exception:
            txt = ''
    try:
        v = json.loads(txt or '{}')
    except Exception:
        v = {}
    if isinstance(v, dict) and 'loginFail' in v:
        return ''
    if isinstance(v, dict) and v.get('error'):
        return ''
    url2 = (v.get('vurl_hls') or v.get('vurl') or '') if isinstance(v, dict) else ''
    return url2


def _get_preview(uuid, page_cat):
    _get_page('/player.php?uuid=%s&cat=%s' % (uuid, page_cat))
    now = int(time.time())
    url = BASE + '/subpage/getMvPreview.php?uuid=%s&v=%d' % (uuid, now)
    try:
        txt, final, headers = _raw(url, headers={'Referer': BASE + '/player.php?uuid=%s&cat=%s' % (uuid, page_cat)})
    except urllib.error.HTTPError as e:
        try:
            txt = e.read().decode('utf-8', 'ignore')
        except Exception:
            txt = ''
        final = url
        headers = {}
    ctype = ''
    if isinstance(headers, dict):
        ctype = headers.get('Content-Type') or headers.get('content-type') or ''
    if final.endswith('.mp4') or 'video/' in ctype:
        return final
    try:
        v = json.loads(txt or '{}')
        u = v.get('url') or v.get('vurl') or v.get('vurl_hls') or ''
        if u:
            return u
    except Exception:
        pass
    if txt.strip().startswith('http'):
        return txt.strip()
    return ''


class Spider(BaseSpider):
    def getName(self):
        return 'AV18.Live'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=''):
        html = _get_page('/')
        return {
            'class': [{'type_id': c[0], 'type_name': c[1]} for c in CATS],
            'list': _parse_cards(html),
        }

    def homeVideoContent(self):
        html = _get_page('/')
        return {'list': _parse_cards(html), 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        tid = _norm_id(tid) or 'free'
        if tid == 'free':
            if pg > 1:
                return {'list': [], 'page': pg, 'pagecount': 0, 'total': 0}
            html = _get_page('/')
            items = _parse_cards(html)
            return {'list': items, 'page': pg, 'pagecount': 0, 'total': len(items)}
        if tid == 'leaks':
            data = _leaks_api(LEAKS_LIST.replace('{page}', str(pg)))
            items, has_more = _parse_leaks_posts(data)
            return {'list': items, 'page': pg, 'pagecount': 0, 'total': len(items) if not has_more else 0}
        if tid in ('zone1', 'zone2', 'topic') and pg > 1:
            return {'list': [], 'page': pg, 'pagecount': 0, 'total': 0}
        path = _cat_path(tid)
        sep = '&' if '?' in path else '?'
        html = _get_page('%s%snum=%d' % (path, sep, pg))
        if tid == 'actor':
            items = []
            for a in _parse_actresses(html):
                items.append({'vod_id': 'actor|%s|%s' % (a['tid'], a['name']), 'vod_name': a['name'], 'vod_pic': a['cover'], 'vod_remarks': ''})
            return {'list': items, 'page': pg, 'pagecount': 0, 'total': len(items) if len(items) < 42 else 0}
        items = _parse_cards(html)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': len(items)}

    def detailContent(self, ids):
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        if nid.startswith('leaks|'):
            uuid = nid[len('leaks|'):]
            enc = urllib.parse.quote(uuid, safe='')
            data = _leaks_api(LEAKS_ONE.replace('{uuid}', enc))
            posts = (data or {}).get('posts') or []
            if not posts:
                return {'list': []}
            post = posts[0]
            cover = post.get('cover_url') or ''
            title = _leaks_title(post)
            tag = _clean(post.get('category_tag') or '')
            views = post.get('view_count') or ''
            post_id = post.get('id') or ''
            eps = []
            stills = []
            vid_no = 0
            for idx, m in enumerate(post.get('media_list') or []):
                path = m.get('path') or ''
                if not path:
                    continue
                is_video = bool(m.get('is_video'))
                is_locked = bool(m.get('is_locked'))
                if is_video:
                    vid_no += 1
                    name = '影片 %d' % vid_no
                    if is_locked:
                        name += '（需會員）'
                    eps.append('%s$leaks|%s|%d' % (name, post_id, idx))
                elif not is_locked:
                    stills.append(path)
            synopsis = title
            if tag:
                synopsis += '\n分類：' + tag
            if views:
                synopsis += '\n播放量：%s' % views
            if stills:
                synopsis += '\n本片劇照：\n' + '\n'.join(stills)
            return {'list': [{
                'vod_id': nid, 'vod_name': title, 'vod_pic': cover, 'vod_actor': '',
                'vod_director': '', 'vod_remarks': tag, 'vod_year': '', 'vod_area': '',
                'vod_content': synopsis, 'type_name': tag, 'vod_tag': tag,
                'vod_play_from': '在线播放', 'vod_play_url': '#'.join(eps), 'stills': stills,
            }]}
        if nid.startswith('actor|'):
            rest = nid[len('actor|'):]
            parts = rest.split('|', 1)
            tid = parts[0]
            name = parts[1] if len(parts) > 1 else tid
            if not name:
                name = tid
            html = _get_page('/search.php?s_type=actor&s_tid=%s' % tid)
            cards = _parse_cards(html)
            eps = ['%s$%s' % (c['vod_name'], c['vod_id']) for c in cards]
            return {'list': [{
                'vod_id': nid, 'vod_name': name, 'vod_pic': '', 'vod_actor': '',
                'vod_director': '', 'vod_remarks': '', 'vod_year': '', 'vod_area': '',
                'vod_content': name, 'type_name': '女優', 'vod_tag': '女優',
                'vod_play_from': '在线播放', 'vod_play_url': '#'.join(eps), 'stills': [],
            }]}
        parts = nid.split('|')
        uuid = parts[0] if parts else ''
        page_cat = parts[1] if len(parts) > 1 else '19'
        if not uuid:
            return {'list': []}
        html = _get_page('/player.php?uuid=%s&cat=%s' % (uuid, page_cat))
        title = ''
        m = re.search(r'<title>([^<|]+)', html or '')
        if m:
            title = _clean(m.group(1))
        cover = ''
        m = re.search(r'img_url_b\s*:\s*"([^"]+)"', html or '')
        if m:
            cover = m.group(1)
        if not cover:
            cover = BASE + '/preview/50/s/%s-800.jpg' % uuid
        actors = []
        for m in re.finditer(r's_type=actor&s_tid=\d+[^>]*>([^<]+)<', html or ''):
            a = _clean(m.group(1))
            if a and a not in actors:
                actors.append(a)
        segments = _parse_segments(html)
        eps = ['預告片$%s|%s|preview' % (uuid, page_cat)]
        for seg in segments:
            if seg['index'] == 1:
                name = '第%d段（免费预览）' % seg['index']
            else:
                name = '第%d段' % seg['index']
            vid = '%s|%s|%s|%s|%s|%s|%s' % (uuid, page_cat, seg['ms_id'], seg['start'], seg['end'], seg['token'], seg['cat_id'])
            eps.append('%s$%s' % (name, vid))
        if not segments:
            eps.append('正片$%s|%s' % (uuid, page_cat))
        stills = [cover] if cover else []
        return {'list': [{
            'vod_id': nid, 'vod_name': title, 'vod_pic': cover, 'vod_actor': ' '.join(actors),
            'vod_director': '', 'vod_remarks': ' '.join(actors), 'vod_year': '', 'vod_area': '',
            'vod_content': title, 'type_name': '', 'vod_tag': '',
            'vod_play_from': '在线播放', 'vod_play_url': '#'.join(eps), 'stills': stills,
        }]}

    def searchContent(self, key, quick=False, pg=1):
        enc = urllib.parse.quote(str(key or ''))
        html = _get_page('/search.php?cat=hd&kw_type=key&kw=%s' % enc)
        items = _parse_cards(html)
        return {'list': items, 'page': _norm_pg(pg), 'pagecount': 0, 'total': len(items)}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        if raw.startswith('leaks|'):
            rest = raw[len('leaks|'):]
            parts = rest.split('|')
            post_id = parts[0] if parts else ''
            try:
                index = int(parts[1]) if len(parts) > 1 else 0
            except Exception:
                index = 0
            body = json.dumps({'post_id': post_id, 'index': index}).encode('utf-8')
            try:
                txt, _u, _h = _raw(BASE + '/ajax/site/get_tg_video.php', headers={'Referer': BASE + '/leaks_zone.php', 'Content-Type': 'application/json', 'X-Requested-With': 'XMLHttpRequest'}, data=body, method='POST')
            except Exception:
                return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
            try:
                v = json.loads(txt or '{}')
            except Exception:
                v = {}
            url = (v.get('url') or '') if isinstance(v, dict) else ''
            if not url:
                return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
            return {'parse': 0, 'playUrl': url, 'url': url, 'header': {'User-Agent': UA, 'Referer': BASE + '/leaks_zone.php'}}
        parts = raw.split('|')
        uuid = parts[0] if parts else ''
        page_cat = parts[1] if len(parts) > 1 else '19'
        if not uuid:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        ref = {'User-Agent': UA, 'Referer': BASE + '/player.php?uuid=%s&cat=%s' % (uuid, page_cat)}
        url = ''
        if len(parts) >= 3 and parts[2] == 'preview':
            url = _get_preview(uuid, page_cat)
        elif len(parts) >= 7:
            url = _get_mv(uuid, page_cat, parts[2], parts[3], parts[4], parts[5], parts[6])
        else:
            html = _get_page('/player.php?uuid=%s&cat=%s' % (uuid, page_cat))
            segs = _parse_segments(html)
            if segs:
                seg = segs[0]
                url = _get_mv(uuid, page_cat, seg['ms_id'], seg['start'], seg['end'], seg['token'], seg['cat_id'])
        if not url:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': ref}
        return {'parse': 0, 'playUrl': url, 'url': url, 'header': ref}

    def localProxy(self, param):
        return [404, 'text/plain', '']

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
