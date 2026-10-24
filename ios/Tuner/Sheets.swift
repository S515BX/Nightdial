import SwiftUI

@MainActor
struct SheetHost: View {
    let sheet: ActiveSheet

    var body: some View {
        Group {
            switch sheet {
            case .groups: GroupsSheet()
            case .search: SearchSheet()
            case .playlists: PlaylistsSheet()
            case .settings: SettingsSheet()
            case .details(let target): DetailsSheet(target: target)
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }
}

private struct DoneButton: ToolbarContent {
    let action: () -> Void
    var body: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) { Button("Done", action: action) }
    }
}

@MainActor
struct GroupsSheet: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("all", "All channels", model.channels.count)
                    row("fav", "Favorites", model.favorites.count)
                    row("recent", "Recently watched", model.recents.count)
                }
                Section("Categories") {
                    ForEach(model.groups) { g in row(g.id, g.name, g.count) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.panel)
            .navigationTitle("Groups")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { DoneButton { model.sheet = nil } }
        }
    }

    private func row(_ id: String, _ name: String, _ count: Int) -> some View {
        Button {
            model.selectGroup(id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .opacity(model.groupId == id ? 1 : 0)
                Text(name).foregroundStyle(Theme.fg)
                Spacer()
                Text("\(count)").foregroundStyle(Theme.fg3).monospacedDigit()
            }
        }
        .listRowBackground(Theme.cell)
    }
}

@MainActor
struct SearchSheet: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""

    var body: some View {
        let results = model.search(query)
        let hasQuery = !query.trimmed.isEmpty
        let channelsTitle: String = hasQuery ? "Channels" : "Recently watched"
        let emptyMessage: String = hasQuery ? "Nothing matches \u{201C}\(query)\u{201D}." : "Type a channel name, a number or a program title."
        NavigationStack {
            List {
                if !results.channels.isEmpty {
                    Section(channelsTitle) {
                        ForEach(results.channels) { ch in channelRow(ch) }
                    }
                }
                if !results.programs.isEmpty {
                    Section("Programs") {
                        ForEach(results.programs) { hit in programRow(hit) }
                    }
                }
                if results.channels.isEmpty && results.programs.isEmpty {
                    Text(emptyMessage)
                        .foregroundStyle(Theme.fg3)
                        .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.panel)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Channels and programs")
            .autocorrectionDisabled()
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { DoneButton { model.sheet = nil } }
        }
    }

    private func channelRow(_ ch: Channel) -> some View {
        let now = model.program(for: ch, at: Date())
        return Button {
            model.goTo(ch, program: nil)
        } label: {
            HStack(spacing: 12) {
                LogoBadge(channel: ch, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(ch.num) · \(ch.name)").foregroundStyle(Theme.fg).lineLimit(1)
                    Text(now.map { "Now: \($0.title)" } ?? "Live channel").font(.system(size: 13)).foregroundStyle(Theme.fg3).lineLimit(1)
                }
            }
        }
        .listRowBackground(Theme.cell)
    }

    private func programRow(_ hit: ProgramHit) -> some View {
        let p = hit.program
        let when = p.isNow(Date()) ? "On now" : "\(Fmt.day(p.start)) \(Fmt.time(p.start, model.clock24))"
        return Button {
            model.goTo(hit.channel, program: p)
        } label: {
            HStack(spacing: 12) {
                LogoBadge(channel: hit.channel, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.title).foregroundStyle(Theme.fg).lineLimit(1)
                    Text("\(when) · \(hit.channel.num) \(hit.channel.name)").font(.system(size: 13)).foregroundStyle(Theme.fg3).lineLimit(1)
                }
            }
        }
        .listRowBackground(Theme.cell)
    }
}

@MainActor
struct PlaylistsSheet: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.savedPlaylists) { pl in
                        Button {
                            model.switchTo(pl)
                        } label: {
                            row(pl.name, "Xtream Codes · \(URL(string: pl.server)?.host ?? pl.server)", selected: model.provider?.id == pl.id && !model.isBackdrop)
                        }
                        .listRowBackground(Theme.cell)
                    }
                    Button {
                        model.switchToDemo()
                    } label: {
                        row("Demo playlist", "Built-in sample channels and guide", selected: model.provider?.id == "demo" && !model.isBackdrop)
                    }
                    .listRowBackground(Theme.cell)
                }
                Section {
                    Button {
                        model.addPlaylist()
                    } label: {
                        Label("Add Xtream Codes playlist", systemImage: "plus").foregroundStyle(Theme.accent)
                    }
                    .listRowBackground(Theme.cell)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.panel)
            .navigationTitle("Playlists")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { DoneButton { model.sheet = nil } }
        }
    }

    private func row(_ title: String, _ subtitle: String, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.accent)
                .opacity(selected ? 1 : 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Theme.fg)
                Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.fg3).lineLimit(1)
            }
        }
    }
}

