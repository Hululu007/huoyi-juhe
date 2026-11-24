import base64
import gzip
import http.client
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

BASE = 'https://xhongyan.com'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

TIMEOUT = 70


def _proxy_target(url):
    parts = urllib.parse.urlsplit(url)
    scheme = (parts.scheme or 'http').lower()
    host = parts.hostname or ''
    proxies = urllib.request.getproxies()
    proxy_url = proxies.get(scheme) or proxies.get('all') or ''
    if not proxy_url or not host:
        return None
    try:
        if urllib.request.proxy_bypass(host):
            return None
    except Exception:
        pass
    return urllib.parse.urlsplit(proxy_url)


def _http_client_get(url, hdr, timeout):
    parts = urllib.parse.urlsplit(url)
    scheme = (parts.scheme or 'http').lower()
    host = parts.hostname or ''
    if not host:
        return None
    port = parts.port or (443 if scheme == 'https' else 80)
    path = parts.path or '/'
    if parts.query:
        path += '?' + parts.query
    proxy = _proxy_target(url)
    try:
        if proxy and scheme == 'https':
            conn = http.client.HTTPConnection(proxy.hostname, proxy.port or 80, timeout=timeout)
            tunnel = {}
            if proxy.username:
                raw_auth = urllib.parse.unquote(proxy.username) + ':' + urllib.parse.unquote(proxy.password or '')
                tunnel['Proxy-Authorization'] = 'Basic ' + base64.b64encode(raw_auth.encode('utf-8')).decode('ascii')
            conn.set_tunnel(host, port, headers=tunnel or None)
            conn.connect()
            conn.sock = CTX.wrap_socket(conn.sock, server_hostname=host)
        elif proxy:
            conn = http.client.HTTPConnection(proxy.hostname, proxy.port or 80, timeout=timeout)
            path = url
            if proxy.username:
                raw_auth = urllib.parse.unquote(proxy.username) + ':' + urllib.parse.unquote(proxy.password or '')
                hdr = dict(hdr)
                hdr['Proxy-Authorization'] = 'Basic ' + base64.b64encode(raw_auth.encode('utf-8')).decode('ascii')
        elif scheme == 'https':
            conn = http.client.HTTPSConnection(host, port, timeout=timeout, context=CTX)
        else:
            conn = http.client.HTTPConnection(host, port, timeout=timeout)
        try:
            conn.putrequest('GET', path, skip_host=True, skip_accept_encoding=True)
            host_hdr = host if (scheme == 'https' and port == 443) or (scheme == 'http' and port == 80) else '%s:%d' % (host, port)
            conn.putheader('Host', host_hdr)
            for key, val in hdr.items():
                conn.putheader(key, val)
            conn.putheader('Connection', 'keep-alive')
            conn.endheaders()
            resp = conn.getresponse()
            if resp.status in (301, 302, 303, 307, 308):
                loc = resp.getheader('Location')
                resp.read()
                if loc:
                    nxt = urllib.parse.urljoin(url, loc)
                    if nxt != url:
                        return _http_client_get(nxt, hdr, timeout)
                return None
            if resp.status != 200:
                try:
                    resp.read()
                except Exception:
                    pass
                return None
            chunks = []
            try:
                while True:
                    chunk = resp.read(65536)
                    if not chunk:
                        break
                    chunks.append(chunk)
            except Exception as ie:
                part = getattr(ie, 'partial', b'') or b''
                if part:
                    chunks.append(part)
            data = b''.join(chunks)
            enc = (resp.getheader('Content-Encoding') or '').lower()
            if enc == 'gzip' or data[:2] == b'\x1f\x8b':
                try:
                    data = gzip.decompress(data)
                except Exception:
                    pass
            return data.decode('utf-8', 'replace')
        finally:
            try:
                conn.close()
            except Exception:
                pass
    except Exception:
        return None


def _http_get(url, referer=None, timeout=TIMEOUT):
    hdr = {
        'User-Agent': UA,
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9',
    }
    if referer:
        hdr['Referer'] = referer
    best = None
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
            text = _http_client_get(url, hdr, timeout)
        if text is None:
            try:
                req = urllib.request.Request(url, headers=hdr)
                with urllib.request.urlopen(req, timeout=timeout, context=CTX) as resp:
                    if resp.status == 200:
                        try:
                            data = resp.read()
                        except Exception as ie:
                            data = getattr(ie, 'partial', b'') or b''
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
            if best is None or len(text) > len(best):
                best = text
            if '</html>' in text:
                return text
        if attempt < 2:
            try:
                time.sleep(1)
            except Exception:
                pass
    return best


