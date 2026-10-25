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
            case .channels: ChannelsSheet()
            case .themes: ThemesSheet()
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
                    row("all", "All channels", model.visibleChannelCount)
                    row("fav", "Favorites", model.favorites.count)
                }
                Section {
                    ForEach(model.visibleGroups) { g in row(g.id, g.name, g.count) }
                } header: {
                    Text("Categories")
                } footer: {
                    if !model.hiddenGroups.isEmpty || !model.hiddenChannels.isEmpty {
                        Text("Some channels or groups are hidden. Bring them back in Settings → Edit channels.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.menu)
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
            .background(Theme.menu)
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
                    Text(now.map { "Now: \($0.title)" } ?? "Live channel").font(.ui(13)).foregroundStyle(Theme.fg3).lineLimit(1)
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
                    Text("\(when) · \(hit.channel.num) \(hit.channel.name)").font(.ui(13)).foregroundStyle(Theme.fg3).lineLimit(1)
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
                            row(pl.name, pl.kind == "m3u" ? "M3U playlist · \(pl.host ?? "")" : "Xtream Codes · \(URL(string: pl.server)?.host ?? pl.server)",
                                selected: model.provider?.id == pl.id && !model.isBackdrop)
                        }
                        .listRowBackground(Theme.cell)
                    }
                    if model.savedPlaylists.isEmpty {
                        Text("No saved playlists yet.").foregroundStyle(Theme.fg3).listRowBackground(Theme.cell)
                    }
                }
                Section {
                    Button {
                        model.addPlaylist()
                    } label: {
                        Label("Add playlist (Xtream Codes or M3U)", systemImage: "plus").foregroundStyle(Theme.accent)
                    }
                    .listRowBackground(Theme.cell)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.menu)
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
                Text(subtitle).font(.ui(13)).foregroundStyle(Theme.fg3).lineLimit(1)
            }
        }
    }
}

