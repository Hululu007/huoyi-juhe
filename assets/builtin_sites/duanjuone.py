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


HOST = 'https://duanju.one'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

CATS = [
    ('all', '全部'),
    ('free', '免费'),
    ('vip', 'VIP / 积分'),
    ('completed', '已完结'),
]

CARD_HREF_RE = re.compile(r'href="https?://duanju\.one/drama/([^"]+)"')
IMG_RE = re.compile(r'<img[^>]*src="([^"]+)"')
EP_RE = re.compile(r'<a class="([^"]*)" href="[^"]*/ep/(\d+)"[^>]*aria-label="([^"]*)"')


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _strip_tags(s):
    if not s:
        return ''
    out = re.sub(r'<[^>]+>', '', s)
    return _html.unescape(out).replace('&nbsp;', ' ').strip()


def _http_get(url, referer=None, accept='text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8', timeout=25):
    h = {'User-Agent': UA, 'Accept': accept, 'Accept-Language': 'zh-CN,zh;q=0.9', 'Accept-Encoding': 'gzip, deflate'}
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


def _attr(block, name):
    marker = '%s="' % name
    p = block.find(marker)
    if p < 0:
        return ''
    s = p + len(marker)
    e = block.find('"', s)
    return block[s:e] if e >= 0 else ''


def _tag_text(block, tag):
    p = block.find('<%s' % tag)
    if p < 0:
        return ''
    after = block[p:]
    s = after.find('>')
    if s < 0:
        return ''
    s += 1
    close = '</%s>' % tag
    e = after.find(close, s)
    if e < 0:
        e = len(after)
    return _strip_tags(after[s:e])


def _span_text(block, cls):
    marker = 'class="%s' % cls
    p = block.find(marker)
    if p < 0:
        return ''
    after = block[p:]
    s = after.find('>')
    if s < 0:
        return ''
    s += 1
    e = after.find('<', s)
    if e < 0:
        e = len(after)
    return _strip_tags(after[s:e])


def _parse_cards(html):
    out = []
    seen = []
    for block in (html or '').split('<a class="drama-card"')[1:]:
        end = block.find('</a>')
        block = block[:end] if end >= 0 else block
        m = CARD_HREF_RE.search(block)
        if not m:
            continue
        slug = m.group(1)
        if slug in seen:
            continue
        seen.append(slug)
        title = _tag_text(block, 'h2')
        if not title:
            continue
        im = IMG_RE.search(block)
        cover = im.group(1) if im else ''
        bits = []
        badge = _span_text(block, 'badge')
        if badge:
            bits.append(badge)
        count = _span_text(block, 'episode-count')
        if count:
            bits.append(count)
        updated = _tag_text(block, 'p')
        if updated:
            bits.append(updated)
        p = block.find('class="card-tags"')
        if p >= 0:
            after = block[p:]
            tags = []
            for seg in after.split('<span>')[1:]:
                e = seg.find('</span>')
                if e >= 0:
                    t = _strip_tags(seg[:e])
                    if t:
                        tags.append(t)
            if tags:
                bits.append(' / '.join(tags))
        out.append({
            'vod_id': slug,
            'vod_name': title,
            'vod_pic': cover,
            'vod_remarks': ' · '.join(bits),
        })
    return out


def _poster_of(html):
    p = html.find('<video')
    if p >= 0:
        v = _attr(html[p:], 'poster')
        if v:
            return v
    marker = 'property="og:image"'
    p = html.find(marker)
    if p >= 0:
        after = html[p:]
        c = after.find('content="')
        if c >= 0:
            s = c + 9
            e = after.find('"', s)
            if e >= 0:
                return after[s:e]
    return ''


def _desc_of(html):
    p = html.find('class="drama-description-content"')
    if p < 0:
        return ''
    after = html[p:]
    end = after.find('</div>')
    seg = after[:end] if end >= 0 else after
    paras = []
    for chunk in seg.split('<p>')[1:]:
        e = chunk.find('</p>')
        if e >= 0:
            t = _strip_tags(chunk[:e])
            if t:
                paras.append(t)
    return '\n'.join(paras)


def _tags_of(html):
    p = html.find('class="series-tags"')
    if p < 0:
        return []
    after = html[p:]
    end = after.find('</div>')
    seg = after[:end] if end >= 0 else after
    tags = []
    for chunk in seg.split('<a ')[1:]:
        s = chunk.find('>')
        if s < 0:
            continue
        e = chunk.find('<', s + 1)
        if e < 0:
            continue
        t = _strip_tags(chunk[s + 1:e])
        if t:
            tags.append(t)
    return tags