def _fetch(path, referer=None):
    if path.startswith('http'):
        return _http_get(path, referer=referer or (BASE + '/'))
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
             .replace('\\/', '/')
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


_NAV_RE = re.compile(r'<a[^>]*href="/(?:index\.php)?/vod/type/id/(\d+)\.html"[^>]*>(.*?)</a>', re.S)
_ANCHOR_RE = re.compile(r'<a[^>]*href="/index\.php/vod/play/id/(\d+)/sid/1/nid/1\.html"[^>]*>(.*?)</a>', re.S)
_TITLE_RE = re.compile(r'title="([^"]+)"')
_SPAN_TITLE_RE = re.compile(r'<span class="title">([^<]+)</span>')
_ALT_RE = re.compile(r'alt="([^"]+)"')
_COVER_RE = re.compile(r'data-original="([^"]+)"')
_DATASRC_RE = re.compile(r'data-src="([^"]+)"')
_BGIMG_RE = re.compile(r'background-image:\s*url\((?:&quot;|"|&quot;)?([^)"\']+)')
_DUR_RE = re.compile(r'(\d+:\d{2}(?::\d{2})?)')
_PLAYER_RE = re.compile(r'var player_data=(\{.*?\})\s*</script>', re.S)
_TITLE_TAG_RE = re.compile(r'<title[^>]*>(.*?)</title>', re.S)
_POSTER_RE = re.compile(r'<img[^>]*src="(/upload/vod/[^"]+)"[^>]*>')
_SID_RE = re.compile(r'/index\.php/vod/play/id/(\d+)/sid/(\d+)/nid/1\.html')
_DESC_RE = re.compile(r'<meta name="description"[^>]*content="([^"]+)"')


def _parse_nav(html):
    out = []
    if not html:
        return out
    seen = set()
    for m in _NAV_RE.finditer(html):
        tid = m.group(1).strip()
        name = _unescape(re.sub(r'<[^>]+>', '', m.group(2))).strip()
        if not tid or not name or tid in seen:
            continue
        seen.add(tid)
        out.append((tid, name))
    return out


def _parse_cards(html):
    out = []
    if not html:
        return out
    seen = set()
    for m in _ANCHOR_RE.finditer(html):
        vid = m.group(1).strip()
        if not vid or vid in seen:
            continue
        tag = m.group(0)
        inner = m.group(2)
        tm = _SPAN_TITLE_RE.search(inner)
        title = _unescape(tm.group(1)) if tm else ''
        if not title:
            tm = _TITLE_RE.search(tag)
            title = _unescape(tm.group(1)) if tm else ''
        if not title:
            am = _ALT_RE.search(tag)
            title = _unescape(am.group(1)) if am else ''
        if not title:
            clean_inner = re.sub(r'<!--.*?-->', ' ', inner, flags=re.S)
            title = _unescape(re.sub(r'<[^>]+>', ' ', clean_inner)).strip()
            title = re.sub(r'\s+', ' ', title)
            dm0 = _DUR_RE.search(title)
            if dm0:
                title = title.replace(dm0.group(1), '').strip()
        cm = _BGIMG_RE.search(tag)
        if not cm:
            cm = _COVER_RE.search(tag)
        if not cm:
            cm = _DATASRC_RE.search(tag)
        if not cm:
            cm = re.search(r'src="([^"]+)"', tag)
        cover = _fix_url(cm.group(1).replace('&quot;', '').replace('&#34;', '').strip()) if cm else ''
        if 'lazyload.gif' in cover:
            cover = ''
        if not title:
            continue
        remark = ''
        dm = re.search(r'id="Duration">(\d+:\d{2}(?::\d{2})?)', inner)
        if not dm:
            dm = _DUR_RE.search(inner)
        if dm:
            remark = dm.group(1)
        seen.add(vid)
        out.append({
            'vod_id': vid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_remarks': remark,
        })
    return out


def _parse_player(html):
    if not html:
        return None
    m = _PLAYER_RE.search(html)
    if not m:
        return None
    try:
        return json.loads(m.group(1))
    except Exception:
        return None