@MainActor
struct SettingsSheet: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlayerController
    @State private var confirmRemove = false
    @State private var m3uGuide = ""
    @State private var vpnOn = false

    var body: some View {
        NavigationStack {
            Form {
                if let p = model.provider {
                    Section("Playlist") {
                        value("Name", p.name)
                        value("Type", p.kind == .demo ? "Built-in demo" : p.kind == .m3u ? "M3U playlist" : "Xtream Codes")
                        if p.kind == .xtream {
                            value("Server", p.server)
                            value("Username", p.user)
                            value("Connections", "\(p.info.activeConnections ?? "–") of \(p.info.maxConnections ?? "–") in use")
                        }
                        if p.kind == .m3u {
                            value("Playlist from", URL(string: p.url)?.host ?? "–")
                        } else {
                            value("Status", p.info.status + (p.info.trial ? " · trial" : ""))
                            value("Expires", p.info.expires.map { Fmt.dateFormatter.string(from: $0) } ?? (p.kind == .demo ? "Never" : "Unlimited"))
                        }
                        value("Channels", "\(model.channels.count) in \(model.groups.count) groups")
                        if model.vod.available {
                            Button("Movies & Series") { model.openOnDemand() }
                        }
                        if model.canEditOptions {
                            NavigationLink { PlaylistOptionsView() } label: {
                                Label("Playlist options", systemImage: "slider.horizontal.3").foregroundStyle(Theme.fg)
                            }
                        }
                        Button("Switch playlist") { model.sheet = .playlists }
                        if p.kind != .demo {
                            Button("Remove playlist", role: .destructive) { confirmRemove = true }
                        }
                    }
                    .listRowBackground(Theme.cell)
                }
                Section("Look") {
                    Button { model.sheet = .themes } label: {
                        HStack {
                            Label("Themes & look", systemImage: "paintpalette").foregroundStyle(Theme.fg)
                            Spacer()
                            Text(Look.shared.theme.name + (Look.shared.autoSeason ? " · auto" : "")).foregroundStyle(Theme.fg3)
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.fg3)
                        }
                    }
                }
                .listRowBackground(Theme.cell)
                Section("Channels") {
                    Picker("Sort channels", selection: $model.sortMode) {
                        Text("Provider order").tag("provider")
                        Text("Number").tag("number")
                        Text("A–Z").tag("name")
                    }
                    value("Favorites", "\(model.favorites.count)")
                    value("Hidden", "\(model.hiddenChannels.count) channels · \(model.hiddenGroups.count) groups")
                    Button { model.sheet = .channels } label: {
                        HStack {
                            Label("Edit channels", systemImage: "list.star").foregroundStyle(Theme.fg)
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.fg3)
                        }
                    }
                }
                .listRowBackground(Theme.cell)
                Section {
                    Picker("Picture shape", selection: $player.aspect) {
                        ForEach(PlayerController.aspects.indices, id: \.self) { i in Text(PlayerController.aspects[i].1).tag(PlayerController.aspects[i].0) }
                    }
                    Picker("Video player", selection: $model.externalPlayer) {
                        ForEach(ExternalPlayer.allCases) { p in Text(p.name).tag(p) }
                    }
                } header: {
                    Text("Playback")
                } footer: {
                    Text("16:9 fills a TV-shaped picture. Fit keeps each channel's own shape; Zoom fills the screen by trimming the edges. With another video player, full screen opens there; the guide preview always plays here.")
                }
                .listRowBackground(Theme.cell)
                Section {
                    HStack {
                        Text("Status").foregroundStyle(Theme.fg3)
                        Spacer()
                        Text(vpnOn ? "On" : "Off").foregroundStyle(Theme.fg)
                    }
                    Toggle("Only play when a VPN is on", isOn: $model.vpnRequired)
                    if let wg = URL(string: "https://apps.apple.com/app/wireguard/id1441195209") {
                        Link("Get the WireGuard app", destination: wg)
                    }
                } header: {
                    Text("VPN")
                } footer: {
                    Text("Only apps with a paid Apple developer account can run their own VPN, so turn on your VPN app (WireGuard or your VPN provider's) before watching. Nightdial shows here when one is on.")
                }
                .listRowBackground(Theme.cell)
                .onAppear { vpnOn = VPNStatus.isOn }
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
                if model.provider?.kind == .m3u {
                    Section {
                        TextField("XMLTV link (optional)", text: $m3uGuide)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Save and reload guide") { model.setM3UGuide(m3uGuide) }
                    } header: {
                        Text("Guide source")
                    } footer: {
                        Text("The TV guide for an M3U playlist comes from an XMLTV file. Your provider's playlist may already include one.")
                    }
                    .listRowBackground(Theme.cell)
                    .onAppear { m3uGuide = model.provider?.epgUrl ?? "" }
                }
                Section("Tips") {
                    tip("hand.tap", "Tap a program to select it. Tap it again to watch, or to see details.")
                    tip("hand.point.up.left", "Touch and hold a channel to add it to favorites.")
                    tip("arrow.up.arrow.down", "In full screen, swipe up or down to change channel, or swipe right for the channel list.")
                    tip("ellipsis.circle", "In full screen, the … button has channel options: favorite, hide, audio track and more.")
                    tip("gobackward.30", "Pause and rewind live TV from the full-screen controls. Channels with catch-up can go back further.")
                    tip("airplayvideo", "Use AirPlay or Picture in Picture from the full-screen controls.")
                }
                .listRowBackground(Theme.cell)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.menu)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { DoneButton { model.sheet = nil } }
            .confirmationDialog("Remove this playlist from Nightdial?", isPresented: $confirmRemove, titleVisibility: .visible) {
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
            Text(text).foregroundStyle(Theme.fg2).font(.ui(14))
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
                    .font(.ui(15))
                    .foregroundStyle(Theme.fg2)
                MetaLine(channel: ch, program: p)
                if !p.desc.isEmpty {
                    Text(p.desc).font(.ui(16)).foregroundStyle(Theme.fg2)
                }
                if p.end <= now && !catchup {
                    Text(ch.archive ? "This program is older than the catch-up window." : "This program has ended and this channel has no catch-up.")
                        .font(.ui(14))
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
                    Button {
                        model.sheet = nil
                        model.setHidden(ch, true, announce: true)
                    } label: {
                        Label("Hide channel", systemImage: "eye.slash").secondaryButton()
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
            .padding(22)
        }
        .background(Theme.menu.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}


// MARK: - Edit channels: favorites order, hidden channels and groups, sorting

@MainActor
struct ChannelsSheet: View {
    @EnvironmentObject var model: AppModel
    @State private var tab = 0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Show", selection: $tab) {
                        Text("Favorites").tag(0)
                        Text("Groups & channels").tag(1)
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Color.clear)
                if tab == 0 { favoritesSection } else { groupsSection }
            }
            .environment(\.editMode, .constant(tab == 0 ? .active : .inactive))
            .scrollContentBackground(.hidden)
            .background(Theme.menu)
            .navigationTitle("Edit channels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { DoneButton { model.sheet = nil } }
            .onAppear { tab = model.favorites.isEmpty ? 1 : 0 }
        }
    }

    @ViewBuilder private var favoritesSection: some View {
        let favs = model.favoriteChannels
        Section {
            if favs.isEmpty {
                Text("No favorites yet. Open Groups & channels and tap the star next to a channel.")
                    .font(.ui(14)).foregroundStyle(Theme.fg3)
                    .listRowBackground(Color.clear)
            }
            ForEach(favs) { ch in
                HStack(spacing: 12) {
                    LogoBadge(channel: ch, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(ch.num) · \(ch.name)").foregroundStyle(Theme.fg).lineLimit(1)
                        Text(model.groupLabel(ch.groupId) + (model.hiddenChannels.contains(ch.id) ? " · hidden" : ""))
                            .font(.ui(12.5)).foregroundStyle(Theme.fg3).lineLimit(1)
                    }
                }
                .listRowBackground(Theme.cell)
            }
            .onMove { model.moveFavorites(from: $0, to: $1) }
            .onDelete { model.removeFavorites(at: $0) }
        } footer: {
            if !favs.isEmpty { Text("Drag to set the order your favorites appear in. Swipe or tap − to remove one.") }
        }
    }

    @ViewBuilder private var groupsSection: some View {
        Section {
            Picker("Sort channels", selection: $model.sortMode) {
                Text("Provider order").tag("provider")
                Text("Number").tag("number")
                Text("A–Z").tag("name")
            }
            .listRowBackground(Theme.cell)
        }
        Section {
            ForEach(model.groups) { g in
                let hidden = model.hiddenGroups.contains(g.id)
                HStack(spacing: 12) {
                    NavigationLink {
                        GroupChannelsView(group: g)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(g.name).foregroundStyle(hidden ? Theme.fg3 : Theme.fg).lineLimit(1)
                            Text(hidden ? "\(g.count) channels · hidden from the guide" : "\(g.count) channels")
                                .font(.ui(12.5)).foregroundStyle(Theme.fg3)
                        }
                    }
                    Button { model.setGroupHidden(g.id, !hidden) } label: {
                        Image(systemName: hidden ? "eye.slash" : "eye")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(hidden ? Theme.live : Theme.fg2)
                            .frame(width: 40, height: 34)
                            .background(Capsule().fill(Theme.cellHover))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(hidden ? "Show \(g.name)" : "Hide \(g.name)")
                }
                .listRowBackground(Theme.cell)
            }
        } header: {
            Text("Groups")
        } footer: {
            Text("The eye hides a whole group. Open a group to pick favorites or hide single channels.")
        }
    }
}

