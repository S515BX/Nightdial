import Foundation

/// Reads M3U / M3U8 playlists (#EXTINF lines with tvg-id, tvg-logo, group-title...).
enum M3U {
    struct Parsed {
        var channels: [Channel]
        var groups: [ChannelGroup]
        var epgURL: String
    }

    private static func attributes(_ s: Substring) -> [String: String] {
        var out: [String: String] = [:]
        let ns = String(s) as NSString
        let re = try? NSRegularExpression(pattern: "([A-Za-z0-9_-]+)=\"([^\"]*)\"")
        re?.enumerateMatches(in: String(s), range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, m.numberOfRanges == 3 else { return }
            out[ns.substring(with: m.range(at: 1)).lowercased()] = ns.substring(with: m.range(at: 2))
        }
        return out
    }

    static func parse(_ text: String) -> Parsed {
        var epg = ""
        var items: [(attrs: [String: String], name: String, group: String, url: String)] = []
        var current: (attrs: [String: String], name: String, group: String)? = nil
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: { $0.isNewline }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let upper = line.uppercased()
            if upper.hasPrefix("#EXTM3U") {
                let a = attributes(Substring(line))
                epg = (a["x-tvg-url"] ?? a["url-tvg"] ?? a["tvg-url"] ?? "").split(separator: ",").first.map { String($0).trimmed } ?? ""
            } else if upper.hasPrefix("#EXTINF") {
                // The title follows the first comma that isn't inside quotes.
                var inQuotes = false
                var cut: String.Index? = nil
                var i = line.index(line.startIndex, offsetBy: min(8, line.count))
                while i < line.endIndex {
                    let c = line[i]
                    if c == "\"" { inQuotes.toggle() } else if c == "," && !inQuotes { cut = i; break }
                    i = line.index(after: i)
                }
                let head = cut.map { line[..<$0] } ?? Substring(line)
                let title = cut.map { String(line[line.index(after: $0)...]).trimmed } ?? ""
                current = (attributes(head), title, "")
            } else if upper.hasPrefix("#EXTGRP:") {
                current?.group = String(line.dropFirst(8)).trimmed
            } else if line.hasPrefix("#") {
                continue
            } else {
                let lower = line.lowercased()
                if let c = current, lower.hasPrefix("http://") || lower.hasPrefix("https://") {
                    items.append((c.attrs, c.name, c.group, line))
                }
                current = nil
            }
        }
        var groupOrder: [String] = []
        var groupNames: [String: String] = [:]
        var counts: [String: Int] = [:]
        var seen = Set<String>()
        var channels: [Channel] = []
        for (k, it) in items.enumerated() {
            let a = it.attrs
            let name = (it.name.isEmpty ? (a["tvg-name"] ?? "") : it.name).trimmed.nonEmpty ?? "Channel \(k + 1)"
            let gname = (a["group-title"] ?? it.group).trimmed.nonEmpty ?? "Other channels"
            let gid = "g" + String(fnv1a(gname), radix: 36)
            if groupNames[gid] == nil { groupNames[gid] = gname; groupOrder.append(gid) }
            counts[gid, default: 0] += 1
            var id = "m" + String(fnv1a((a["tvg-id"] ?? "") + "|" + name + "|" + gname), radix: 36)
            while seen.contains(id) { id += "x" }
            seen.insert(id)
            let num = Int(a["tvg-chno"] ?? a["channel-number"] ?? a["tvg-num"] ?? "") ?? (k + 1)
            channels.append(Channel(id: id, num: num, name: name, logo: (a["tvg-logo"] ?? a["logo"]).flatMap { URL(string: $0) },
                                    groupId: gid, epgId: (a["tvg-id"] ?? a["tvg-name"] ?? name).lowercased(),
                                    archive: false, archiveDays: 0, hue: Double(fnv1a(name) % 360),
                                    streamURL: playableURL(it.url)))
        }
        let groups = groupOrder.map { ChannelGroup(id: $0, name: groupNames[$0] ?? "Channels", count: counts[$0] ?? 0) }
        let lowerEpg = epg.lowercased()
        return Parsed(channels: channels, groups: groups, epgURL: lowerEpg.hasPrefix("http://") || lowerEpg.hasPrefix("https://") ? epg : "")
    }

    /// Apple's player needs HLS. Xtream-style ".ts" live links usually also exist as ".m3u8", so ask for that.
    static func playableURL(_ s: String) -> URL? {
        if s.lowercased().hasSuffix(".ts"), s.contains("/live/") {
            return URL(string: String(s.dropLast(3)) + ".m3u8")
        }
        return URL(string: s)
    }

    static func connect(name: String, urlInput: String, epgInput: String, step: @escaping @MainActor (String) -> Void) async throws -> XtreamClient.LoginResult {
        var s = urlInput.trimmed
        guard !s.isEmpty else { throw AppError("Paste the M3U playlist link from your provider.") }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "http://" + s }
        guard let url = URL(string: s), let host = url.host, !host.isEmpty else {
            throw AppError("That doesn't look like a web link. It should start with http:// or https://.")
        }
        // An Xtream Codes get.php link: sign in with Xtream instead, which adds catch-up, the full guide and On Demand.
        if url.path.lowercased().hasSuffix("/get.php") {
            let n = XtreamClient.normalize(s)
            if let u = n.user, let p = n.pass,
               let r = try? await XtreamClient.connect(name: name, serverInput: n.server, user: u, pass: p, step: step) {
                return r
            }
        }
        await step("Loading playlist…")
        var request = URLRequest(url: url)
        request.setValue(Net.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120
        let data: Data
        do {
            let (d, response) = try await XtreamClient.session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw AppError("\(host) returned error \(http.statusCode). Check the playlist link.")
            }
            data = d
        } catch let e as AppError {
            throw e
        } catch let e as URLError where e.code == .timedOut {
            throw AppError("\(host) took too long to send the playlist. Try again.")
        } catch {
            throw AppError("Couldn't reach \(host). Check the link and that you're online.")
        }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let parsed = parse(text)
        if parsed.channels.isEmpty {
            throw AppError(text.prefix(300).uppercased().contains("#EXTM3U") ? "The playlist loaded, but it has no channels in it." : "That link didn't return an M3U playlist. Check the address.")
        }
        let id = "m" + String(fnv1a(s), radix: 36)
        let epg = epgInput.trimmed.nonEmpty ?? parsed.epgURL
        let provider = Provider(id: id, kind: .m3u, name: name.trimmed.nonEmpty ?? host, info: AccountInfo(status: "Active"), url: s, epgUrl: epg)
        return XtreamClient.LoginResult(provider: provider, channels: parsed.channels, groups: parsed.groups)
    }
}