def _text_of(obj, keys):
    if not isinstance(obj, dict):
        return ''
    for k in keys:
        v = obj.get(k)
        if isinstance(v, str) and v:
            return v
    return ''


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
        return 'X红颜'

    def getDependence(self):
        return []

    def init(self, extend=None):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=False):
        html = _fetch('/')
        cats = _parse_nav(html)
        return {
            'class': [{'type_id': cid, 'type_name': name} for cid, name in cats],
            'filters': {},
        }

    def homeVideoContent(self):
        html = _fetch('/')
        items = _parse_cards(html)
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        tid = _norm_id(tid).strip()
        pg = _norm_pg(pg)
        if pg < 1:
            pg = 1
        if not tid:
            html = _fetch('/')
            cats = _parse_nav(html)
            if cats:
                tid = cats[0][0]
            else:
                return {'list': [], 'page': pg, 'pagecount': 0, 'total': 0}
        if pg <= 1:
            path = '/index.php/vod/type/id/%s.html' % tid
        else:
            path = '/index.php/vod/type/id/%s/page/%d.html' % (tid, pg)
        html = _fetch(path)
        items = _parse_cards(html)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        nid = _norm_id(ids).strip()
        nid = ''.join([ch for ch in nid if ch.isdigit()])
        if not nid:
            return _empty_detail(nid)
        html = _fetch('/index.php/vod/detail/id/%s.html' % nid)
        if not html:
            return _empty_detail(nid)
        title = ''
        tm = _TITLE_TAG_RE.search(html)
        if tm:
            title = _unescape(re.sub(r'<[^>]+>', '', tm.group(1))).strip()
            if '详情介绍' in title:
                title = title.split('详情介绍')[0].strip()
        cover = ''
        pm = _POSTER_RE.search(html)
        if pm:
            cover = _fix_url(pm.group(1))
        desc = ''
        dm = _DESC_RE.search(html)
        if dm:
            desc = _unescape(dm.group(1))
            if desc.endswith('剧情:'):
                desc = desc[:-len('剧情:')].strip()
        parts = []
        seen = set()
        for sm in _SID_RE.finditer(html):
            if sm.group(1) != nid:
                continue
            sid = sm.group(2)
            if sid not in seen:
                seen.add(sid)
                parts.append(sid)
        parts.sort(key=lambda x: int(x))
        if not title:
            return _empty_detail(nid)
        if not parts:
            parts = ['1']
        if not cover:
            kw = title.split()[0] if title.split() else ''
            if not kw:
                kw = title[:12]
            if len(kw) > 20:
                kw = kw[:20]
            if kw:
                try:
                    sh = _fetch('/index.php/vod/search.html?wd=' + urllib.parse.quote_plus(kw))
                    if sh:
                        for item in _parse_cards(sh):
                            if item['vod_id'] == nid:
                                cover = item['vod_pic']
                                break
                except Exception:
                    cover = ''
        if len(parts) == 1:
            play_url = '播放$%s:%s' % (nid, parts[0])
        else:
            play_url = '#'.join('第%s部$%s:%s' % (i + 1, nid, sid) for i, sid in enumerate(parts))
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': '共%s部' % len(parts) if len(parts) > 1 else '',
            'vod_year': '',
            'vod_area': '',
            'vod_content': desc,
            'type_name': '',
            'vod_tag': '',
            'vod_play_from': '在线播放',
            'vod_play_url': play_url,
            'stills': [cover] if cover else [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        if pg < 1:
            pg = 1
        kw = urllib.parse.quote_plus(str(key).strip())
        html = _fetch('/index.php/vod/search.html?wd=' + kw)
        items = _parse_cards(html)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '').strip()
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        if not raw:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        if raw.startswith('http'):
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        nid = raw
        sid = '1'
        if ':' in raw:
            nid, sid = raw.split(':', 1)
        nid = ''.join([ch for ch in nid if ch.isdigit()])
        sid = ''.join([ch for ch in sid if ch.isdigit()]) or '1'
        if not nid:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        page_url = '/index.php/vod/play/id/%s/sid/%s/nid/1.html' % (nid, sid)
        html = _fetch(page_url)
        player = _parse_player(html)
        url = _text_of(player, ['url']) if player else ''
        url = _unescape(url)
        if url:
            url = _fix_url(url)
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