@MainActor
struct GroupChannelsView: View {
    @EnvironmentObject var model: AppModel
    let group: ChannelGroup

    var body: some View {
        List {
            ForEach(model.channels(inGroup: group.id)) { ch in
                let fav = model.favorites.contains(ch.id)
                let hidden = model.hiddenChannels.contains(ch.id)
                HStack(spacing: 12) {
                    LogoBadge(channel: ch, size: 34).opacity(hidden ? 0.45 : 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(ch.num) · \(ch.name)").foregroundStyle(hidden ? Theme.fg3 : Theme.fg).lineLimit(1)
                        if hidden { Text("Hidden").font(.ui(12.5)).foregroundStyle(Theme.fg3) }
                    }
                    Spacer()
                    Button { model.toggleFavorite(ch, quiet: true) } label: {
                        Image(systemName: fav ? "star.fill" : "star")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(fav ? Theme.warn : Theme.fg2)
                            .frame(width: 40, height: 34)
                            .background(Capsule().fill(Theme.cellHover))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(fav ? "Remove \(ch.name) from favorites" : "Add \(ch.name) to favorites")
                    Button { model.setHidden(ch, !hidden) } label: {
                        Image(systemName: hidden ? "eye.slash" : "eye")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(hidden ? Theme.live : Theme.fg2)
                            .frame(width: 40, height: 34)
                            .background(Capsule().fill(Theme.cellHover))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(hidden ? "Show \(ch.name)" : "Hide \(ch.name)")
                }
                .listRowBackground(Theme.cell)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.menu)
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Themes & look

@MainActor
struct ThemesSheet: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var look = Look.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section("Size") {
                        Picker("Size", selection: $look.size) {
                            ForEach(Look.sizes.indices, id: \.self) { i in Text(Look.sizes[i].1).tag(Look.sizes[i].0) }
                        }
                        .pickerStyle(.segmented)
                        hint("Smaller fits more channels and more hours of the guide on screen.")
                    }
                    section("Theme") {
                        tiles(Themes.all.filter { !$0.season })
                    }
                    section("Holidays") {
                        tiles(Themes.all.filter { $0.season })
                        Toggle("Switch to holiday themes automatically", isOn: $look.autoSeason)
                            .tint(Theme.accent)
                            .font(.ui(15))
                            .foregroundStyle(Theme.fg)
                        hint(seasonHint)
                    }
                    section("Highlight color") {
                        swatches(Themes.highlightColors, selection: $look.highlight)
                        hint("Marks what's selected: the program you're on, menu items and buttons.")
                    }
                    section("Menu color") {
                        swatches(Themes.menuColors, selection: $look.menu)
                        hint("Colors the side menu and the panels that slide up.")
                    }
                    section("Font") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
                            ForEach(Fonts.all) { f in
                                let on = look.font == f.id
                                Button { look.font = f.id } label: {
                                    Text(f.name)
                                        .font(fontPreview(f))
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 44)
                                        .foregroundStyle(on ? Theme.hlInk : Theme.fg)
                                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(on ? Theme.hl : Theme.cell))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    section("Effects") {
                        Toggle("Holiday decorations (snow, bats, hearts and more)", isOn: $look.decorations).tint(Theme.accent)
                        Toggle("Background glow", isOn: $look.glow).tint(Theme.accent)
                        Button { look.resetLook() } label: {
                            Label("Reset to the default look", systemImage: "arrow.counterclockwise").secondaryButton()
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 6)
                    }
                    .font(.ui(15))
                    .foregroundStyle(Theme.fg)
                }
                .padding(20)
            }
            .background(Theme.menu.ignoresSafeArea())
            .navigationTitle("Themes & look")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { DoneButton { model.sheet = nil } }
        }
        .tint(Theme.accent)
    }

