import Compression
import Foundation

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct HTTPStatusError: Error { let code: Int }
private struct NotXtream: Error {}

private let urlSafe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

extension String {
    var urlEncoded: String { addingPercentEncoding(withAllowedCharacters: urlSafe) ?? self }
}

private func parseJSON(_ data: Data) throws -> Any {
    do { return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
    catch { throw NotXtream() }
}

/// Xtream panels mix strings and numbers freely, so read values loosely.
func looseString(_ v: Any?) -> String? {
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return nil
}

func looseNumber(_ v: Any?) -> Double? {
    if let n = v as? NSNumber { return n.doubleValue }
    if let s = v as? String { return Double(s.trimmed) }
    return nil
}

/// Talks to an Xtream Codes panel (player_api.php).
struct XtreamClient {
    let server: String
    let user: String
    let pass: String

    struct LoginResult {
        let provider: Provider
        let channels: [Channel]
        let groups: [ChannelGroup]
    }

    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 25
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    private var apiBase: String {
        "\(server)/player_api.php?username=\(user.urlEncoded)&password=\(pass.urlEncoded)"
    }

    func fetch(_ extra: String = "", timeout: TimeInterval = 25) async throws -> Data {
        guard let url = URL(string: apiBase + extra) else {
            throw AppError("That server address isn't valid. It should look like http://line.example.com:8080.")
        }
        var request = URLRequest(url: url)
        request.setValue(Net.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = timeout
        let (data, response) = try await XtreamClient.session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPStatusError(code: http.statusCode)
        }
        return data
    }

    // MARK: Server address

    /// Accepts "host:port", a full URL, or a pasted M3U link with username/password in it.
    static func normalize(_ raw: String) -> (server: String, user: String?, pass: String?) {
        var s = raw.trimmed
        guard !s.isEmpty else { return ("", nil, nil) }
        let lower = s.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") { s = "http://" + s }
        guard var comps = URLComponents(string: s), let host = comps.host, !host.isEmpty else { return ("", nil, nil) }
        let items = comps.queryItems ?? []
        let user = items.first(where: { $0.name == "username" })?.value
        let pass = items.first(where: { $0.name == "password" })?.value
        var path = comps.path
        if let r = path.range(of: "/(get|player_api|xmltv|panel_api)\\.php.*$", options: [.regularExpression, .caseInsensitive]) {
            path.removeSubrange(r)
        }
        while path.hasSuffix("/") { path.removeLast() }
        comps.path = path
        comps.query = nil
        comps.fragment = nil
        return (comps.string ?? s, user, pass)
    }

    static func friendly(_ error: Error, server: String) -> AppError {
        if let e = error as? AppError { return e }
        let host = URL(string: server)?.host ?? server
        if let e = error as? HTTPStatusError {
            if e.code == 401 || e.code == 403 {
                return AppError("\(host) refused the sign-in (error \(e.code)). Check your username and password.")
            }
            return AppError("\(host) returned error \(e.code). Check the server address.")
        }
        if error is NotXtream {
            return AppError("\(host) answered, but not like an Xtream Codes server. Check the address. It usually ends with a port, like :8080.")
        }
        if let e = error as? URLError {
            switch e.code {
            case .timedOut: return AppError("\(host) took too long to answer. Check the address and port, then try again.")
            case .notConnectedToInternet: return AppError("You're offline. Connect to the internet and try again.")
            case .cannotFindHost, .dnsLookupFailed: return AppError("Couldn't find \(host). Check the server address.")
            default: return AppError("Couldn't reach \(host). Check the server address and port.")
            }
        }
        return AppError("Couldn't reach \(host). \(error.localizedDescription)")
    }

    // MARK: Sign in

    static func connect(name: String, serverInput: String, user userInput: String, pass passInput: String,
                        step: @escaping @MainActor (String) -> Void) async throws -> LoginResult {
        let norm = normalize(serverInput)
        let server = norm.server
        let user = userInput.isEmpty ? (norm.user ?? "") : userInput
        let pass = passInput.isEmpty ? (norm.pass ?? "") : passInput
        guard !server.isEmpty else { throw AppError("Enter the server address from your provider, like http://line.example.com:8080.") }
        guard !user.isEmpty, !pass.isEmpty else { throw AppError("Enter your username and password.") }

        let client = XtreamClient(server: server, user: user, pass: pass)
        await step("Checking account…")
        let auth: [String: Any]
        do {
            let data = try await client.fetch()
            auth = (try parseJSON(data) as? [String: Any]) ?? [:]
        } catch {
            throw friendly(error, server: server)
        }
        guard let ui = auth["user_info"] as? [String: Any], (looseNumber(ui["auth"]) ?? 0) != 0 else {
            throw AppError("The username or password wasn't accepted.")
        }
        let status = looseString(ui["status"]) ?? "Active"
        var expires: Date? = nil
        if let e = looseNumber(ui["exp_date"]), e > 0 { expires = Date(timeIntervalSince1970: e) }
        if status != "Active" {
            var msg = "This account is \(status.lowercased())."
            if let expires { msg += " It ended on \(Fmt.dateFormatter.string(from: expires))." }
            throw AppError(msg + " Contact your provider.")
        }

        await step("Loading channels…")
        let catsData: Data
        let streamsData: Data
        do {
            async let c = client.fetch("&action=get_live_categories")
            async let s = client.fetch("&action=get_live_streams", timeout: 60)
            catsData = try await c
            streamsData = try await s
        } catch {
            throw friendly(error, server: server)
        }

        let cats = ((try? parseJSON(catsData)) as? [[String: Any]]) ?? []
        guard let streams = (try? parseJSON(streamsData)) as? [[String: Any]], !streams.isEmpty else {
            throw AppError("Signed in, but the provider sent no live channels for this account.")
        }
        var catName: [String: String] = [:]
        var order: [String: Int] = [:]
        for (i, c) in cats.enumerated() {
            if let id = looseString(c["category_id"]) {
                catName[id] = looseString(c["category_name"]) ?? "Channels"
                order[id] = i
            }
        }

        var channels: [Channel] = []
        channels.reserveCapacity(streams.count)
        for (i, s) in streams.enumerated() {
            guard let sid = looseString(s["stream_id"]) else { continue }
            var gid = looseString(s["category_id"]) ?? ""
            if gid.isEmpty, let ids = s["category_ids"] as? [Any], let firstId = ids.first {
                gid = looseString(firstId) ?? ""
            }
            if gid.isEmpty { gid = "none" }
            let name = (looseString(s["name"]) ?? "Channel \(i + 1)").trimmed
            var logo: URL? = nil
            if let icon = looseString(s["stream_icon"]), !icon.isEmpty { logo = URL(string: icon) }
            let number = Int(looseNumber(s["num"]) ?? Double(i + 1))
            channels.append(Channel(
                id: sid,
                num: number,
                name: name,
                logo: logo,
                groupId: gid,
                epgId: (looseString(s["epg_channel_id"]) ?? "").lowercased(),
                archive: (looseNumber(s["tv_archive"]) ?? 0) == 1,
                archiveDays: Int(looseNumber(s["tv_archive_duration"]) ?? 0),
                hue: Double(fnv1a(name) % 360)
            ))
        }
        channels.sort { $0.num < $1.num }

        var counts: [String: Int] = [:]
        for c in channels { counts[c.groupId, default: 0] += 1 }
        let groups = counts
            .map { ChannelGroup(id: $0.key, name: catName[$0.key] ?? "Other channels", count: $0.value) }
            .sorted { (order[$0.id] ?? Int.max) < (order[$1.id] ?? Int.max) }

        var info = AccountInfo()
        info.status = status
        info.expires = expires
        info.maxConnections = looseString(ui["max_connections"])
        info.activeConnections = looseString(ui["active_cons"])
        info.trial = looseString(ui["is_trial"]) == "1"
        info.timezone = looseString((auth["server_info"] as? [String: Any])?["timezone"])

        let id = "x" + String(fnv1a(server + "|" + user), radix: 36)
        let host = URL(string: server)?.host ?? server
        let provider = Provider(id: id, kind: .xtream, name: name.isEmpty ? host : name,
                                server: server, user: user, pass: pass, info: info)
        return LoginResult(provider: provider, channels: channels, groups: groups)
    }

    // MARK: Guide

    func epg(streamId: String) async throws -> [Program] {
        var list: [Program] = []
        if let data = try? await fetch("&action=get_simple_data_table&stream_id=\(streamId.urlEncoded)") {
            list = XtreamClient.parseListings(data)
        }
        if list.isEmpty {
            let data = try await fetch("&action=get_short_epg&limit=60&stream_id=\(streamId.urlEncoded)")
            list = XtreamClient.parseListings(data)
        }
        return list
    }

    static func parseListings(_ data: Data) -> [Program] {
        guard let obj = (try? parseJSON(data)) as? [String: Any],
              let arr = obj["epg_listings"] as? [[String: Any]] else { return [] }
        var out: [Program] = []
        out.reserveCapacity(arr.count)
        for l in arr {
            var start: Date? = nil
            var end: Date? = nil
            if let t = looseNumber(l["start_timestamp"]), t > 0 { start = Date(timeIntervalSince1970: t) }
            if let t = looseNumber(l["stop_timestamp"]), t > 0 { end = Date(timeIntervalSince1970: t) }
            if start == nil { start = parseServerTime(looseString(l["start"])) }
            if end == nil { end = parseServerTime(looseString(l["end"]) ?? looseString(l["stop"])) }
            guard let s = start, let e = end, e > s else { continue }
            let title = decodeBase64(looseString(l["title"]))
            out.append(Program(start: s, end: e, title: title.isEmpty ? "Untitled" : title,
                               desc: decodeBase64(looseString(l["description"]))))
        }
        return cleanPrograms(out)
    }

    static func decodeBase64(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "" }
        if let d = Data(base64Encoded: s, options: .ignoreUnknownCharacters), let t = String(data: d, encoding: .utf8) {
            return t
        }
        return s
    }

    static let serverTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func parseServerTime(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return serverTimeFormatter.date(from: s)
    }

    func downloadXMLTV(from custom: String?) async throws -> URL {
        let address = custom?.nonEmpty ?? "\(server)/xmltv.php?username=\(user.urlEncoded)&password=\(pass.urlEncoded)"
        guard let url = URL(string: address) else { throw AppError("That guide address isn't valid.") }
        var request = URLRequest(url: url)
        request.setValue(Net.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 180
        let (tmp, response) = try await XtreamClient.session.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPStatusError(code: http.statusCode)
        }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("nightdial-guide.xml")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return try XtreamClient.gunzipIfNeeded(dest)
    }

    /// Guide files are often shared compressed (.xml.gz). Unpacks them in chunks so big guides don't fill memory.
    static func gunzipIfNeeded(_ file: URL) throws -> URL {
        guard let input = try? FileHandle(forReadingFrom: file) else { return file }
        defer { try? input.close() }
        let head = input.readData(ofLength: 4096)
        guard head.count > 18, head[0] == 0x1f, head[1] == 0x8b else { return file }
        guard head[2] == 8 else { throw AppError("The guide file is compressed in a format Nightdial can't read.") }
        // Skip the gzip header to reach the deflate data.
        let flags = head[3]
        var i = 10
        if flags & 4 != 0, head.count > i + 1 { i += 2 + (Int(head[i]) | Int(head[i + 1]) << 8) }
        if flags & 8 != 0 { while i < head.count && head[i] != 0 { i += 1 }; i += 1 }
        if flags & 16 != 0 { while i < head.count && head[i] != 0 { i += 1 }; i += 1 }
        if flags & 2 != 0 { i += 2 }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        var remaining = size - i - 8          // the last 8 bytes are a checksum and length
        guard i < head.count, remaining > 0 else { throw AppError("The guide file is damaged.") }
        let dest = file.deletingLastPathComponent().appendingPathComponent("nightdial-guide-unpacked.xml")
        try? FileManager.default.removeItem(at: dest)
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let output = try FileHandle(forWritingTo: dest)
        defer { try? output.close() }
        do {
            let filter = try OutputFilter(.decompress, using: .zlib) { data in
                if let data, !data.isEmpty { output.write(data) }
            }
            try input.seek(toOffset: UInt64(i))
            while remaining > 0 {
                let chunk = input.readData(ofLength: min(1 << 16, remaining))
                if chunk.isEmpty { break }
                remaining -= chunk.count
                try filter.write(chunk)
            }
            try filter.finalize()
        } catch {
            throw AppError("The guide file couldn't be unpacked.")
        }
        try? FileManager.default.removeItem(at: file)
        return dest
    }

    // MARK: On Demand

    func vodCategories(_ kind: VodKind) async -> [VodCategory] {
        let action = kind == .movies ? "get_vod_categories" : "get_series_categories"
        guard let data = try? await fetch("&action=" + action, timeout: 20),
              let arr = (try? parseJSON(data)) as? [[String: Any]] else { return [] }
        return arr.compactMap { c in
            guard let id = looseString(c["category_id"]) else { return nil }
            return VodCategory(id: id, name: (looseString(c["category_name"]) ?? "Other").trimmed)
        }
    }

    func vodItems(_ kind: VodKind) async throws -> [VodItem] {
        let data: Data
        do {
            data = try await fetch("&action=" + (kind == .movies ? "get_vod_streams" : "get_series"), timeout: 90)
        } catch {
            throw XtreamClient.friendly(error, server: server)
        }
        guard let arr = (try? parseJSON(data)) as? [[String: Any]] else { return [] }
        var out: [VodItem] = []
        out.reserveCapacity(arr.count)
        for (i, v) in arr.enumerated() {
            guard let id = looseString(kind == .movies ? v["stream_id"] : v["series_id"]) else { continue }
            let name = (looseString(v["name"]) ?? "Untitled \(i + 1)").trimmed
            let icon = looseString(kind == .movies ? v["stream_icon"] : v["cover"]) ?? ""
            var gid = looseString(v["category_id"]) ?? ""
            if gid.isEmpty, let ids = v["category_ids"] as? [Any], let f = ids.first { gid = looseString(f) ?? "" }
            var rating = looseNumber(v["rating"]) ?? 0
            if rating == 0, let r5 = looseNumber(v["rating_5based"]) { rating = r5 * 2 }
            out.append(VodItem(
                id: id, kind: kind, name: name,
                poster: icon.isEmpty ? nil : URL(string: icon),
                categoryId: gid.isEmpty ? "none" : gid,
                rating: min(10, max(0, rating)),
                year: yearFrom(name, looseString(v["year"]) ?? looseString(v["releaseDate"]) ?? looseString(v["release_date"])),
                ext: (looseString(v["container_extension"]) ?? "mp4").trimmed,
                added: looseNumber(v["added"]) ?? looseNumber(v["last_modified"]) ?? Double(arr.count - i),
                plot: (looseString(v["plot"]) ?? "").trimmed,
                genre: (looseString(v["genre"]) ?? "").trimmed))
        }
        return out
    }

    private static func details(_ info: [String: Any]) -> VodDetails {
        var d = VodDetails()
        d.plot = (looseString(info["plot"]) ?? looseString(info["description"]) ?? "").trimmed
        d.genre = (looseString(info["genre"]) ?? "").trimmed
        d.cast = (looseString(info["cast"]) ?? looseString(info["actors"]) ?? "").trimmed
        d.director = (looseString(info["director"]) ?? "").trimmed
        if let secs = looseNumber(info["duration_secs"]), secs > 0 {
            d.duration = Fmt.duration(secs)
        } else if let dur = looseString(info["duration"])?.trimmed, !dur.isEmpty, dur != "00:00:00" {
            let parts = dur.split(separator: ":").compactMap { Double($0) }
            d.duration = parts.count == 3 ? Fmt.duration(parts[0] * 3600 + parts[1] * 60 + parts[2]) : dur
        } else if let mins = looseNumber(info["episode_run_time"]), mins > 0 {
            d.duration = Fmt.duration(mins * 60)
        }
        d.year = yearFrom("", looseString(info["releasedate"]) ?? looseString(info["releaseDate"]) ?? looseString(info["year"]))
        d.rating = min(10, max(0, looseNumber(info["rating"]) ?? 0))
        if let b = (info["backdrop_path"] as? [Any])?.first.flatMap({ looseString($0) }) ?? looseString(info["backdrop_path"]), !b.isEmpty {
            d.backdrop = URL(string: b)
        }
        if let img = looseString(info["movie_image"]) ?? looseString(info["cover_big"]) ?? looseString(info["cover"]), !img.isEmpty {
            d.poster = URL(string: img)
        }
        return d
    }

    func movieInfo(_ id: String) async throws -> VodDetails {
        let data = try await fetch("&action=get_vod_info&vod_id=\(id.urlEncoded)", timeout: 30)
        guard let obj = (try? parseJSON(data)) as? [String: Any] else { return VodDetails() }
        var d = XtreamClient.details((obj["info"] as? [String: Any]) ?? [:])
        if let md = obj["movie_data"] as? [String: Any], let ext = looseString(md["container_extension"]) { d.ext = ext }
        return d
    }

    func seriesInfo(_ id: String) async throws -> SeriesDetails {
        let data = try await fetch("&action=get_series_info&series_id=\(id.urlEncoded)", timeout: 30)
        guard let obj = (try? parseJSON(data)) as? [String: Any] else { return SeriesDetails() }
        var out = SeriesDetails()
        out.info = XtreamClient.details((obj["info"] as? [String: Any]) ?? [:])
        // Episodes come as {"1": [...], "2": [...]} or as [[...], [...]].
        var lists: [[String: Any]] = []
        if let dict = obj["episodes"] as? [String: Any] {
            for (_, v) in dict { lists += (v as? [[String: Any]]) ?? [] }
        } else if let arr = obj["episodes"] as? [Any] {
            for v in arr { lists += (v as? [[String: Any]]) ?? ((v as? [String: Any]).map { [$0] } ?? []) }
        }
        var bySeason: [Int: [Episode]] = [:]
        for e in lists {
            guard let eid = looseString(e["id"]) else { continue }
            let info = (e["info"] as? [String: Any]) ?? [:]
            let season = Int(looseNumber(e["season"]) ?? looseNumber(info["season"]) ?? 1)
            let num = Int(looseNumber(e["episode_num"]) ?? 0)
            var dur = ""
            if let secs = looseNumber(info["duration_secs"]), secs > 0 { dur = Fmt.duration(secs) }
            let img = looseString(info["movie_image"]) ?? ""
            bySeason[season, default: []].append(Episode(
                id: eid, season: season, number: num,
                title: (looseString(e["title"]) ?? "Episode \(num)").trimmed,
                ext: (looseString(e["container_extension"]) ?? "mp4").trimmed,
                plot: (looseString(info["plot"]) ?? "").trimmed,
                duration: dur,
                image: img.isEmpty ? nil : URL(string: img)))
        }
        for k in bySeason.keys { bySeason[k]?.sort { $0.number < $1.number } }
        out.episodes = bySeason
        out.seasons = bySeason.keys.sorted()
        return out
    }

    func movieURL(_ item: VodItem, ext: String? = nil) -> URL? {
        URL(string: "\(server)/movie/\(user.urlEncoded)/\(pass.urlEncoded)/\(item.id).\((ext?.nonEmpty ?? item.ext.nonEmpty) ?? "mp4")")
    }

    func episodeURL(_ e: Episode) -> URL? {
        URL(string: "\(server)/series/\(user.urlEncoded)/\(pass.urlEncoded)/\(e.id).\(e.ext.nonEmpty ?? "mp4")")
    }

    // MARK: Stream addresses (Apple's player needs HLS, so always .m3u8)

    func liveURL(_ ch: Channel) -> URL? {
        URL(string: "\(server)/live/\(user.urlEncoded)/\(pass.urlEncoded)/\(ch.id).m3u8")
    }

    func catchupURL(_ ch: Channel, _ p: Program, timezone: String?) -> URL? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timezone.flatMap { TimeZone(identifier: $0) } ?? TimeZone.current
        f.dateFormat = "yyyy-MM-dd:HH-mm"
        let minutes = Int((p.end.timeIntervalSince(p.start) / 60).rounded(.up))
        return URL(string: "\(server)/timeshift/\(user.urlEncoded)/\(pass.urlEncoded)/\(minutes)/\(f.string(from: p.start))/\(ch.id).m3u8")
    }
}

