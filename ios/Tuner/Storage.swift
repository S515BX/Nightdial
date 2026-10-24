import Foundation
import Security

/// Passwords live in the Keychain, never in UserDefaults.
enum Keychain {
    private static let service = "Tuner"

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

    private func key(_ k: String) -> String { "tuner." + k }

    func strings(_ k: String) -> [String] { defaults.stringArray(forKey: key(k)) ?? [] }
    func setStrings(_ v: [String], _ k: String) { defaults.set(v, forKey: key(k)) }

    func string(_ k: String) -> String? { defaults.string(forKey: key(k)) }
    func remove(_ k: String) { defaults.removeObject(forKey: key(k)) }
    func setString(_ v: String?, _ k: String) {
        if let v { defaults.set(v, forKey: key(k)) } else { defaults.removeObject(forKey: key(k)) }
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
        for prefix in ["fav.", "recent.", "group.", "lastch.", "hide.", "hideg.", "resume."] { defaults.removeObject(forKey: key(prefix + id)) }
        if string("last") == id { setString(nil, "last") }
    }
}
