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

HOST = 'https://javhdtube.com'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

CATS = [
    ('latest-updates', '最新更新'),
    ('4k', '4K'), ('asian', 'Asian'), ('asian2', 'Asian2'), ('ass', 'Ass'),
    ('ass-licking', 'Ass Licking'), ('ass-to-mouth', 'Ass To Mouth'), ('bed-sex', 'Bed Sex'),
    ('big-breasts', 'Big Breasts'), ('big-cock', 'Big Cock'), ('big-natural-tits', 'Big Natural Tits'),
    ('big-tits', 'Big Tits'), ('bikini', 'Bikini'), ('blonde', 'Blonde'),
    ('blowjob', 'Blowjob'), ('boyfriend', 'Boyfriend'), ('brunette', 'Brunette'),
    ('brunette2', 'Brunette2'), ('couple', 'Couple'), ('cum-in-mouth', 'Cum In Mouth'),
    ('cum-in-mouth2', 'Cum In Mouth2'), ('cum-in-pussy', 'Cum In Pussy'), ('cum-inside', 'Cum Inside'),
    ('cumshot', 'Cumshot'), ('cunnilingus', 'Cunnilingus'), ('dirty-talk', 'Dirty Talk'),
    ('doggystyle', 'Doggystyle'), ('double-blowjob', 'Double Blowjob'), ('exclusive', 'Exclusive'),
    ('facial', 'Facial'), ('facial-cumshot', 'Facial Cumshot'), ('finger-fuck', 'Finger Fuck'),
    ('girlfriend', 'Girlfriend'), ('hairy', 'Hairy'), ('hairy-pussy', 'Hairy Pussy'),
    ('handjob', 'Handjob'), ('hardcore', 'Hardcore'), ('hardcore2', 'Hardcore2'),
    ('hd', 'HD'), ('hot-milf', 'Hot Milf'), ('individual', 'Individual'),
    ('insertions', 'Insertions'), ('japanese', 'Japanese'), ('japanese-close-up', 'Japanese Close Up'),
    ('japanese2', 'Japanese2'), ('kissing', 'Kissing'), ('lesbian', 'Lesbian'),
    ('lingerie', 'Lingerie'), ('lingerie2', 'Lingerie2'), ('maid', 'Maid'),
    ('masturbating', 'Masturbating'), ('masturbation', 'Masturbation'), ('mature', 'Mature'),
    ('mature-woman', 'Mature Woman'), ('milf', 'Milf'), ('mini-skirt', 'Mini Skirt'),
    ('missionary', 'Missionary'), ('mmf', 'Mmf'), ('natural-boobs', 'Natural Boobs'),
    ('natural-tits', 'Natural Tits'), ('natural-tits2', 'Natural Tits2'), ('nipple-play', 'Nipple Play'),
    ('nurse', 'Nurse'), ('office-lady', 'Office Lady'), ('on-her-knees', 'On Her Knees'),
    ('open-pussy', 'Open Pussy'), ('outdoor', 'Outdoor'), ('panties', 'Panties'),
    ('perfect-ass', 'Perfect Ass'), ('pink-pussy', 'Pink Pussy'), ('pov', 'Pov'),
    ('pussy-licking', 'Pussy Licking'), ('pussy-to-mouth', 'Pussy To Mouth'), ('reality', 'Reality'),
    ('reverse-cowgirl', 'Reverse Cowgirl'), ('riding', 'Riding'), ('schoolgirl-18', 'Schoolgirl 18+'),
    ('shaved', 'Shaved'), ('shaved-pussy', 'Shaved Pussy'), ('skinny', 'Skinny'),
    ('small-cock', 'Small Cock'), ('small-tits', 'Small Tits'), ('squirting', 'Squirting'),
    ('standing-sex', 'Standing Sex'), ('stockings', 'Stockings'), ('sucking', 'Sucking'),
    ('talk', 'Talk'), ('tattoo', 'Tattoo'), ('teen-18', 'Teen 18+'),
    ('thong', 'Thong'), ('threesome', 'Threesome'), ('tit-fuck', 'Tit Fuck'),
    ('titjob', 'Titjob'), ('toys', 'Toys'), ('trimmed-pussy', 'Trimmed Pussy'),
    ('undressing', 'Undressing'), ('vibrator', 'Vibrator'), ('vr', 'VR'),
    ('wet-pussy', 'Wet Pussy'),
]

_JAR = http.cookiejar.CookieJar()
_OPENER = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(_JAR))


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _get(url, referer=None, timeout=30):
    h = {'User-Agent': UA, 'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'}
    if referer:
        h['Referer'] = referer
    for _ in range(3):
        try:
            req = urllib.request.Request(url, headers=h)
            with _OPENER.open(req, timeout=timeout, context=_ctx()) as resp:
                raw = resp.read()
                enc = (resp.headers.get('Content-Encoding') or '').lower()
                if enc == 'gzip' or raw[:2] == b'\x1f\x8b':
                    try:
                        raw = gzip.decompress(raw)
                    except Exception:
                        pass
                return raw.decode('utf-8', 'replace'), resp.geturl()
        except urllib.error.HTTPError as e:
            try:
                return e.read().decode('utf-8', 'ignore'), url
            except http.client.IncompleteRead as ie:
                return ie.partial.decode('utf-8', 'ignore'), url
        except Exception:
            time.sleep(1)
    return '', url


def _decode_entities(s):
    return _html.unescape(s or '').replace('&nbsp;', ' ').strip()


def _truncate(s, n):
    s = s or ''
    if len(s) > n:
        return s[:n]
    return s


