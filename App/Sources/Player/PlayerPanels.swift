import SwiftUI
import CatalogKit

enum PlayerPanel: String, Identifiable {
    case tracks, chapters, episodes
    var id: String { rawValue }
}

/// A dark glass panel over the video: along the trailing edge in landscape, along the bottom in portrait.
/// The video keeps playing beside it.
struct PlayerPanelFrame<Content: View>: View {
    let title: String
    let isLandscape: Bool
    var isWide = false
    let onClose: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Space.s)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: PlayerMetrics.control, height: PlayerMetrics.control)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(.leading, Space.l)
            .padding(.trailing, Space.xs)
            .padding(.top, Space.xs)

            content
        }
        .foregroundStyle(.white)
        .frame(width: isLandscape ? (isWide ? PlayerMetrics.panelWideWidth : PlayerMetrics.panelSideWidth) : nil)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular.tint(.black.opacity(0.45)), in: .rect(cornerRadius: Radius.large))
    }
}

// MARK: - Audio & Subtitles

struct TracksPanel: View {
    @ObservedObject var engine: PlaybackEngine
    @ObservedObject var secondary: SecondarySubtitles
    let isLandscape: Bool
    let onAddFile: () -> Void

    var body: some View {
        if isLandscape {
            HStack(alignment: .top, spacing: Space.s) {
                ScrollView { audio }
                ScrollView { subtitles }
                if !secondary.options.isEmpty { ScrollView { second } }
            }
            .scrollIndicators(.hidden)
            .padding(.horizontal, Space.s)
            .padding(.bottom, Space.s)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    audio
                    subtitles
                    if !secondary.options.isEmpty { second }
                }
                .padding(.horizontal, Space.s)
                .padding(.bottom, Space.l)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var audio: some View {
        TrackColumn(title: "Audio") {
            if engine.audioTracks.isEmpty {
                TrackRow(title: "Default", detail: nil, selected: true) {}
                    .disabled(true)
            }
            ForEach(engine.audioTracks) { t in
                TrackRow(title: t.title, detail: t.detail, selected: t.id == engine.currentAudio) { engine.selectAudio(t.id) }
            }
            if engine.audioTracks.count > 0 {
                TimingControl(title: "Audio Timing", value: engine.audioDelay, step: 0.05) { engine.setAudioDelay($0) }
            }
        }
    }

    private var subtitles: some View {
        TrackColumn(title: "Subtitles") {
            if engine.subtitleTracks.isEmpty {
                TrackRow(title: "Off", detail: nil, selected: true) {}
                    .disabled(true)
            }
            ForEach(engine.subtitleTracks) { t in
                TrackRow(title: t.title, detail: t.detail, selected: t.id == engine.currentSubtitle) { engine.selectSubtitle(t.id) }
            }
            Button(action: onAddFile) {
                Label("Add From Files…", systemImage: "plus")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, Space.s)
                    .frame(maxWidth: .infinity, minHeight: PlayerMetrics.control, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.8))
            if engine.currentSubtitle != MediaTrack.offID {
                TimingControl(title: "Subtitle Timing", value: engine.subtitleDelay, step: 0.1) { engine.setSubtitleDelay($0) }
            }
        }
    }

    private var second: some View {
        TrackColumn(title: "Second Subtitles") {
            TrackRow(title: "Off", detail: nil, selected: secondary.selected == nil) { secondary.select(nil) }
            ForEach(secondary.options) { o in
                TrackRow(title: o.title, detail: nil, selected: secondary.selected == o.id) { secondary.select(o.id) }
            }
            if secondary.selected != nil {
                TimingControl(title: "Timing", value: secondary.delay, step: 0.1) { secondary.setDelay($0) }
            }
        }
    }
}

private struct TrackColumn<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, Space.s)
                .padding(.bottom, Space.xs)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One choice: a check when selected, the name, and its language when the name is something else.
private struct TrackRow: View {
    let title: String
    let detail: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .opacity(selected ? 1 : 0)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.body.weight(selected ? .semibold : .regular))
                        .lineLimit(2)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.s)
            .frame(minHeight: PlayerMetrics.control)
            .background(selected ? Color.white.opacity(0.12) : .clear, in: .rect(cornerRadius: Radius.small))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Shifts a track earlier or later in small steps. Tapping the value puts it back in sync.
private struct TimingControl: View {
    let title: String
    let value: Double
    let step: Double
    let onChange: (Double) -> Void