def _catalog_url(tid, pg):
    if tid == 'free':
        base = HOST + '/?filter=free'
    elif tid == 'vip':
        base = HOST + '/?filter=vip'
    elif tid == 'completed':
        base = HOST + '/?filter=completed'
    else:
        base = HOST + '/'
    if pg <= 1:
        return base
    if '?' in base:
        return '%s&page=%s' % (base, pg)
    return '%s?page=%s' % (base, pg)


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
        return '短剧one'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cats(self):
        return list(CATS)

    def homeContent(self, filter=''):
        cats = self._cats()
        items = _parse_cards(_http_get(HOST + '/', referer=HOST + '/'))
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in cats],
            'list': items,
        }

    def homeVideoContent(self):
        items = _parse_cards(_http_get(HOST + '/', referer=HOST + '/'))
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        items = _parse_cards(_http_get(_catalog_url(tid, pg), referer=HOST + '/'))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        html = _http_get('%s/drama/%s' % (HOST, nid), referer=HOST + '/')
        if not html:
            return {'list': []}
        title = _tag_text(html, 'h1')
        if not title:
            p = html.find('<title>')
            if p >= 0:
                after = html[p + 7:]
                e = after.find('</title>')
                title = _strip_tags(after[:e] if e >= 0 else after)
                q = title.find('在线观看')
                if q >= 0:
                    title = title[:q].strip()
        if not title:
            return {'list': []}
        cover = _poster_of(html)
        desc = _desc_of(html)
        tags = _tags_of(html)
        views = ''
        p = html.find('class="series-views"')
        if p >= 0:
            after = html[p:]
            s = after.find('>')
            if s >= 0:
                e = after.find('<', s + 1)
                if e >= 0:
                    views = _strip_tags(after[s + 1:e])
        eps = []
        paid = []
        seen = []
        for m in EP_RE.finditer(html):
            cls = m.group(1)
            try:
                n = int(m.group(2))
            except Exception:
                continue
            if n in seen:
                continue
            seen.append(n)
            is_paid = 'episode-paid' in cls
            if is_paid:
                paid.append(n)
            label = '第%s集·VIP' % n if is_paid else '第%s集' % n
            eps.append('%s$duanjuone:%s:%s' % (label, nid, n))
        eps.sort(key=lambda x: int(x.rsplit(':', 1)[-1]))
        if not eps:
            eps = ['第1集$duanjuone:%s:1' % nid]
        remark_bits = []
        if tags:
            remark_bits.append(' / '.join(tags))
        remark_bits.append('共 %s 集' % len(eps))
        if paid:
            remark_bits.append('%s 集付费' % len(paid))
        if views:
            remark_bits.append(views)
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': ' · '.join(remark_bits),
            'vod_year': '',
            'vod_area': '',
            'vod_content': desc,
            'type_name': ' / '.join(tags),
            'vod_tag': ' / '.join(tags),
            'vod_play_from': '在线播放',
            'vod_play_url': '#'.join(eps),
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        url = '%s/?q=%s' % (HOST, urllib.parse.quote(key or ''))
        items = _parse_cards(_http_get(url, referer=HOST + '/'))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        if raw.startswith('duanjuone:'):
            raw = raw[len('duanjuone:'):]
        header = {'User-Agent': UA, 'Referer': HOST + '/'}
        url = ''
        if '.m3u8' in raw or '.mp4' in raw:
            url = raw
        else:
            if ':' in raw:
                slug, ep = raw.rsplit(':', 1)
            else:
                slug, ep = raw, '1'
            try:
                epn = int(ep)
            except Exception:
                epn = 1
            txt = _http_get('%s/player/drama/%s/ep/%s' % (HOST, slug, epn), referer=HOST + '/', accept='application/json')
            try:
                obj = json.loads(txt or '{}')
            except Exception:
                obj = {}
            can_watch = obj.get('canWatch') is True
            src = obj.get('src') or ''
            if can_watch and src:
                url = src.split('?')[0]
                header['Referer'] = '%s/drama/%s/ep/%s' % (HOST, slug, epn)
        return {'parse': 0, 'playUrl': url, 'url': url, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', '']

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