/// Streams a (possibly huge) XMLTV file and keeps only programmes for our channels inside the guide window.
final class XMLTVParser: NSObject, XMLParserDelegate {
    private let wanted: [String: [String]]
    private let from: Date
    private let to: Date
    private(set) var lists: [String: [Program]] = [:]
    private(set) var count = 0

    private var current: (ids: [String], start: Date, end: Date)?
    private var title = "", desc = "", episode = "", rating = ""
    private var isNew = false, inRating = false
    private var text = ""
    private var calendars: [Int: Calendar] = [:]

    init(wanted: [String: [String]], from: Date, to: Date) {
        self.wanted = wanted
        self.from = from
        self.to = to
    }

    static func parse(file: URL, wanted: [String: [String]], from: Date, to: Date) -> (lists: [String: [Program]], count: Int)? {
        guard let parser = XMLParser(contentsOf: file) else { return nil }
        let delegate = XMLTVParser(wanted: wanted, from: from, to: to)
        parser.delegate = delegate
        _ = parser.parse()
        var out: [String: [Program]] = [:]
        for (k, v) in delegate.lists { out[k] = cleanPrograms(v) }
        return (out, delegate.count)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "programme":
            current = nil
            if let ch = attributeDict["channel"]?.lowercased(), let ids = wanted[ch],
               let s = time(attributeDict["start"]), let e = time(attributeDict["stop"]), e > from, s < to, e > s {
                current = (ids, s, e)
                title = ""; desc = ""; episode = ""; rating = ""; isNew = false
            }
        case "rating": inRating = true
        case "new": isNew = true
        default: break
        }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if current != nil { text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if current != nil, let s = String(data: CDATABlock, encoding: .utf8) { text += s }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let c = current else { return }
        let t = text.trimmed
        switch elementName {
        case "title": if title.isEmpty { title = t }
        case "desc": if desc.isEmpty { desc = t }
        case "episode-num": if episode.isEmpty { episode = XMLTVParser.episodeLabel(t) }
        case "value": if inRating && rating.isEmpty { rating = t }
        case "rating": inRating = false
        case "programme":
            let p = Program(start: c.start, end: c.end, title: title.isEmpty ? "Untitled" : title, desc: desc,
                            episode: episode, rating: rating, live: false, isNew: isNew)
            for id in c.ids { lists[id, default: []].append(p) }
            count += 1
            current = nil
        default: break
        }
        text = ""
    }