def _parse_cards(html):
    out = []
    seen = set()
    for block in (html or '').split('<div class="item th">')[1:]:
        end = block.find('<div class="item th">')
        if end >= 0:
            block = block[:end]
        p = block.find('<a class="th-image-link" href="')
        if p < 0:
            continue
        s = p + 31
        e = block[s:].find('"')
        if e < 0:
            continue
        href = block[s:s + e]
        if '/video/' not in href or href in seen:
            continue
        title = ''
        p = block.find('title="')
        if p >= 0:
            s = p + 7
            e = block[s:].find('"')
            if e >= 0:
                title = _decode_entities(block[s:s + e])
        if not title:
            continue
        cover = ''
        p = block.find('data-original="')
        if p >= 0:
            s = p + 15
            e = block[s:].find('"')
            if e >= 0:
                cover = block[s:s + e]
        remark = ''
        p = block.find('<span class="th-duration">')
        if p >= 0:
            s = p + 26
            e = block[s:].find('</span>')
            if e >= 0:
                remark = block[s:s + e].strip()
        seen.add(href)
        out.append({'vod_id': href, 'vod_name': _truncate(title, 90), 'vod_pic': cover, 'vod_remarks': remark})
    return out


def _catalog_url(tid, pg):
    slug = tid or 'latest-updates'
    if slug == 'latest-updates':
        base = HOST + '/latest-updates/'
    else:
        base = HOST + '/categories/%s/' % slug
    if pg <= 1:
        return base
    return base + '%d/' % pg


def _meta_content(html, attr, key):
    marker = '%s="%s"' % (attr, key)
    p = html.find(marker)
    if p < 0:
        return ''
    after = html[p:]
    c = after.find('content="')
    if c < 0:
        return ''
    s = c + 9
    e = after[s:].find('"')
    return _decode_entities(after[s:s + e]) if e >= 0 else ''


def _extract_video_url(html):
    marker = "video_url: '"
    p = html.find(marker)
    if p < 0:
        return ''
    s = p + len(marker)
    e = html[s:].find("'")
    return html[s:s + e] if e >= 0 else ''


def _extract_video_url_720p(html):
    marker = '_720p.mp4/?v-acctoken='
    p = html.find(marker)
    if p < 0:
        return ''
    start = html[:p].rfind('https://')
    if start < 0:
        start = 0
    rest = html[start:]
    end = len(rest)
    for c in ('"', "'", '<', ' ', '\n', '\r', '\t'):
        i = rest.find(c)
        if 0 <= i < end:
            end = i
    return rest[:end]


def _format_duration(seconds):
    if seconds <= 0:
        return ''
    h = seconds // 3600
    m = (seconds % 3600) // 60
    s = seconds % 60
    if h > 0:
        return '%d:%02d:%02d' % (h, m, s)
    return '%d:%02d' % (m, s)


def _video_duration(html):
    marker = 'duration" content="'
    p = html.find(marker)
    if p < 0:
        return ''
    s = p + len(marker)
    e = html[s:].find('"')
    if e < 0:
        return ''
    try:
        return _format_duration(int(html[s:s + e].strip()))
    except Exception:
        return ''


def _resolve_redirect(url, referer):
    try:
        txt, final = _get(url, referer=referer)
        if final != url and len(final) > 20:
            return final
    except Exception:
        pass
    return url


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
        return 'JAVHDTube'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=''):
        html, _ = _get(HOST + '/latest-updates/', referer=HOST + '/')
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in CATS],
            'list': _parse_cards(html),
        }

    def homeVideoContent(self):
        html, _ = _get(HOST + '/latest-updates/', referer=HOST + '/')
        return {'list': _parse_cards(html), 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        tid = _norm_id(tid) or 'latest-updates'
        html, _ = _get(_catalog_url(tid, pg), referer=HOST + '/')
        items = _parse_cards(html)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': len(items)}

    def detailContent(self, ids):
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        page_url = nid if nid.startswith('http') else HOST + nid.lstrip('/')
        html, _ = _get(page_url, referer=HOST + '/')
        title = _meta_content(html, 'property', 'og:title')
        if not title:
            return {'list': []}
        cover = _meta_content(html, 'property', 'og:image')
        desc = _meta_content(html, 'name', 'description')
        duration = _video_duration(html)
        eps = []
        url_720p = _extract_video_url_720p(html)
        url_480p = _extract_video_url(html)
        if url_720p:
            eps.append('720p$%s' % url_720p)
        if url_480p:
            eps.append('正片$%s' % url_480p)
        if not eps:
            eps.append('正片$%s' % page_url)
        return {'list': [{
            'vod_id': page_url,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': duration,
            'vod_year': '',
            'vod_area': '',
            'vod_content': _truncate(desc, 400),
            'type_name': '',
            'vod_tag': '',
            'vod_play_from': '在线播放',
            'vod_play_url': '#'.join(eps),
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        url = HOST + '/search/%s/' % urllib.parse.quote((key or '').strip(), safe='')
        html, _ = _get(url, referer=HOST + '/')
        items = _parse_cards(html)[:60]
        return {'list': items, 'page': _norm_pg(pg), 'pagecount': 0, 'total': len(items)}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        header = {'User-Agent': UA, 'Referer': HOST + '/'}
        if '.mp4' in raw:
            url = _resolve_redirect(raw, HOST + '/')
            return {'parse': 0, 'playUrl': url, 'url': url, 'header': header}
        page_url = raw.split('$')[-1] if '$' in raw else raw
        html, _ = _get(page_url, referer=HOST + '/')
        url = _extract_video_url(html)
        if not url:
            url = _extract_video_url_720p(html)
        if not url:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        url = _resolve_redirect(url, page_url)
        return {'parse': 0, 'playUrl': url, 'url': url, 'header': {'User-Agent': UA, 'Referer': page_url}}

    def localProxy(self, param):
        return [404, 'text/plain', '']

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