    private var seasonHint: String {
        if let h = Holidays.active() {
            return "\(Themes.find(h.id).name) is on until \(Fmt.shortDate(h.until)). Your own theme comes back after each holiday."
        }
        if let n = Holidays.next() {
            return "Next up: \(Themes.find(n.id).name) from \(Fmt.shortDate(n.from)). Your own theme comes back after each holiday."
        }
        return "Each holiday theme turns on in its season."
    }

    private func fontPreview(_ f: FontChoice) -> Font {
        if f.faces.count == 4, let ui = UIFont(name: f.faces[2], size: 16) { return Font(ui as CTFont) }
        return .system(size: 16, weight: .semibold)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased()).font(.cond(11.5, .semibold)).tracking(1).foregroundStyle(Theme.fg3)
            content()
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.ui(12.5)).foregroundStyle(Theme.fg3)
    }

    private func tiles(_ list: [ThemeDef]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
            ForEach(list) { t in
                let on = look.theme.id == t.id
                Button {
                    if look.autoSeason, let h = Holidays.active(), h.id != t.id {
                        look.autoSeason = false
                        model.showToast("Automatic holiday themes turned off")
                    }
                    look.themeId = t.id
                } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        ThemePreview(theme: t).frame(height: 58)
                        Text(t.name).font(.cond(12.5, .medium)).lineLimit(1)
                    }
                    .padding(8)
                    .foregroundStyle(on ? Theme.hlInk : Theme.fg2)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(on ? Theme.hl : Theme.cell))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t.name + (on ? ", selected" : ""))
            }
        }
    }

    private func swatches(_ list: [(String, String)], selection: Binding<String>) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 42), spacing: 12)], spacing: 12) {
            ForEach(list.indices, id: \.self) { i in
                let item = list[i]
                let on = selection.wrappedValue == item.0
                Button { selection.wrappedValue = item.0 } label: {
                    ZStack {
                        if let hex = Hex.parse(item.0) {
                            Circle().fill(Color(uiColor: UIColor(hex: hex)))
                            Image(systemName: "checkmark").font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Color(uiColor: UIColor(hex: Hex.ink(hex, dark: 0x151821))))
                                .opacity(on ? 1 : 0)
                        } else {
                            Circle().fill(AngularGradient(colors: [Theme.accent, Theme.accent2, Theme.hl, Theme.accent], center: .center))
                            Text("A").font(.cond(13, .bold)).foregroundStyle(Color(uiColor: UIColor(hex: 0x151821)))
                        }
                    }
                    .frame(width: 38, height: 38)
                    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                    .padding(3)
                    .overlay(Circle().stroke(on ? Theme.fg : Color.clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.1 + (on ? ", selected" : ""))
            }
        }
    }
}

