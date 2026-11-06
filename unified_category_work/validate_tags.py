import json
import os

TREE = os.path.expanduser("~/workspace/huoyi_juhe")
ASSET = os.path.join(TREE, "assets", "unified_video_categories.json")
BAK = os.path.join(TREE, "unified_category_work",
                   "unified_video_categories.v1.bak.json")


def dart_parse(text):
    try:
        decoded = json.loads(text)
    except Exception:
        return None
    if not isinstance(decoded, dict):
        return None
    cats = {}
    raw = decoded.get("categories")
    if isinstance(raw, dict):
        for name, val in raw.items():
            name = str(name).strip()
            if not name or not isinstance(val, list):
                continue
            sites = []
            for r in val:
                if not isinstance(r, dict):
                    continue
                sid = str(r.get("siteId") or "").strip()
                path = str(r.get("path") or "").strip()
                if sid and path:
                    sites.append((sid, path))
            if sites:
                cats[name] = sites
    tags = {}
    raw = decoded.get("tags")
    if isinstance(raw, dict):
        for name, val in raw.items():
            name = str(name).strip()
            if not name or not isinstance(val, list):
                continue
            sites = []
            for r in val:
                if not isinstance(r, dict):
                    continue
                sid = str(r.get("siteId") or "").strip()
                url = str(r.get("url") or "").strip()
                if not sid or not url or r.get("browsable") is not True:
                    continue
                sites.append((sid, url, True))
            if sites:
                tags[name] = sites
    elif isinstance(raw, list):
        for r in raw:
            if not isinstance(r, dict):
                continue
            name = str(r.get("name") or "").strip()
            sid = str(r.get("siteId") or "").strip()
            url = str(r.get("url") or "").strip()
            if not name or not sid or not url or r.get("browsable") is not True:
                continue
            tags.setdefault(name, []).append((sid, url, True))
    without = []
    raw = decoded.get("sites_without_categories")
    if isinstance(raw, list):
        for item in raw:
            s = str(item).strip()
            if s:
                without.append(s)
    return {
        "categories": cats,
        "tags": tags,
        "without": without,
        "site_count": decoded.get("site_count"),
        "total": decoded.get("total_site_count"),
        "version": decoded.get("version"),
    }


def main():
    with open(ASSET, "r", encoding="utf-8") as f:
        text = f.read()
    with open(BAK, "r", encoding="utf-8") as f:
        old = json.load(f)
    new = json.loads(text)
    assert new["categories"] == old["categories"], "categories changed!"
    assert old["tags"] == {}, "old tags were not empty"
    p = dart_parse(text)
    assert p is not None
    tag_entries = sum(len(v) for v in p["tags"].values())
    tag_sites = {s for v in p["tags"].values() for s, _, _ in v}
    cat_sites = {s for v in p["categories"].values() for s, _ in v}
    print("json legal: yes")
    print("version:", p["version"], "site_count:", p["site_count"],
          "total:", p["total"])
    print("categories names:", len(p["categories"]),
          "cat sites:", len(cat_sites))
    print("tag names parsed:", len(p["tags"]),
          "tag entries parsed:", tag_entries,
          "tag sites:", len(tag_sites))
    print("without list:", len(p["without"]))
    print("accounting: cats", len(cat_sites), "+ tags-only",
          len(tag_sites - cat_sites), "+ neither", len(p["without"]),
          "=", len(cat_sites) + len(tag_sites - cat_sites)
          + len(p["without"]))
    ranked = sorted(p["tags"].items(), key=lambda kv: (-len(kv[1]), kv[0]))
    print("top 10 tags by site count:")
    for name, sites in ranked[:10]:
        print("  ", name, len(sites), "sites:",
              sorted({s for s, _, _ in sites}))
    print("single-site tag names:", sum(1 for v in p["tags"].values()
                                         if len(v) == 1))
    print("asset bytes:", os.path.getsize(ASSET))
    for name in ["校服", "高跟鞋", "中出", "丝袜"]:
        print("TRACE", name, json.dumps(
            [{"siteId": s, "url": u} for s, u, _ in p["tags"].get(name, [])],
            ensure_ascii=False)[:600])
    for sid in ["avhwa", "herexxx", "kissjav"]:
        n = sum(1 for v in p["tags"].values() for s, _, _ in v if s == sid)
        print("site entries in parsed tags:", sid, n)


if __name__ == "__main__":
    main()