    private var text: String {
        abs(value) < 0.001 ? "In Sync" : String(format: step < 0.1 ? "%+.2f s" : "%+.1f s", value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
            HStack(spacing: 0) {
                Button { onChange(max(-60, value - step)) } label: {
                    Image(systemName: "minus")
                        .frame(width: PlayerMetrics.control, height: PlayerMetrics.control)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Earlier")
                Button { onChange(0) } label: {
                    Text(text)
                        .font(.subheadline.weight(.medium).monospacedDigit())
                        .frame(maxWidth: .infinity, minHeight: PlayerMetrics.control)
                        .contentShape(.rect)
                }
                .disabled(abs(value) < 0.001)
                .accessibilityLabel("Reset")
                Button { onChange(min(60, value + step)) } label: {
                    Image(systemName: "plus")
                        .frame(width: PlayerMetrics.control, height: PlayerMetrics.control)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Later")
            }
            .buttonStyle(.plain)
            .font(.subheadline.weight(.semibold))
            .background(Color.white.opacity(0.08), in: .capsule)
        }
        .padding(.horizontal, Space.s)
        .padding(.top, Space.m)
        .accessibilityElement(children: .contain)
        .accessibilityValue(text)
    }
}

// MARK: - Chapters

struct ChaptersPanel: View {
    let chapters: [Chapter]
    let current: Int?
    let onSelect: (Chapter) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.xxs) {
                    ForEach(chapters) { c in
                        Button { onSelect(c) } label: {
                            HStack(spacing: Space.m) {
                                Text(c.name)
                                    .font(.body.weight(c.id == current ? .semibold : .regular))
                                    .lineLimit(2)
                                Spacer(minLength: Space.s)
                                Text(Format.seconds(c.start))
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                            .padding(.horizontal, Space.m)
                            .frame(minHeight: PlayerMetrics.control)
                            .background(c.id == current ? Color.white.opacity(0.12) : .clear, in: .rect(cornerRadius: Radius.small))
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .id(c.id)
                        .accessibilityAddTraits(c.id == current ? .isSelected : [])
                    }
                }
                .padding(.horizontal, Space.s)
                .padding(.bottom, Space.m)
            }
            .scrollIndicators(.hidden)
            .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
        }
    }
}

// MARK: - Episodes

struct EpisodesPanel: View {
    let details: ShowDetails
    let playing: ShowPlayback
    @EnvironmentObject private var shows: ShowsModel
    @State private var seasonID: Int?
    let onSelect: (ShowSeason, ShowEpisode) -> Void

    var body: some View {
        let season = details.season(id: seasonID ?? playing.seasonID) ?? details.seasons.first
        VStack(alignment: .leading, spacing: Space.s) {
            if details.seasons.count > 1 {
                Picker("Season", selection: Binding(get: { season?.id ?? 0 }, set: { seasonID = $0 })) {
                    ForEach(details.seasons) { s in Text("Season \(s.number)").tag(s.id) }
                }
                .pickerStyle(.menu)
                .tint(.white)
                .padding(.horizontal, Space.s)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Space.xxs) {
                        ForEach(season?.episodes ?? []) { e in
                            if let season { row(season, e).id(e.number) }
                        }
                    }
                    .padding(.horizontal, Space.s)
                    .padding(.bottom, Space.m)
                }
                .scrollIndicators(.hidden)
                .onAppear { proxy.scrollTo(playing.episode, anchor: .center) }
            }
        }
    }

    private func row(_ s: ShowSeason, _ e: ShowEpisode) -> some View {
        let isCurrent = s.id == playing.seasonID && e.number == playing.episode
        let p = shows.progress(details.show, s, e)
        return Button { onSelect(s, e) } label: {
            HStack(alignment: .top, spacing: Space.m) {
                VStack(spacing: Space.xs) {
                    PosterImage(url: e.thumbnailURL, title: String(e.number), showsTitle: e.thumbnailURL == nil,
                                cornerRadius: Radius.small, titleFont: .headline)
                        .frame(width: 112, height: 63)
                    if let p, p.fraction > 0.02, !p.isWatched, !isCurrent {
                        WatchedBar(fraction: p.fraction, onArtwork: true)
                            .frame(width: 112)
                    }
                }
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(isCurrent ? "Now Playing" : "Episode \(e.number)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isCurrent ? Color.accentColor : .white.opacity(0.6))
                    Text(e.title?.isEmpty == false ? e.title! : "Episode \(e.number)")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    if !e.isAired, let at = e.airsAt {
                        Text("Airs \(at.formatted(.dateTime.month(.abbreviated).day()))")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                    } else if p?.isWatched == true {
                        Text("Watched")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(Space.s)
            .background(isCurrent ? Color.white.opacity(0.12) : .clear, in: .rect(cornerRadius: Radius.medium))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!e.isAired || isCurrent)
        .opacity(e.isAired ? 1 : 0.5)
    }
}
