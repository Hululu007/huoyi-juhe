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

HOST = 'https://javmit.com'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

CATS = [
    ('creampie', 'CREAMPIE'),
    ('solowork', 'SOLOWORK'),
    ('big-tits', 'BIG TITS'),
    ('married', 'MARRIED'),
    ('amateur', 'AMATEUR'),
    ('blowjob', 'BLOWJOB'),
    ('slut', 'SLUT'),
    ('ol', 'OL'),
    ('beautiful-girl', 'BEAUTIFUL GIRL'),
    ('slender', 'SLENDER'),
    ('pov', 'POV'),
    ('boobs-fetish', 'BOOBS FETISH'),
    ('3p', '3P'),
    ('mature', 'MATURE'),
    ('squirting', 'SQUIRTING'),
    ('orgasm', 'ORGASM'),
    ('big-breasts', 'BIG BREASTS'),
    ('individual', 'INDIVIDUAL'),
    ('cuckold', 'CUCKOLD'),
    ('mature-woman', 'MATURE WOMAN'),
    ('back', 'BACK'),
    ('drama', 'DRAMA'),
    ('schoolgirls', 'SCHOOLGIRLS'),
    ('cunnilingus', 'CUNNILINGUS'),
    ('facials', 'FACIALS'),
    ('big-butt', 'BIG BUTT'),
    ('uniform', 'UNIFORM'),
    ('kissing', 'KISSING'),
    ('cowgirl', 'COWGIRL'),
    ('titty-fuck', 'TITTY FUCK'),
    ('orgy', 'ORGY'),
    ('toy', 'TOY'),
    ('documentary', 'DOCUMENTARY'),
    ('nasty', 'NASTY'),
    ('deep-throat', 'DEEP THROAT'),
    ('mother', 'MOTHER'),
    ('uncategorized', 'UNCATEGORIZED'),
    ('cosplay', 'COSPLAY'),
    ('affair', 'AFFAIR'),
    ('shaved', 'SHAVED'),
    ('humiliation', 'HUMILIATION'),
    ('bukkake', 'BUKKAKE'),
    ('subtitles', '字幕付き'),
    ('debut-production', 'DEBUT PRODUCTION'),
    ('handjob', 'HANDJOB'),
    ('anal', 'ANAL'),
    ('original', 'ORIGINAL'),
    ('planning', 'PLANNING'),
    ('pantyhose', 'PANTYHOSE'),
    ('voyeur', 'VOYEUR'),
    ('incest', 'INCEST'),
    ('dirty-talk', 'DIRTY TALK'),
    ('other-fetish', 'OTHER FETISH'),
    ('lotion', 'LOTION'),
    ('lesbian', 'LESBIAN'),
    ('gal', 'GAL'),
    ('cum', 'CUM'),
    ('nampa', 'NAMPA'),
    ('transsexual', 'TRANSSEXUAL'),
    ('urination', 'URINATION'),
    ('sweat', 'SWEAT'),
    ('mini', 'MINI'),
    ('close-up', 'CLOSE UP'),
    ('cross-dressing', 'CROSS DRESSING'),
    ('big-breast-fetish', 'BIG BREAST FETISH'),
    ('beauty-shop', 'BEAUTY SHOP'),
    ('outdoors', 'OUTDOORS'),
    ('leg-fetish', 'LEG FETISH'),
    ('action', 'ACTION'),
    ('bbw', 'BBW'),
    ('special-effects', 'SPECIAL EFFECTS'),
    ('school-uniform', 'SCHOOL UNIFORM'),
    ('busty-fetish', 'BUSTY FETISH'),
    ('vibe', 'VIBE'),
    ('lesbian-kiss', 'LESBIAN KISS'),
    ('huge-butt', 'HUGE BUTT'),
    ('4hr', '4HR'),
    ('prank', 'PRANK'),
    ('petite', 'PETITE'),
    ('drug', 'DRUG'),
    ('foot-fetish', 'FOOT FETISH'),
    ('panty-flash', 'PANTY FLASH'),
    ('butt-fetish', 'BUTT FETISH'),
    ('bunny-girl', 'BUNNY GIRL'),
    ('old-friend', 'OLD FRIEND'),
    ('loli', 'LOLI'),
    ('hardcore', 'HARDCORE'),
    ('69', '69'),
    ('hd', 'HD'),
    ('dance', 'DANCE'),
    ('rape', 'RAPE'),
    ('black-actor', 'BLACK ACTOR'),
    ('digital-mosaic', 'DIGITAL MOSAIC'),
    ('hentai-collab', 'HENTAI COLLAB'),
    ('4k', '4K'),
]


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _http_get(url, referer=None, timeout=25):
    h = {'User-Agent': UA, 'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8', 'Accept-Language': 'en-US,en;q=0.9', 'Accept-Encoding': 'gzip, deflate'}
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


def _decode_entities(s):
    return _html.unescape(s or '').replace('&nbsp;', ' ').strip()


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


def _clean_card_title(raw):
    s = _decode_entities(raw)
    i = s.find('[Download and Stream]')
    if i >= 0:
        s = s[:i].strip()
    return _trunc(s, 90)


