# TorrentStream

An iOS app that streams video and audio straight out of a torrent — like VLC, but you don't wait for the download.

* **Search Nyaa** from the Search tab: results sorted by seeders, date, size, downloads, leechers or comments (sorted
  by the site across all pages), filtered by category or trusted uploaders. Tap a result to see its videos and play.
* Add a **magnet link** (paste, or tap one in Safari) or a **.torrent file** (Files app, share sheet, or the in-app picker).
* Browse the torrent's contents, tap a file, and it **starts playing within seconds** while it downloads.
* Torrents with **many videos or nested folders** (seasons, specials) open as folders; Play picks up the next
  unwatched episode.
* Seek anywhere — the download jumps to wherever you are watching.
* Built-in **VLC player** (MobileVLCKit): MKV, AVI, WebM, HEVC, etc., **audio-track switching**, **embedded subtitles**,
  **subtitle files from the torrent** (auto-loaded), **load your own subtitle file**, subtitle/audio delay, playback speed.
* **One tap "Open in VLC"** hands the stream to the VLC for iOS app (TorrentStream keeps serving it in the background).
* Optional Apple AVPlayer engine (MP4/MOV, AirPlay, Picture in Picture), switchable mid-playback.
* **iOS 26 Liquid Glass** UI: glass tab bar, glass player controls, a seek bar that shows which parts of the file
  are already downloaded, double-tap to skip ±10 s, resume where you left off, and Up Next autoplay for episodes.
* **Downloads tab**: active downloads with progress and a list of downloaded videos.
* Finished files can be **saved to Files, saved to Photos (MP4/MOV), or shared** instead of being discarded.
  Removing a torrent offers to save what's downloaded first.

Requires **iOS 26** or later.

## How it works

```
SwiftUI app ──► TorrentKit (pure Swift, no dependencies)
 │               ├─ Peer discovery: HTTP/UDP trackers, Mainline DHT, peer exchange
 │               ├─ Peer wire protocol + magnet metadata download (BEP 3/9/10/11/15/5)
 │               ├─ Streaming piece picker: readahead window at the playhead, file head/tail first,
 │               │  then sequential; slow blocks near the playhead are re-requested from other peers
 │               ├─ SHA-1 verified, sparse on-disk storage with resume
 │               └─ Loopback HTTP server (Range/seek support) ──► VLC / AVPlayer / VLC app
 └─────────────► NyaaKit: nyaa.si search (HTML listing, server-side sort and pagination)
```

The player just opens `http://127.0.0.1:<port>/stream/<infohash>/<file>`. Each HTTP range request blocks until the
needed pieces are downloaded and tells the engine where playback is, so downloading follows playback and seeking.

## Getting the app

### Option A — prebuilt IPA (no Mac needed)
Every push builds the app on GitHub Actions (macOS 26, Xcode 26). Download the **TorrentStream-unsigned-ipa** artifact from the
latest run on the Actions tab and install it with [Sideloadly](https://sideloadly.io) or
[AltStore](https://altstore.io), which sign it with your Apple ID.

### Option B — build with Xcode
```sh
# Xcode 26 or later
brew install xcodegen cocoapods
xcodegen generate
pod install
open TorrentStream.xcworkspace
```
Pick your team under *Signing & Capabilities*, choose your iPhone, and Run.
(If you skip `pod install` and open `TorrentStream.xcodeproj`, the app builds without VLC and uses AVPlayer only.)

## Engine development (macOS or Linux)
```sh
cd TorrentKit
swift test                      # unit + end-to-end loopback tests (fake seeder, magnet metadata, HTTP range streaming)
NYAA_LIVE=1 swift test --filter NyaaKitTests   # also checks sorting and paging against the live site
swift run -c release tkcli "magnet:?xt=urn:btih:..."   # stream the head and middle of the biggest file, print stats
```

## Notes & limits
* Download-only client (does not upload pieces), IPv4, BitTorrent v1 / hybrid torrents.
* "Open in VLC" keeps TorrentStream alive in the background via a silent audio session — tap **Stop** in the
  banner when you're done.
* Only download content you have the right to download.
