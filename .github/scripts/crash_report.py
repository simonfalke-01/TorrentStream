import json, sys, glob, os

# Prints the useful part of a simulator crash report (.ips): reason, and the crashed thread's frames.
paths = sorted(glob.glob(os.path.expanduser("~/Library/Logs/DiagnosticReports/**/TorrentStream*.ips"), recursive=True))
if not paths:
    print("no crash report found")
    sys.exit(0)
for path in paths[-2:]:
    print("==", path)
    text = open(path).read()
    head, _, body = text.partition("\n")
    try:
        r = json.loads(body)
    except Exception:
        print(text[:6000])
        continue
    for key in ("exception", "termination", "asi", "lastExceptionBacktrace"):
        if key in r and key != "lastExceptionBacktrace":
            print(key, json.dumps(r[key])[:1500])
    images = r.get("usedImages", [])

    def frames(fs):
        for f in fs[:40]:
            img = images[f["imageIndex"]]["name"] if "imageIndex" in f and f["imageIndex"] < len(images) else "?"
            print("   ", img, f.get("symbol", hex(f.get("imageOffset", 0))), f.get("sourceFile", ""), f.get("sourceLine", ""))

    if "lastExceptionBacktrace" in r:
        print("last exception backtrace:")
        frames(r["lastExceptionBacktrace"])
    threads = r.get("threads", [])
    crashed = next((t for t in threads if t.get("triggered")), threads[0] if threads else None)
    if crashed:
        print("crashed thread:", crashed.get("name", ""), crashed.get("queue", ""))
        frames(crashed.get("frames", []))
