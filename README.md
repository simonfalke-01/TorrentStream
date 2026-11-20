# TorrentStream

An iOS app that plays shows and movies the moment you tap them, like a streaming service. Under the hood it streams
straight out of BitTorrent, but you never manage downloads, progress or storage.

* **Home**: a hero for what you're watching, **Continue Watching** with progress bars, and **My List** with posters.
* **Title pages**: artwork, synopsis and genres (from AniList and Cinemeta), one **Play / Resume / Play Episode N**
  button, and an episode list grouped by season. Folders and multi-video releases become seasons and episodes.
* **Search** (Nyaa): results read like titles (poster, show name, episode, quality, release group, availability).
  Sort by upload date, availability, popularity or size (sorted by the site across all pages), filter by category or
  trusted uploaders. Tap a result and its title page opens; tap Play and it starts within seconds.
* Add a **magnet link** (paste, or tap one in Safari) or a **.torrent file** (Files app, share sheet, or Add by Link).
* Seek anywhere: loading jumps to wherever you are watching.
* Built-in **VLC player** (MobileVLCKit): MKV, AVI, WebM, HEVC, etc., **audio-track switching**, **embedded subtitles**,
  **subtitle files shipped with the release** (auto-loaded), **load your own subtitle file**, subtitle/audio delay,
  playback speed.
* **One tap "Open in VLC"** hands the stream to the VLC for iOS app (TorrentStream keeps serving it in the background).
* Optional Apple AVPlayer engine (MP4/MOV, AirPlay, Picture in Picture), switchable mid-playback.
* **iOS 26 Liquid Glass** UI: glass tab bar and player controls, double-tap to skip ±10 s, resume where you left off,
  and Up Next autoplay.
* **Automatic cache**: an episode you haven't finished stays cached so resuming is instant; when you finish one, the
  next episode is fetched ahead of time. Least-recently-watched titles are cleared automatically to stay within a
  budget of a quarter of free space (2–20 GB). Titles stay in My List with their progress. Settings shows the cache
  size and a Clear Cache button; nothing else about storage is exposed.
* A fully cached episode can still be saved to Files or Photos from its long-press menu.

Requires **iOS 26** or later. Artwork lookups can be turned off in Settings (Show Artwork and Details).

## How it works

```
SwiftUI app ──► TorrentKit (pure Swift, no dependencies)
 │               ├─ Peer discovery: HTTP/UDP trackers, Mainline DHT, peer exchange
 │               ├─ Peer wire protocol + magnet metadata download (BEP 3/9/10/11/15/5)
 │               ├─ Streaming piece picker: readahead window at the playhead, file head/tail first,
 │               │  then sequential; slow blocks near the playhead are re-requested from other peers
 │               ├─ SHA-1 verified, sparse on-disk storage with resume
 │               └─ Loopback HTTP server (Range/seek support) ──► VLC / AVPlayer / VLC app
 ├─────────────► NyaaKit: nyaa.si search (HTML listing, server-side sort and pagination)
 └─────────────► CatalogKit: release-name parsing; posters and details from AniList (anime) and Cinemeta
```

The player just opens `http://127.0.0.1:<port>/stream/<infohash>/<file>`. Each HTTP range request blocks until the
needed pieces are downloaded and tells the engine where playback is, so loading follows playback and seeking.

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
CATALOG_LIVE=1 swift test --filter CatalogKitTests   # also checks AniList and Cinemeta lookups
swift run -c release tkcli "magnet:?xt=urn:btih:..."   # stream the head and middle of the biggest file, print stats
```

## Notes & limits
* Download-only client (does not upload pieces), IPv4, BitTorrent v1 / hybrid torrents.
* "Open in VLC" keeps TorrentStream alive in the background via a silent audio session — tap **Stop** in the
  banner when you're done.
* Only download content you have the right to download.
