#!/usr/bin/env python3
"""Met à jour altstore/source.json après une compilation.

AltStore refuse d'installer une app dont les permissions déclarées dans la source
ne correspondent pas à l'IPA : on les lit donc directement dans l'Info.plist de l'IPA
plutôt que de les recopier à la main.
"""
import argparse
import datetime as dt
import json
import os
import plistlib
import zipfile

KEEP_VERSIONS = 5

p = argparse.ArgumentParser()
p.add_argument("--ipa", required=True)
p.add_argument("--repo", required=True)          # owner/repo
p.add_argument("--version", required=True)
p.add_argument("--build", required=True)
p.add_argument("--notes", default="")
p.add_argument("--source", default="altstore/source.json")
a = p.parse_args()

with zipfile.ZipFile(a.ipa) as z:
    plist_name = next(n for n in z.namelist()
                      if n.startswith("Payload/") and n.endswith(".app/Info.plist") and n.count("/") == 2)
    info = plistlib.loads(z.read(plist_name))

privacy = {k: v for k, v in info.items() if k.startswith("NS") and k.endswith("UsageDescription")}
raw = f"https://raw.githubusercontent.com/{a.repo}/main/altstore"

source = {}
if os.path.exists(a.source):
    with open(a.source, encoding="utf-8") as f:
        source = json.load(f)

app = {
    "name": "Roamcast",
    "bundleIdentifier": info["CFBundleIdentifier"],
    "developerName": "LLCenLive",
    "subtitle": "Balade · Drone · Direct",
    "localizedDescription": "Live Twitch outdoor : caméra iPhone, DJI Mic Mini, musique, GPS, "
                            "et bascule vers le DJI Mini 2 sans couper le stream.",
    "iconURL": f"{raw}/icon.png",
    "tintColor": "#8B5CF6",
    "category": "photo-video",
    "appPermissions": {"entitlements": [], "privacy": privacy},
    "versions": [],
}
old_versions = next((x.get("versions", []) for x in source.get("apps", [])
                     if x.get("bundleIdentifier") == app["bundleIdentifier"]), [])

new_version = {
    "version": a.version,
    "buildVersion": a.build,
    "date": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "localizedDescription": a.notes or f"Build {a.build}",
    "downloadURL": f"https://github.com/{a.repo}/releases/download/v{a.version}/Roamcast.ipa",
    "size": os.path.getsize(a.ipa),
    "minOSVersion": info.get("MinimumOSVersion", "17.0"),
}
app["versions"] = [new_version] + [v for v in old_versions if v.get("version") != a.version][: KEEP_VERSIONS - 1]

source = {
    "name": "Roamcast (LLCenLive)",
    "identifier": "com.llcenlive.roamcast.source",
    "iconURL": f"{raw}/icon.png",
    "tintColor": "#8B5CF6",
    "apps": [app],
    "news": source.get("news", []),
}

os.makedirs(os.path.dirname(a.source), exist_ok=True)
with open(a.source, "w", encoding="utf-8") as f:
    json.dump(source, f, ensure_ascii=False, indent=2)
print(f"Source AltStore → {a.version} (build {a.build}), {len(privacy)} permissions")
