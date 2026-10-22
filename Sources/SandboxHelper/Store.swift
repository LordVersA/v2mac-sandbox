import CryptoKit
import Foundation
import Observation

/// The signed plugin index (plan §7, `../store`): `index.json` and `index.json.sig`, the base64
/// Ed25519 signature of SHA-256(index.json) made on the maintainer's Ledger (M0 0.12).
struct StoreIndex: Decodable, Equatable {
    struct Template: Decodable, Equatable {
        var id: String
        var name: String
        var plugins: [String]
    }

    struct Revoked: Decodable, Equatable {
        var id: String
        var version: String
        var reason: String
    }

    var version: Int
    var expires: Date
    var minApi: Int
    var plugins: [PluginManifest]
    var templates: [Template]
    var revoked: [Revoked]

    func revocation(of app: InstalledApp) -> Revoked? { revoked.first { $0.id == app.id && $0.version == app.version } }
    func plugin(_ id: String) -> PluginManifest? { plugins.first { $0.id == id } }
}

enum Store {
    static let indexURL = URL(string: "https://raw.githubusercontent.com/LordVersA/v2mac-store/main/index.json")!
    /// The store key on the maintainer's Ledger (SSH/PGP Agent app, the fixed path in
    /// `../store/Scripts/ledger-sign.py`), as in spike 0.12's `key.pub`.
    static let publicKey = "sCtOaz07SFCyeuNRtk2TT9ZYLD03VhXjv3WlIiywnBs="

    enum Refusal: Error, Equatable, LocalizedError {
        case badSignature, rollback(have: Int, got: Int), tooNew, unreadable
        var errorDescription: String? {
            switch self {
            case .badSignature: "The store index is not signed by V2Mac's store key."
            case .rollback(let have, let got): "The store index is older (\(got)) than one already seen (\(have))."
            case .tooNew: "The store needs a newer V2Mac."
            case .unreadable: "The store index can't be read."
            }
        }
    }

    /// Checks `index` against `signature` and the last version seen; an expired index still decodes
    /// (revocations apply), but `isExpired` blocks installs and updates. Plugins this sandbox can't
    /// use or that break the rules are left out.
    static func verify(index: Data, signature: String, key: String = publicKey, lastVersion: Int?) throws -> StoreIndex {
        guard let raw = Data(base64Encoded: key), let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
              let sig = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)),
              publicKey.isValidSignature(sig, for: Data(SHA256.hash(data: index))) else { throw Refusal.badSignature }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var decoded = try? decoder.decode(StoreIndex.self, from: index) else { throw Refusal.unreadable }
        if let lastVersion, decoded.version < lastVersion { throw Refusal.rollback(have: lastVersion, got: decoded.version) }
        guard decoded.minApi <= PluginManifest.api else { throw Refusal.tooNew }
        decoded.plugins = decoded.plugins.filter { (try? $0.validateForStore()) != nil }
        return decoded
    }

    static func isExpired(_ index: StoreIndex, now: Date = Date()) -> Bool { index.expires <= now }

    /// Debug: a store served on 127.0.0.1 (`V2MAC_SANDBOX_STORE`), for testing installs end to end.
    static func allowsLocal(_ url: URL) -> Bool { url.scheme == "http" && url.host == "127.0.0.1" }
}

/// The index as the helper uses it: fetched through V2Mac when the Sandbox window opens and daily,
/// checked, and the highest version seen kept in `store.json` so an older index is refused later.
@MainActor @Observable final class StoreClient {
    private(set) var index: StoreIndex?
    private(set) var problem: String?
    var isExpired: Bool { index.map { Store.isExpired($0) } ?? false }

    @ObservationIgnored var fetch: (URL) async -> URL? = { _ in nil }
    @ObservationIgnored private let state: URL
    @ObservationIgnored private var lastRefresh: Date?
    @ObservationIgnored private let base: URL
    @ObservationIgnored private let key: String

    init(root: URL) {
        state = root.appendingPathComponent("store.json")
        let env = ProcessInfo.processInfo.environment
        // Debug: `V2MAC_SANDBOX_STORE=http://127.0.0.1:<port>/` and its test key; never a remote store.
        if let local = env["V2MAC_SANDBOX_STORE"].flatMap(URL.init(string:)), Store.allowsLocal(local), let key = env["V2MAC_SANDBOX_STORE_KEY"] {
            base = local
            self.key = key
        } else {
            base = Store.indexURL.deletingLastPathComponent()
            key = Store.publicKey
        }
    }

    private var lastVersion: Int? {
        get { (try? Data(contentsOf: state)).flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) }?["version"] }
        set { if let newValue, let data = try? JSONEncoder().encode(["version": newValue]) { try? data.write(to: state) } }
    }

    /// At most once a day unless `force`.
    func refresh(force: Bool = false) async {
        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < 86_400 { return }
        lastRefresh = Date()
        guard let indexFile = await fetch(base.appendingPathComponent("index.json")),
              let sigFile = await fetch(base.appendingPathComponent("index.json.sig")),
              let data = try? Data(contentsOf: indexFile), let sig = try? String(contentsOf: sigFile, encoding: .utf8)
        else { problem = "The store can't be reached."; return }
        do {
            let checked = try Store.verify(index: data, signature: sig, key: key, lastVersion: lastVersion)
            index = checked
            lastVersion = max(checked.version, lastVersion ?? 0)
            problem = isExpired ? "The store index has expired; installs and updates wait for a new one." : nil
        } catch {
            problem = error.localizedDescription
            log("store index refused: \(error.localizedDescription)")
        }
    }
}
