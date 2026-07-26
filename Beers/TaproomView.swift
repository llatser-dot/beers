import AppKit
import SwiftUI

/// The Taproom: every pour pinned behind the bar. Navy sidebar,
/// cream floor, beer-mat rows that lift on hover.
struct TaproomView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var store: PourStore
    @ObservedObject private var updater = UpdateController.shared
    @State private var filter: TapFilter = .all
    @State private var search = ""

    enum TapFilter: Hashable {
        case all
        case pubWall
        case keepers
        case app(String)
        case dripTray

        var title: String {
            switch self {
            case .all: return "All pours"
            case .pubWall: return "Pub Wall"
            case .keepers: return "Keepers"
            case .app(let name): return name
            case .dripTray: return "The drip tray"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Beers.ink).frame(width: 2.5)
            main
        }
        .frame(minWidth: 880, minHeight: 560)
        .background(Beers.cream)
        .environment(\.colorScheme, .light)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                BeersMenuBadge(size: 28)
                Text("eers")
                    .font(Beers.display(19))
                    .foregroundStyle(Beers.lager)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 12)

            navItem(.all, emoji: "🍺")
            navItem(.pubWall, emoji: "🏆")
            navItem(.keepers, emoji: "⭐")
            ForEach(store.appNames.prefix(4), id: \.self) { app in
                navItem(.app(app), emoji: "→")
            }
            navItem(.dripTray, emoji: "🗑")

            Spacer()

            updateButton
            streakCard
        }
        .padding(16)
        .frame(width: 200)
        .frame(maxHeight: .infinity)
        .background(Beers.ink)
    }

    private var updateButton: some View {
        Button {
            updater.checkForUpdates()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: updater.availableVersion == nil ? "arrow.triangle.2.circlepath" : "arrow.down.circle.fill")
                    .font(.system(size: 11, weight: .bold))
                Text(updater.actionTitle)
                    .font(Beers.ui(12, .bold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(updater.availableVersion == nil ? Beers.cream : Beers.ink)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                updater.availableVersion == nil ? Beers.stout : Beers.lager,
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(updater.availableVersion == nil ? Beers.cream.opacity(0.55) : Beers.ink, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .disabled(!updater.canCheckForUpdates || updater.isChecking)
        .opacity(updater.canCheckForUpdates ? 1 : 0.55)
        .padding(.bottom, 8)
    }

    private func navItem(_ item: TapFilter, emoji: String) -> some View {
        Button {
            withAnimation(Beers.spring) { filter = item }
        } label: {
            HStack(spacing: 9) {
                Text(emoji).font(.system(size: 12))
                Text(item.title)
                    .font(Beers.ui(13, .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(filter == item ? Beers.paper : Beers.cream.opacity(0.72))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background {
                if filter == item {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Beers.amber)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Beers.cream, lineWidth: 2)
                        )
                        .shadow(color: .black.opacity(0.4), radius: 0, y: 3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var streakCard: some View {
        VStack(spacing: 2) {
            Text("\(store.streak)")
                .font(Beers.display(26))
                .foregroundStyle(Beers.lager)
            Text("day pour streak 🔥")
                .font(Beers.ui(11, .semibold))
                .foregroundStyle(Beers.hops)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Beers.hops, style: StrokeStyle(lineWidth: 2.5, dash: [6, 5]))
        )
    }

    // MARK: Main

    private var main: some View {
        Group {
            if filter == .pubWall {
                PubWallView()
            } else {
                VStack(spacing: 0) {
                    toolbar
                    ScrollView {
                        LazyVStack(spacing: 0, pinnedViews: []) {
                            if visiblePours.isEmpty {
                                emptyState.padding(.top, 90)
                            } else {
                                ForEach(groupedByDay, id: \.0) { day, pours in
                                    dayDivider(day, pours: pours)
                                    ForEach(pours) { pour in
                                        PourRowView(
                                            pour: pour,
                                            inDripTray: filter == .dripTray,
                                            onCopy: { copy(pour) },
                                            onKeeper: { store.toggleKeeper(pour) },
                                            onDelete: { withAnimation(Beers.spring) { store.moveToDripTray(pour) } },
                                            onRestore: { withAnimation(Beers.spring) { store.restore(pour) } }
                                        )
                                        .padding(.horizontal, 22)
                                        .padding(.bottom, 11)
                                    }
                                }
                            }
                        }
                        .padding(.top, 6)
                        .padding(.bottom, 24)
                    }
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Beers.ink.opacity(0.45))
                TextField("Search your pours…", text: $search)
                    .textFieldStyle(.plain)
                    .font(Beers.ui(13, .medium))
                    .foregroundStyle(Beers.ink)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .background(Beers.paper, in: Capsule())
            .overlay(Capsule().strokeBorder(Beers.ink, lineWidth: 2.5))

            Text("\(store.poursToday) pours · \(store.wordsToday) words today")
                .font(Beers.ui(12, .semibold))
                .foregroundStyle(Beers.stout)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private func dayDivider(_ day: Date, pours: [Pour]) -> some View {
        HStack(spacing: 12) {
            Text(dayLabel(day) + " — \(pours.count) \(pours.count == 1 ? "pour" : "pours")")
                .font(Beers.ui(11, .bold))
                .tracking(1.8)
                .textCase(.uppercase)
                .foregroundStyle(Beers.stout)
            DottedLine()
                .stroke(Beers.stout.opacity(0.45), style: StrokeStyle(lineWidth: 2.5, dash: [2.5, 5]))
                .frame(height: 2.5)
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 11)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text(filter == .dripTray ? "🗑" : "🍺").font(.system(size: 44))
            Text(filter == .dripTray ? "The drip tray is clean" : "The bar's empty")
                .font(Beers.display(18))
                .foregroundStyle(Beers.stout)
            Text(
                filter == .dripTray
                    ? "Deleted pours rest here for 30 days."
                    : "Hold \(appState.hotkeyChoice.keycapLabel) and say anything — your first pour lands here."
            )
            .font(Beers.ui(13, .medium))
            .foregroundStyle(Beers.ink.opacity(0.6))
        }
    }

    // MARK: Data

    private var visiblePours: [Pour] {
        var pours: [Pour]
        switch filter {
        case .all: pours = store.active
        case .pubWall: pours = []
        case .keepers: pours = store.keepers
        case .app(let name): pours = store.active.filter { $0.appName == name }
        case .dripTray: pours = store.dripTray
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            pours = pours.filter {
                $0.text.localizedCaseInsensitiveContains(query)
                    || $0.appName.localizedCaseInsensitiveContains(query)
            }
        }
        return pours
    }

    private var groupedByDay: [(Date, [Pour])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: visiblePours) { calendar.startOfDay(for: $0.date) }
        return groups.sorted { $0.key > $1.key }
    }

    private func dayLabel(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE d MMM"
        return formatter.string(from: day)
    }

    private func copy(_ pour: Pour) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pour.text, forType: .string)
    }
}

private struct DottedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// A beer-mat row. Lifts on hover; cap stamp carries the target app's initial.
private struct PourRowView: View {
    let pour: Pour
    let inDripTray: Bool
    let onCopy: () -> Void
    let onKeeper: () -> Void
    let onDelete: () -> Void
    let onRestore: () -> Void

    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 13) {
            CapStamp(
                letter: String(pour.appName.prefix(1)).uppercased(),
                color: CapStamp.color(for: pour.appName),
                size: 40
            )

            VStack(alignment: .leading, spacing: 3) {
                Text("“\(pour.text)”")
                    .font(Beers.ui(13.5, .semibold))
                    .foregroundStyle(Beers.ink)
                    .lineLimit(1)
                Text(info)
                    .font(Beers.ui(11, .medium))
                    .foregroundStyle(Beers.ink.opacity(0.5))
            }

            Spacer(minLength: 8)

            if hovering || pour.isKeeper || inDripTray {
                actions
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Beers.paper, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(pour.isKeeper && !inDripTray ? Beers.lager : Beers.ink, lineWidth: 2.5)
        )
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Beers.ink.opacity(0.8))
                .offset(y: hovering ? 6 : 3)
        )
        .offset(y: hovering ? -3 : 0)
        .rotationEffect(.degrees(hovering ? -0.3 : 0))
        .opacity(inDripTray ? 0.75 : 1)
        .animation(Beers.springTight, value: hovering)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy") { onCopy() }
            if !inDripTray {
                Button(pour.isKeeper ? "Un-keep" : "Keep") { onKeeper() }
                Button("To the drip tray", role: .destructive) { onDelete() }
            } else {
                Button("Restore") { onRestore() }
            }
        }
    }

    private var info: String {
        let time = pour.date.formatted(date: .omitted, time: .shortened)
        var parts = [pour.appName, time, "\(pour.words) words"]
        if pour.duration > 0 {
            parts.append(String(format: "%d:%02d", Int(pour.duration) / 60, Int(pour.duration) % 60))
        }
        if pour.isKeeper { parts.append("⭐ keeper") }
        return parts.joined(separator: " · ")
    }

    private var actions: some View {
        HStack(spacing: 7) {
            if inDripTray {
                iconButton(system: "arrow.uturn.left", tint: Beers.cream2) { onRestore() }
            } else {
                iconButton(text: copied ? "✓" : "⧉", tint: Beers.cream2) {
                    onCopy()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                }
                iconButton(text: pour.isKeeper ? "★" : "☆", tint: pour.isKeeper ? Beers.lager : Beers.cream2) {
                    onKeeper()
                }
                iconButton(system: "trash", tint: Beers.cream2) { onDelete() }
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.85)))
    }

    private func iconButton(
        text: String? = nil,
        system: String? = nil,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if let text {
                    Text(text).font(Beers.ui(13, .bold))
                } else if let system {
                    Image(systemName: system).font(.system(size: 11, weight: .bold))
                }
            }
            .foregroundStyle(Beers.ink)
            .frame(width: 30, height: 30)
            .background(tint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Beers.ink, lineWidth: 2)
            )
        }
        .buttonStyle(HopIconButtonStyle())
    }
}

private struct HopIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .rotationEffect(.degrees(configuration.isPressed ? -5 : 0))
            .animation(Beers.springTight, value: configuration.isPressed)
    }
}
