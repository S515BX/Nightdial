import SwiftUI
import UIKit

@MainActor
struct LoginView: View {
    @EnvironmentObject var model: AppModel
    @State private var name = ""
    @State private var server = ""
    @State private var user = ""
    @State private var pass = ""
    @State private var showPassword = false
    @State private var remember = true
    @State private var busy = false
    @State private var step = ""
    @State private var errorText: String?
    @State private var infoText: String?
    @State private var lastServer = ""
    @State private var kind = "xtream"
    @State private var m3u = ""
    @State private var epg = ""
    @FocusState private var focused: Field?

    enum Field: Hashable { case name, server, user, pass, m3u, epg }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Picker("Playlist type", selection: $kind) {
                    Text("Xtream Codes").tag("xtream")
                    Text("M3U playlist").tag("m3u")
                }
                .pickerStyle(.segmented)
                .disabled(busy)
                VStack(alignment: .leading, spacing: 14) {
                    field("Playlist name", text: $name, prompt: "My provider", field: .name, capitalize: true)
                    if kind == "m3u" {
                        field("M3U playlist link", text: $m3u, prompt: "http://provider.example.com/playlist.m3u", field: .m3u, keyboard: .URL)
                        field("TV guide link (XMLTV, optional)", text: $epg, prompt: "Leave empty to use the playlist's guide", field: .epg, keyboard: .URL)
                    } else {
                        field("Server URL", text: $server, prompt: "http://line.example.com:8080", field: .server, keyboard: .URL)
                        field("Username", text: $user, prompt: "", field: .user, content: .username)
                        passwordField
                    }
                }
                Toggle("Remember this playlist on this device", isOn: $remember)
                    .tint(Theme.accent)
                    .font(.ui(15))
                    .foregroundStyle(Theme.fg2)
                if let infoText {
                    Text(infoText).font(.ui(14)).foregroundStyle(Theme.ok)
                }
                if let errorText {
                    Text(errorText)
                        .font(.ui(14))
                        .foregroundStyle(Color(uiColor: UIColor(hex: 0xFFC0BA)))
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.live.opacity(0.13)))
                }
                actions
                Text("Your details stay on this device and are only sent to your provider.")
                    .font(.ui(13))
                    .foregroundStyle(Theme.fg3)
            }
            .padding(26)
            .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Theme.panel))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
            .frame(maxWidth: 480)
            .padding(.horizontal, 16)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.black.opacity(0.55).ignoresSafeArea())
        .onAppear(perform: prefill)
        .onChange(of: server) { value in handleServerChange(value) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                BrandMark(size: 42)
                Text("Nightdial").font(.cond(24, .semibold)).foregroundStyle(Theme.fg)
            }
            Label(kind == "m3u" ? "M3U PLAYLIST" : "XTREAM CODES", systemImage: kind == "m3u" ? "list.bullet.rectangle" : "dot.radiowaves.left.and.right")
                .font(.cond(11.5, .semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(Theme.accentSoft))
            Text("Add a playlist").font(.cond(28, .semibold)).foregroundStyle(Theme.fg)
            Text(kind == "m3u"
                 ? "Paste the M3U link from your IPTV provider. Add a TV guide link if your provider gave you one."
                 : "Enter the server address, username and password from your IPTV provider. You can also paste your full M3U link into Server URL.")
                .font(.ui(15))
                .foregroundStyle(Theme.fg2)
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button(action: signIn) {
                HStack(spacing: 10) {
                    if busy { ProgressView().tint(Theme.accentInk) }
                    Text(busy ? step : "Sign in")
                }
                .primaryButton()
            }
            .disabled(busy)
            if model.canCancelLogin {
                Button("Cancel") { model.showLogin = false }
                    .font(.ui(15))
                    .foregroundStyle(Theme.fg2)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
        }
        .buttonStyle(.plain)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.ui(12.5, .medium))
            .foregroundStyle(Theme.fg2)
    }

    private func field(_ title: String, text: Binding<String>, prompt: String, field f: Field,
                       keyboard: UIKeyboardType = .default, content: UITextContentType? = nil, capitalize: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            label(title)
            TextField("", text: text, prompt: Text(prompt).foregroundColor(Theme.fg3))
                .keyboardType(keyboard)
                .textContentType(content)
                .textInputAutocapitalization(capitalize ? TextInputAutocapitalization.words : TextInputAutocapitalization.never)
                .autocorrectionDisabled()
                .focused($focused, equals: f)
                .submitLabel(.next)
                .onSubmit { advance(from: f) }
                .inputBox(focused: focused == f)
        }
    }

    private var passwordField: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("Password")
            HStack(spacing: 8) {
                Group {
                    if showPassword {
                        TextField("", text: $pass)
                    } else {
                        SecureField("", text: $pass)
                    }
                }
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused, equals: .pass)
                .submitLabel(.go)
                .onSubmit(signIn)
                Button {
                    showPassword.toggle()
                } label: {
                    Image(systemName: showPassword ? "eye.slash" : "eye").foregroundStyle(Theme.fg3)
                }
                .accessibilityLabel(showPassword ? "Hide password" : "Show password")
            }
            .inputBox(focused: focused == .pass)
        }
    }

    private func advance(from f: Field) {
        switch f {
        case .name: focused = .server
        case .server: focused = .user
        case .user: focused = .pass
        case .pass: signIn()
        case .m3u: focused = .epg
        case .epg: signIn()
        }
    }

    private func prefill() {
        if UserDefaults.standard.string(forKey: "tuner.debug.login") == "m3u" { kind = "m3u" }   // screenshots
        guard let p = model.loginPrefill else { return }
        kind = p.kind
        m3u = p.m3u
        epg = p.epg
        name = p.name
        server = p.server
        lastServer = p.server
        user = p.user
        pass = p.pass
        errorText = p.error
    }

    /// When a whole M3U link is pasted, pull the username and password out of it.
    private func handleServerChange(_ value: String) {
        defer { lastServer = value }
        guard value.count - lastServer.count > 1 else { return }
        let n = XtreamClient.normalize(value)
        if let u = n.user, let p = n.pass {
            user = u
            pass = p
            server = n.server
            infoText = "Filled in your username and password from the link."
        }
    }

    private func signIn() {
        guard !busy else { return }
        errorText = nil
        busy = true
        focused = nil
        if kind == "m3u" {
            step = "Loading playlist…"
            let values = (name.trimmed, m3u.trimmed, epg.trimmed)
            Task { @MainActor in
                do {
                    try await model.signInM3U(name: values.0, url: values.1, epg: values.2, remember: remember) { text in
                        step = text
                    }
                } catch {
                    errorText = error.localizedDescription
                }
                busy = false
            }
            return
        }
        step = "Checking account…"
        let values = (name.trimmed, server.trimmed, user.trimmed, pass)
        Task { @MainActor in
            do {
                try await model.signIn(name: values.0, server: values.1, user: values.2, pass: values.3, remember: remember) { text in
                    step = text
                }
            } catch {
                errorText = error.localizedDescription
            }
            busy = false
        }
    }
}
