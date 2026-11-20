import SwiftUI
import CatalogKit

/// What airs each day, from two days ago to a week ahead. Episodes already out read as primary;
/// the ones still to come step back.
struct ScheduleView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var shows: ShowsModel
    @AppStorage("scheduleMyListOnly") private var myListOnly = false
    @State private var day = Calendar.current.startOfDay(for: Date())

    private var days: [Date] {
        let today = Calendar.current.startOfDay(for: Date())
        return (-2...6).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: today) }
    }

    private var episodes: [AiringEpisode] {
        shows.schedule.filter { e in
            Calendar.current.isDate(e.airingAt, inSameDayAs: day) && (!myListOnly || shows.isInMyList(e.show))
        }
    }

    var body: some View {
        NavigationStack(path: $model.schedulePath) {
            content
                .navigationTitle("Schedule")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Picker("Show", selection: $myListOnly) {
                                Text("All Shows").tag(false)
                                Text("My List").tag(true)
                            }
                        } label: {
                            Label("Filter", systemImage: myListOnly
                                  ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        }
                    }
                }
                .routeDestinations()
                .task { await shows.loadSchedule() }
                .refreshable { await shows.loadSchedule(force: true) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if shows.schedule.isEmpty {
            if shows.scheduleFailed {
                ContentUnavailableView {
                    Label("Can’t Load the Schedule", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("Check your connection and try again.")
                } actions: {
                    Button("Try Again") { Task { await shows.loadSchedule(force: true) } }
                        .buttonStyle(.bordered)
                }
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    DayStrip(days: days, selection: $day)
                    let list = episodes
                    if list.isEmpty {
                        Text(myListOnly ? "Nothing from My List airs this day." : "Nothing airs this day.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, Space.xxl)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(list) { e in
                                NavigationLink(value: Route.show(e.show)) {
                                    AiringRow(airing: e)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, Space.l)
                    }
                }
                .padding(.vertical, Space.s)
                .frame(maxWidth: Metrics.contentMaxWidth)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// Nine days side by side. The selected one is filled; today is marked in the accent color.
private struct DayStrip: View {
    let days: [Date]
    @Binding var selection: Date

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: Space.s) {
                    ForEach(days, id: \.self) { d in
                        cell(d).id(d)
                    }
                }
                .padding(.horizontal, Space.l)
            }
            .scrollIndicators(.hidden)
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
        }
    }

    private func cell(_ d: Date) -> some View {
        let selected = Calendar.current.isDate(d, inSameDayAs: selection)
        let today = Calendar.current.isDateInToday(d)
        return Button { selection = d } label: {
            VStack(spacing: Space.xxs) {
                Text(d, format: .dateTime.weekday(.abbreviated))
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                Text(d, format: .dateTime.day())
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(selected ? Color(uiColor: .systemBackground) : today ? Color.accentColor : Color.primary)
            .frame(width: 52, height: 60)
            .background(selected ? Color.primary : Color.clear, in: .rect(cornerRadius: Radius.medium))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(d, format: .dateTime.weekday(.wide).month(.wide).day()))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: selected)
    }
}

/// Time, poster, title and episode.
private struct AiringRow: View {
    let airing: AiringEpisode

    private var isOut: Bool { airing.airingAt <= Date() }

    var body: some View {
        HStack(spacing: Space.m) {
            Text(airing.airingAt, format: .dateTime.hour().minute())
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(isOut ? .primary : .secondary)
                .frame(width: 72, alignment: .leading)
            PosterImage(url: airing.show.posterURL, title: airing.show.title, showsTitle: false, cornerRadius: Radius.small)
                .frame(width: Metrics.rowPoster.width, height: Metrics.rowPoster.height)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(airing.show.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(isOut ? .primary : .secondary)
                    .lineLimit(2)
                Text("Episode \(airing.episode)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Space.s)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}
