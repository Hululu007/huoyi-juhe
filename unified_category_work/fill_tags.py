import json
import os

TREE = os.path.expanduser("~/workspace/huoyi_juhe")
ASSET = os.path.join(TREE, "assets", "unified_video_categories.json")
TPD = os.path.expanduser("~/workspace/tpd_harvest/all_stations_tags.json")


def main():
    with open(ASSET, "r", encoding="utf-8") as f:
        uni = json.load(f)
    with open(TPD, "r", encoding="utf-8") as f:
        tpd = json.load(f)

    old_categories = uni["categories"]
    old_without = list(uni.get("sites_without_categories", []))

    tags = {}
    seen_triples = set()
    stats = {
        "tpd_sites": len(tpd),
        "raw_entries": 0,
        "browsable_entries": 0,
        "non_browsable_skipped": 0,
        "exact_triple_dupes_dropped": 0,
        "empty_name_or_url_skipped": 0,
    }
    sites_with_tags = set()
    for site_id in sorted(tpd.keys()):
        entries = tpd[site_id].get("tags") or []
        for raw in entries:
            stats["raw_entries"] += 1
            if raw.get("browsable") is not True:
                stats["non_browsable_skipped"] += 1
                continue
            name = (raw.get("name") or "").strip()
            url = (raw.get("url") or "").strip()
            if not name or not url:
                stats["empty_name_or_url_skipped"] += 1
                continue
            stats["browsable_entries"] += 1
            triple = (name, site_id, url)
            if triple in seen_triples:
                stats["exact_triple_dupes_dropped"] += 1
                continue
            seen_triples.add(triple)
            sites_with_tags.add(site_id)
            tags.setdefault(name, []).append(
                {"siteId": site_id, "url": url, "browsable": True}
            )

    for name in tags:
        tags[name].sort(key=lambda e: (e["siteId"], e["url"]))
    ordered_tags = dict(
        sorted(tags.items(), key=lambda kv: (-len(kv[1]), kv[0]))
    )

    removed_from_without = sorted(set(old_without) & sites_with_tags)
    new_without = [s for s in old_without if s not in sites_with_tags]

    uni["tags"] = ordered_tags
    uni["total_site_count"] = 201
    uni["sites_without_categories"] = new_without
    uni["version"] = 2
    uni["source"] = (
        "core_cats_extracted.json (Rust module CATS) + tags from "
        "tpd_harvest/all_stations_tags.json (2026-11-06, browsable only)"
    )

    assert uni["categories"] == old_categories, "categories must be untouched"

    with open(ASSET, "w", encoding="utf-8") as f:
        json.dump(uni, f, ensure_ascii=False, separators=(",", ":"))

    stats["distinct_tag_names"] = len(ordered_tags)
    stats["kept_entries"] = sum(len(v) for v in ordered_tags.values())
    stats["sites_with_browsable_tags"] = len(sites_with_tags)
    stats["removed_from_without"] = removed_from_without
    stats["new_without_count"] = len(new_without)
    stats["site_count_unchanged"] = uni.get("site_count")
    print(json.dumps(stats, ensure_ascii=False, indent=2))
    print("asset bytes:", os.path.getsize(ASSET))


if __name__ == "__main__":
    main()