    static func episodeLabel(_ s: String) -> String {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count >= 2, let season = Int(parts[0].trimmingCharacters(in: .whitespaces)),
           let ep = Int(parts[1].trimmingCharacters(in: .whitespaces).split(separator: "/").first ?? "") {
            return "S\(season + 1) E\(ep + 1)"
        }
        return s
    }

    /// "20261024140000 +0100"
    private func time(_ s: String?) -> Date? {
        guard let s, s.count >= 12 else { return nil }
        let chars = Array(s)
        func num(_ at: Int, _ len: Int) -> Int? {
            guard at + len <= chars.count else { return nil }
            return Int(String(chars[at..<(at + len)]))
        }
        guard let y = num(0, 4), let mo = num(4, 2), let d = num(6, 2), let h = num(8, 2), let mi = num(10, 2) else { return nil }
        var comps = DateComponents()
        comps.year = y; comps.month = mo; comps.day = d; comps.hour = h; comps.minute = mi
        comps.second = num(12, 2) ?? 0
        var offset = TimeZone.current.secondsFromGMT()
        if let r = s.range(of: "[+-][0-9]{4}", options: .regularExpression) {
            let o = String(s[r])
            let sign = o.hasPrefix("-") ? -1 : 1
            let hh = Int(o.dropFirst().prefix(2)) ?? 0
            let mm = Int(o.suffix(2)) ?? 0
            offset = sign * (hh * 3600 + mm * 60)
        }
        if calendars[offset] == nil {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(secondsFromGMT: offset) ?? TimeZone.current
            calendars[offset] = cal
        }
        return calendars[offset]?.date(from: comps)
    }
}