@MainActor
struct SettingsSheet: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmRemove = false

    var body: some View {
        NavigationStack {
            Form {
                if let p = model.provider {
                    Section("Playlist") {
                        value("Name", p.name)
                        value("Type", p.kind == .demo ? "Built-in demo" : "Xtream Codes")
                        if p.kind == .xtream {
                            value("Server", p.server)
                            value("Username", p.user)
                            value("Connections", "\(p.info.activeConnections ?? "–") of \(p.info.maxConnections ?? "–") in use")
                        }
                        value("Status", p.info.status + (p.info.trial ? " · trial" : ""))
                        value("Expires", p.info.expires.map { Fmt.dateFormatter.string(from: $0) } ?? (p.kind == .demo ? "Never" : "Unlimited"))
                        value("Channels", "\(model.channels.count) in \(model.groups.count) groups")
                        Button("Switch playlist") { model.sheet = .playlists }
                        if p.kind == .xtream {
                            Button("Remove playlist", role: .destructive) { confirmRemove = true }
                        }
                    }
                    .listRowBackground(Theme.cell)
                }
                Section("TV guide") {
                    Toggle("24-hour clock", isOn: $model.clock24)
                    Toggle("Compact rows", isOn: $model.compactRows)
                }
                .listRowBackground(Theme.cell)
                if model.provider?.kind == .xtream {
                    Section {
                        Toggle("Use XMLTV file", isOn: $model.useXMLTV)
                        if model.useXMLTV {
                            TextField("Your provider's XMLTV (leave empty)", text: $model.xmltvURL)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        Button("Reload guide") { model.reloadGuide() }
                    } header: {
                        Text("Guide source")
                    } footer: {
                        Text(model.useXMLTV
                             ? "Leave the address empty to use your provider's XMLTV file. Large files can take a minute."
                             : "Guide data loads for the channels on screen as you scroll.")
                    }
                    .listRowBackground(Theme.cell)
                }
                Section("Tips") {
                    tip("hand.tap", "Tap a program to select it. Tap it again to watch, or to see details.")
                    tip("hand.point.up.left", "Touch and hold a channel to add it to favorites.")
                    tip("arrow.up.arrow.down", "In full screen, swipe up or down to change channel.")
                    tip("airplayvideo", "Use AirPlay or Picture in Picture from the full-screen controls.")
                }
                .listRowBackground(Theme.cell)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.panel)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { DoneButton { model.sheet = nil } }
            .confirmationDialog("Remove this playlist from Tuner?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove playlist", role: .destructive) { model.removeCurrentPlaylist() }
            }
        }
    }

    private func value(_ key: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(key).foregroundStyle(Theme.fg3)
            Spacer()
            Text(text).foregroundStyle(Theme.fg).multilineTextAlignment(.trailing)
        }
        .textSelection(.enabled)
    }

    private func tip(_ icon: String, _ text: String) -> some View {
        Label {
            Text(text).foregroundStyle(Theme.fg2).font(.system(size: 14))
        } icon: {
            Image(systemName: icon).foregroundStyle(Theme.accent)
        }
    }
}

@MainActor
struct DetailsSheet: View {
    @EnvironmentObject var model: AppModel
    let target: DetailsTarget

    var body: some View {
        let ch = target.channel
        let p = target.program
        let now = Date()
        let live = p.isNow(now)
        let catchup = model.canCatchup(ch, p)
        let favorite = model.favorites.contains(ch.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    LogoBadge(channel: ch, size: 30)
                    Text("\(ch.num)").font(.cond(15, .semibold)).foregroundStyle(Theme.fg3).monospacedDigit()
                    Text(ch.name).font(.cond(15, .semibold)).foregroundStyle(Theme.fg2).lineLimit(1)
                    Spacer()
                    Button {
                        model.sheet = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 24)).foregroundStyle(Theme.fg3)
                    }
                    .accessibilityLabel("Close")
                }
                Text(p.title).font(.cond(30, .semibold)).foregroundStyle(Theme.fg)
                Text("\(Fmt.day(p.start)) · \(Fmt.time(p.start, model.clock24)) – \(Fmt.time(p.end, model.clock24)) · \(Fmt.duration(p.end.timeIntervalSince(p.start)))")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.fg2)
                MetaLine(channel: ch, program: p)
                if !p.desc.isEmpty {
                    Text(p.desc).font(.system(size: 16)).foregroundStyle(Theme.fg2)
                }
                if p.end <= now && !catchup {
                    Text(ch.archive ? "This program is older than the catch-up window." : "This program has ended and this channel has no catch-up.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.fg3)
                }
                VStack(spacing: 10) {
                    if live {
                        Button { model.watchFromDetails(ch, catchup: nil) } label: {
                            Label("Watch now", systemImage: "play.fill").primaryButton()
                        }
                    }
                    if catchup {
                        Button { model.watchFromDetails(ch, catchup: p) } label: {
                            Label("Watch from start", systemImage: "gobackward").buttonLook(primary: !live)
                        }
                    }
                    if !live {
                        Button { model.watchFromDetails(ch, catchup: nil) } label: {
                            Label("Watch channel live", systemImage: "dot.radiowaves.left.and.right").buttonLook(primary: !catchup)
                        }
                    }
                    Button { model.toggleFavorite(ch) } label: {
                        Label(favorite ? "Remove favorite" : "Add to favorites", systemImage: favorite ? "star.fill" : "star").secondaryButton()
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
            .padding(22)
        }
        .background(Theme.panel.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
