# TorrentStream

An iOS app that plays shows and movies the moment you tap them, like a streaming service. Under the hood it streams
straight out of BitTorrent, but you never manage downloads, progress or storage.

* **A catalog, not a search box**: Home opens on shelves (Trending Now, New This Season, Popular, Top Rated, Movies)
  from AniList, the same database that covers what Nyaa carries (anime). Search finds any show or movie by name; it
  runs on Kitsu, which has no request limit, so typing never gets throttled (AniList is the fallback).
* **Show pages**: poster, synopsis, genres, one **Play / Resume / Play S2 E5** button, My List, and every season with
  its episodes (names and stills from Kitsu). Tap an episode and it plays. Progress is saved per episode, and Continue
  Watching picks up where you stopped.
* **Sources are found for you**: when you press Play, TorrentStream searches Nyaa for that episode, parses every
  release name (show, season, episode, absolute numbering, batches, resolution, codec, source, audio, subtitles,
  group, in the spirit of Sonarr's parser), rejects wrong seasons, specials and movies, ranks the rest by your
  preferred quality and audio, availability and size, and opens the best one that starts. Season packs are reused for
  the next episodes, and the release group you watched is preferred for the rest of the show.
* **Choose Version**: touch and hold an episode (or use the player's More menu) to see every release found, grouped by
  resolution, with encoding, source, audio, subtitles, size and availability. Switching mid-episode keeps your place.
* **Settings**: preferred quality (4K, 1080p, 720p, 480p) and audio (Japanese with subtitles, or English dub).
* Home also keeps a hero for what you're watching and **My List** with posters.
* Add a **magnet link** (paste, or tap one in Safari) or a **.torrent file** (Files app, share sheet, or Add by Link).
* Seek anywhere: loading jumps to wherever you are watching.
* Built-in **VLC player** (MobileVLCKit): MKV, AVI, WebM, HEVC, etc., **audio-track switching**, **embedded subtitles**,
  **subtitle files shipped with the release** (auto-loaded), **load your own subtitle file**, subtitle/audio delay,
  playback speed.
* **One tap "Open in VLC"** hands the stream to the VLC for iOS app (TorrentStream keeps serving it in the background).
* Optional Apple AVPlayer engine (MP4/MOV, AirPlay, Picture in Picture), switchable mid-playback.
* **iOS 26 Liquid Glass** UI: glass tab bar and player controls, double-tap to skip ±10 s, resume where you left off,
  and Up Next autoplay.
* **Automatic cache, sized like a streaming service**: playback loads up to about ten minutes ahead (from the video's
  bitrate, capped at 1 GB), and the first few minutes of the next episode are loaded as soon as an episode starts, so
  Up Next is instant. Nothing else is fetched in the background. What was
  loaded stays cached, so resuming is instant; the titles watched longest ago are cleared to stay within the cache
  size from Settings (2, 5 or 10 GB, default 5 GB, never more than a quarter of free space). Titles stay in My List
  with their progress.
* A fully cached episode can still be saved to Files or Photos from its long-press menu.

Requires **iOS 26** or later. Artwork lookups for titles added by link can be turned off in Settings (Show Artwork and Details).

## How it works

```
SwiftUI app ──► TorrentKit (pure Swift, no dependencies)
 │               ├─ Peer discovery: HTTP/UDP trackers, Mainline DHT, peer exchange
 │               ├─ Peer wire protocol + magnet metadata download (BEP 3/9/10/11/15/5)
 │               ├─ Streaming piece picker: readahead window at the playhead, file head/tail first,
 │               │  then sequential; slow blocks near the playhead are re-requested from other peers
 │               ├─ SHA-1 verified, sparse on-disk storage with resume
 │               └─ Loopback HTTP server (Range/seek support) ──► VLC / AVPlayer / VLC app
 ├─────────────► CatalogKit: search (Kitsu), rows, seasons and episodes (AniList + Kitsu episode names); name parsing
 ├─────────────► NyaaKit: nyaa.si search (HTML listing, server-side sort and pagination)
 └─────────────► SourceKit: episode → Nyaa queries, release matching and ranking, picking the file inside a pack
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
CATALOG_LIVE=1 swift test --filter CatalogKitTests   # also checks AniList, Kitsu and Cinemeta lookups
NYAA_LIVE=1 swift test --filter SourceKitTests       # finds and ranks real releases for a known episode
swift run -c release tkcli "magnet:?xt=urn:btih:..."   # stream the head and middle of the biggest file, print stats
```

## Notes & limits
* The catalog is anime only, because that is what Nyaa carries. Matching releases to episodes is heuristic: shows
  whose release groups number seasons differently from AniList (split cours, absolute numbering) can occasionally
  pick the wrong file; Choose Version lists everything found.
* Download-only client (does not upload pieces), IPv4, BitTorrent v1 / hybrid torrents.
* "Open in VLC" keeps TorrentStream alive in the background via a silent audio session — tap **Stop** in the
  banner when you're done.
* Only download content you have the right to download.
