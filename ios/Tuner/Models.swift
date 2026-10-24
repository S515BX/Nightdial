import Foundation

func fnv1a(_ s: String) -> UInt32 {
    var h: UInt32 = 2166136261
    for b in s.utf8 {
        h ^= UInt32(b)
        h = h &* 16777619
    }
    return h
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

struct Channel: Identifiable, Hashable {
    let id: String          // Xtream stream_id
    let num: Int
    let name: String
    let logo: URL?
    let groupId: String
    let epgId: String
    let archive: Bool       // provider keeps catch-up for this channel
    let archiveDays: Int
    let hue: Double
    var demoKind: String? = nil
    var demoStream: URL? = nil
    /// M3U playlists: the channel's own stream link.
    var streamURL: URL? = nil

    var initials: String { Channel.makeInitials(name) }

    /// Name without a country prefix like "US: ", for A–Z sorting.
    static func sortName(_ name: String) -> String {
        var s = name
        if let r = s.range(of: "^[A-Z]{2,3}\\s*[:|]\\s*", options: .regularExpression) { s.removeSubrange(r) }
        return s
    }

    static func makeInitials(_ name: String) -> String {
        var s = name
        if let r = s.range(of: "^[A-Z]{2,3}\\s*[:|]\\s*", options: .regularExpression) {
            s.removeSubrange(r)
        }
        let words = s.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard let first = words.first else { return "?" }
        if words.count > 1, let a = first.first, let b = words[1].first {
            return String([a, b]).uppercased()
        }
        return String(first.prefix(2)).uppercased()
    }
}

struct Program: Hashable {
    var start: Date
    var end: Date
    var title: String
    var desc: String = ""
    var episode: String = ""
    var rating: String = ""
    var live: Bool = false
    var isNew: Bool = false

    func isNow(_ now: Date) -> Bool { start <= now && end > now }
}

struct ChannelGroup: Identifiable, Hashable {
    let id: String
    let name: String
    let count: Int
}

struct Playlist: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var server: String
    var user: String
    /// nil or "xtream" for Xtream Codes, "m3u" for an M3U link (the link itself is kept in the Keychain).
    var kind: String? = nil
    var host: String? = nil
}

struct AccountInfo: Hashable {
    var status: String = "Active"
    var expires: Date? = nil
    var maxConnections: String? = nil
    var activeConnections: String? = nil
    var trial: Bool = false
    var timezone: String? = nil
}

enum ProviderKind { case demo, xtream, m3u }

struct Provider {
    let id: String
    let kind: ProviderKind
    var name: String
    var server: String = ""
    var user: String = ""
    var pass: String = ""
    var info = AccountInfo()
    var url: String = ""
    var epgUrl: String = ""
}

enum EPGLoad { case queued, loading, done, failed }

/// Sorts, removes duplicates and trims overlaps so the guide never draws two blocks on top of each other.
func cleanPrograms(_ input: [Program]) -> [Program] {
    let sorted = input.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
    var out: [Program] = []
    out.reserveCapacity(sorted.count)
    for p in sorted {
        if let last = out.last {
            if last.start == p.start { continue }
            if last.end > p.start { out[out.count - 1].end = p.start }
        }
        out.append(p)
    }
    return out.filter { $0.end > $0.start }
}

extension Array where Element == Program {
    /// Index of the first program that ends after `t`.
    func firstIndex(endingAfter t: Date) -> Int {
        var lo = 0, hi = count
        while lo < hi {
            let m = (lo + hi) / 2
            if self[m].end <= t { lo = m + 1 } else { hi = m }
        }
        return lo
    }

    func program(containing t: Date) -> Program? {
        let i = firstIndex(endingAfter: t)
        guard i < count, self[i].start <= t else { return nil }
        return self[i]
    }

    /// The program at `t`, or the closest one when `t` falls in a gap.
    func program(near t: Date) -> Program? {
        guard !isEmpty else { return nil }
        var lo = 0, hi = count - 1
        while lo < hi {
            let m = (lo + hi + 1) / 2
            if self[m].start <= t { lo = m } else { hi = m - 1 }
        }
        let p = self[lo]
        if p.start <= t && p.end > t { return p }
        if p.start > t { return self[0].start.timeIntervalSince(t) < 6 * 3600 ? self[0] : nil }
        if lo + 1 < count, self[lo + 1].start.timeIntervalSince(t) < 3 * 3600 { return self[lo + 1] }
        return t.timeIntervalSince(p.end) < 3 * 3600 ? p : nil
    }

    func neighbor(of p: Program, _ offset: Int) -> Program? {
        guard let i = self.firstIndex(where: { $0.start == p.start }) else { return nil }
        let j = i + offset
        return indices.contains(j) ? self[j] : nil
    }
}

// MARK: On Demand (movies and series)

enum VodKind: String, Hashable, CaseIterable {
    case movies, series
    var title: String { self == .movies ? "Movies" : "Series" }
}

struct VodCategory: Identifiable, Hashable {
    let id: String
    let name: String
}

/// A movie or a series in the provider's catalog.
struct VodItem: Identifiable, Hashable {
    let id: String
    let kind: VodKind
    let name: String
    let poster: URL?
    let categoryId: String
    let rating: Double       // out of 10, 0 when unknown
    let year: String
    let ext: String          // movies: container extension (mp4, mkv…)
    let added: Double
    var plot: String = ""
    var genre: String = ""

    var hue: Double { Double(fnv1a(name) % 360) }
    var resumeKey: String { (kind == .movies ? "m:" : "s:") + id }
}

struct VodDetails: Hashable {
    var plot = ""
    var genre = ""
    var cast = ""
    var director = ""
    var duration = ""
    var year = ""
    var rating: Double = 0
    var backdrop: URL? = nil
    var poster: URL? = nil
    var ext = ""
}

struct Episode: Identifiable, Hashable {
    let id: String
    let season: Int
    let number: Int
    let title: String
    let ext: String
    var plot = ""
    var duration = ""
    var image: URL? = nil

    var resumeKey: String { "e:" + id }
}

struct SeriesDetails: Hashable {
    var info = VodDetails()
    var seasons: [Int] = []
    var episodes: [Int: [Episode]] = [:]
}

/// Where you stopped in a movie or episode.
struct ResumePoint: Codable, Hashable {
    var pos: Double
    var dur: Double
    var at: Double
    var title: String
    /// Episodes: the series they belong to, for "Continue watching".
    var series: String? = nil

    var fraction: Double { dur > 0 ? min(1, max(0, pos / dur)) : 0 }
}

/// Pulls a release year out of a title like "Movie Name (2019)".
func yearFrom(_ name: String, _ fallback: String?) -> String {
    if let f = fallback?.trimmed, f.count >= 4, let y = Int(f.prefix(4)), y > 1900 { return String(y) }
    if let r = name.range(of: "\\((19|20)[0-9]{2}\\)", options: .regularExpression) {
        return String(name[r].dropFirst().dropLast())
    }
    return ""
}