def _cards(html):
    out = []
    seen = set()
    for block in (html or '').split('<article class="v-card"')[1:]:
        end = block.find('</article>')
        block = block[:end] if end >= 0 else block
        p = block.find('<a href="https://javmit.com/')
        if p < 0:
            continue
        s = p + 9
        e = block[s:].find('"')
        if e < 0:
            continue
        href = block[s:s + e]
        if href.endswith('/feed/') or '/category/' in href or '/tag/' in href:
            continue
        if href in seen:
            continue
        p2 = block.find('alt="')
        if p2 < 0:
            continue
        s2 = p2 + 5
        e2 = block[s2:].find('"')
        title = _clean_card_title(block[s2:s2 + e2]) if e2 >= 0 else ''
        if not title:
            continue
        cover = ''
        p3 = block.find('src="https://javmit.com/wp-content/uploads/')
        if p3 >= 0:
            s3 = p3 + 5
            e3 = block[s3:].find('"')
            if e3 >= 0:
                cover = block[s3:s3 + e3]
        remark = ''
        p4 = block.find('<div class="vc-dur">')
        if p4 >= 0:
            s4 = p4 + 20
            e4 = block[s4:].find('</div>')
            if e4 >= 0:
                remark = block[s4:s4 + e4].strip()
        seen.add(href)
        out.append({'vod_id': href, 'vod_name': title, 'vod_pic': cover, 'vod_remarks': remark})
    return out


def _catalog_url(slug, pg):
    slug = slug or 'creampie'
    if pg <= 1:
        return '%s/category/%s/' % (HOST, slug)
    return '%s/category/%s/page/%d/' % (HOST, slug, pg)


def _meta(html, attr, key):
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
    if e < 0:
        return ''
    return _decode_entities(after[s:s + e])


def _detail_cover(html):
    marker = 'src="https://javmit.com/wp-content/uploads/'
    rest = html
    while True:
        p = rest.find(marker)
        if p < 0:
            return ''
        s = p + 5
        e = rest[s:].find('"')
        if e >= 0:
            url = rest[s:s + e]
            if '-cover' in url:
                return url
        rest = rest[p + 1:]


def _fmt_duration(sec):
    try:
        sec = int(sec)
    except Exception:
        return ''
    if sec <= 0:
        return ''
    h = sec // 3600
    m = (sec % 3600) // 60
    s = sec % 60
    if h > 0:
        return '%d:%02d:%02d' % (h, m, s)
    return '%d:%02d' % (m, s)


def _video_duration(html):
    marker = 'video:duration" content="'
    p = html.find(marker)
    if p < 0:
        return ''
    s = p + len(marker)
    e = html[s:].find('"')
    if e < 0:
        return ''
    return _fmt_duration(html[s:s + e])


class Spider(BaseSpider):
    def getName(self):
        return 'JAVMIT'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _catalog(self, tid, pg):
        return _cards(_http_get(_catalog_url(tid, pg), referer=HOST + '/'))

    def homeContent(self, filter=''):
        cats = list(CATS)
        items = self._catalog(cats[0][0], 1) if cats else []
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in cats],
            'list': items,
        }

    def homeVideoContent(self):
        cats = list(CATS)
        items = self._catalog(cats[0][0], 1) if cats else []
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        items = self._catalog(_norm_id(tid), pg)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        if nid.startswith('http'):
            page_url = nid
        else:
            page_url = '%s/%s/' % (HOST, nid.strip('/'))
        html = _http_get(page_url, referer=HOST + '/')
        if not html:
            return {'list': []}
        title = _meta(html, 'property', 'og:title')
        i = title.find(' - JAVMIT')
        if i >= 0:
            title = title[:i].strip()
        if not title:
            return {'list': []}
        cover = _detail_cover(html)
        desc = _trunc(_meta(html, 'name', 'description'), 400)
        duration = _video_duration(html)
        parts = []
        if desc:
            parts.append(desc)
        if duration:
            parts.append('时长：' + duration)
        play_title = _trunc(title, 60)
        return {'list': [{
            'vod_id': page_url,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': duration,
            'vod_year': '',
            'vod_area': '',
            'vod_content': '\n'.join(parts),
            'type_name': '',
            'vod_tag': '',
            'vod_play_from': '在线播放',
            'vod_play_url': '%s$%s' % (play_title, page_url),
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        url = '%s/?s=%s' % (HOST, urllib.parse.quote(str(key or '').strip()))
        html = _http_get(url, referer=HOST + '/')
        return {'list': _cards(html)[:60], 'page': _norm_pg(pg), 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        header = {'User-Agent': UA, 'Referer': HOST + '/'}
        if '.m3u8' in raw:
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        page_url = raw.split('$')[-1].strip()
        html = _http_get(page_url, referer=HOST + '/')
        m3u8 = ''
        if html:
            m = re.search(r'property="og:video" content="([^"]+\.m3u8[^"]*)"', html)
            if m:
                m3u8 = m.group(1)
        if m3u8:
            header['Referer'] = page_url
            return {'parse': 0, 'playUrl': m3u8, 'url': m3u8, 'header': header}
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