/// A tiny drawing of a theme: its room, side menu, highlight pill and accent.
struct ThemePreview: View {
    let theme: ThemeDef

    var body: some View {
        let c = { (h: UInt32) in Color(uiColor: UIColor(hex: h)) }
        ZStack(alignment: .topLeading) {
            c(theme.bg)
            if let a = theme.glowA { RadialGradient(colors: [Color(uiColor: UIColor(hex: a, alpha: 0.5)), .clear], center: .topLeading, startRadius: 0, endRadius: 70) }
            if let b = theme.glowB { RadialGradient(colors: [Color(uiColor: UIColor(hex: b, alpha: 0.4)), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 70) }
            GeometryReader { g in
                let side = g.size.width * 0.15
                RoundedRectangle(cornerRadius: 5).fill(c(Hex.mix(theme.panel, 0xFFFFFF, 0.07)))
                    .frame(width: side, height: g.size.height - 14).offset(x: 7, y: 7)
                RoundedRectangle(cornerRadius: 5).fill(c(theme.hl ?? 0xFFFFFF))
                    .frame(width: g.size.width - side - 20, height: 10).offset(x: side + 13, y: 7)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5).fill(c(Hex.mix(theme.panel, 0xFFFFFF, 0.07)))
                    RoundedRectangle(cornerRadius: 5).fill(LinearGradient(colors: [c(theme.accent).opacity(0), c(theme.accent).opacity(0.6)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: (g.size.width - side - 20) * 0.62)
                }
                .frame(width: g.size.width - side - 20, height: 18).offset(x: side + 13, y: g.size.height - 25)
                if let glyph = theme.glyph {
                    Image(glyph).renderingMode(.template).resizable().scaledToFit()
                        .foregroundStyle(c(theme.glyphColor ?? theme.accent))
                        .frame(width: 15, height: 15).offset(x: g.size.width - 21, y: 22)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}


/// Settings → Playlist options: things that belong to this playlist only.
@MainActor
struct PlaylistOptionsView: View {
    @EnvironmentObject var model: AppModel
    @State private var name = ""
    @State private var ua = ""

    var body: some View {
        Form {
            Section("Playlist") {
                TextField("Name", text: $name)
                    .submitLabel(.done)
                    .onSubmit { model.renamePlaylist(name) }
            }
            .listRowBackground(Theme.cell)
            Section {
                Picker("Guide time shift", selection: binding(\.epgShift)) {
                    ForEach([-3, -2, -1, 0, 1, 2, 3], id: \.self) { h in
                        Text(h == 0 ? "None" : (h > 0 ? "+\(h) h" : "−\(-h) h")).tag(h)
                    }
                }
            } header: {
                Text("TV guide")
            } footer: {
                Text("If every show in the guide starts too early or too late, move the whole guide by a few hours.")
            }
            .listRowBackground(Theme.cell)
            Section("Channels") {
                Picker("Channel numbers", selection: binding(\.numbers)) {
                    Text("From the provider").tag("provider")
                    Text("1, 2, 3… in order").tag("seq")
                }
                Picker("Open on", selection: binding(\.startOn)) {
                    Text("Last channel").tag("last")
                    Text("Favorites").tag("fav")
                    Text("All channels").tag("all")
                }
                Toggle("Hide adult groups", isOn: binding(\.hideAdult))
            }
            .listRowBackground(Theme.cell)
            Section {
                TextField("Default", text: $ua)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { saveUA() }
            } header: {
                Text("User-Agent")
            } footer: {
                Text("The app name sent to your provider. Only change it if your provider asks for a particular one.")
            }
            .listRowBackground(Theme.cell)
            if model.provider?.kind == .xtream {
                Section("Movies & series") {
                    Toggle("Show Movies & Series", isOn: binding(\.showVOD))
                }
                .listRowBackground(Theme.cell)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.menu)
        .navigationTitle("Playlist options")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            name = model.provider?.name ?? ""
            ua = model.options.userAgent
        }
        .onDisappear {
            if name.trimmed != (model.provider?.name ?? "") { model.renamePlaylist(name) }
            saveUA()
        }
    }

    private func saveUA() {
        guard ua.trimmed != model.options.userAgent else { return }
        var o = model.options
        o.userAgent = ua.trimmed
        model.setOptions(o)
    }

    private func binding<T: Equatable>(_ kp: WritableKeyPath<PlaylistOptions, T>) -> Binding<T> {
        Binding(get: { model.options[keyPath: kp] }, set: { v in
            var o = model.options
            o[keyPath: kp] = v
            model.setOptions(o)
        })
    }
}
