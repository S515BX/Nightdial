import Foundation
import Security

/// Passwords live in the Keychain, never in UserDefaults.
enum Keychain {
    static let service = "Nightdial"

    static func set(_ value: String, for key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly   // never leaves this device (not in backups)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}

final class Store {
    static let shared = Store()
    private let defaults = UserDefaults.standard

    private func key(_ k: String) -> String { "nightdial." + k }

    /// Earlier versions used another name for their keys: move playlists, passwords and settings over, once.
    static func moveLegacyData() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "nightdial.moved") else { return }
        let legacy = "tuner."
        for (k, v) in d.dictionaryRepresentation() where k.hasPrefix(legacy) {
            let nk = "nightdial." + String(k.dropFirst(legacy.count))
            if d.object(forKey: nk) == nil { d.set(v, forKey: nk) }
            d.removeObject(forKey: k)
        }
        // Keychain items saved under the old service name
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Tuner",
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var out: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] {
            for item in items {
                guard let account = item[kSecAttrAccount as String] as? String, let data = item[kSecValueData as String] as? Data,
                      let value = String(data: data, encoding: .utf8) else { continue }
                if Keychain.get(account) == nil { Keychain.set(value, for: account) }
            }
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Tuner"] as CFDictionary)
        }
        d.set(true, forKey: "nightdial.moved")
    }

    func strings(_ k: String) -> [String] { defaults.stringArray(forKey: key(k)) ?? [] }
    func setStrings(_ v: [String], _ k: String) { defaults.set(v, forKey: key(k)) }

    func string(_ k: String) -> String? { defaults.string(forKey: key(k)) }
    func remove(_ k: String) { defaults.removeObject(forKey: key(k)) }
    func setString(_ v: String?, _ k: String) {
        if let v { defaults.set(v, forKey: key(k)) } else { defaults.removeObject(forKey: key(k)) }
    }

    func options(_ id: String) -> PlaylistOptions {
        guard let data = defaults.data(forKey: key("plopts." + id)), let o = try? JSONDecoder().decode(PlaylistOptions.self, from: data) else { return PlaylistOptions() }
        return o
    }
    func setOptions(_ o: PlaylistOptions, _ id: String) {
        if let data = try? JSONEncoder().encode(o) { defaults.set(data, forKey: key("plopts." + id)) }
    }

    func channelEdits(_ id: String) -> ChannelEdits {
        guard let data = defaults.data(forKey: key("chedits." + id)), let e = try? JSONDecoder().decode(ChannelEdits.self, from: data) else { return ChannelEdits() }
        return e
    }
    func setChannelEdits(_ e: ChannelEdits, _ id: String) {
        if let data = try? JSONEncoder().encode(e) { defaults.set(data, forKey: key("chedits." + id)) }
    }

    func bool(_ k: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: key(k)) == nil ? fallback : defaults.bool(forKey: key(k))
    }
    func setBool(_ v: Bool, _ k: String) { defaults.set(v, forKey: key(k)) }

    var playlists: [Playlist] {
        get {
            guard let data = defaults.data(forKey: key("playlists")),
                  let list = try? JSONDecoder().decode([Playlist].self, from: data) else { return [] }
            return list
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: key("playlists")) }
        }
    }

    func password(for id: String) -> String { Keychain.get("playlist." + id) ?? "" }
    func setPassword(_ p: String, for id: String) { Keychain.set(p, for: "playlist." + id) }

    /// M3U links often carry the username and password, so they live in the Keychain too.
    func playlistLink(for id: String) -> (url: String, epg: String) {
        (Keychain.get("playlist-url." + id) ?? "", Keychain.get("playlist-epg." + id) ?? "")
    }
    func setPlaylistLink(_ url: String, epg: String, for id: String) {
        Keychain.set(url, for: "playlist-url." + id)
        Keychain.set(epg, for: "playlist-epg." + id)
    }

    /// Where you stopped in movies and episodes.
    func resumes(_ providerId: String) -> [String: ResumePoint] {
        guard let data = defaults.data(forKey: key("resume." + providerId)),
              let v = try? JSONDecoder().decode([String: ResumePoint].self, from: data) else { return [:] }
        return v
    }
    func setResumes(_ v: [String: ResumePoint], _ providerId: String) {
        if let data = try? JSONEncoder().encode(v) { defaults.set(data, forKey: key("resume." + providerId)) }
    }

    func removePlaylist(_ id: String) {
        playlists = playlists.filter { $0.id != id }
        Keychain.delete("playlist." + id)
        Keychain.delete("playlist-url." + id)
        Keychain.delete("playlist-epg." + id)
        for prefix in ["fav.", "recent.", "group.", "lastch.", "hide.", "hideg.", "resume.", "plopts.", "chedits."] { defaults.removeObject(forKey: key(prefix + id)) }
        if string("last") == id { setString(nil, "last") }
    }
}
