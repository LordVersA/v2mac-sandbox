import CryptoKit
import Foundation
import Testing
@testable import SandboxHelper

@Suite struct StoreTests {
    let key = Curve25519.Signing.PrivateKey()
    var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }

    func index(version: Int = 5, expires: String = "2099-01-01T00:00:00Z", minApi: Int = 1, layerSHA: String = String(repeating: "a", count: 64),
               api: Int = 1) -> Data {
        Data("""
        {"version":\(version),"expires":"\(expires)","minApi":\(minApi),
         "plugins":[{"api":\(api),"id":"hello-pty","name":"Hello","version":"1.0","display":"pty","launch":{"cmd":["bash"]},
           "source":{"repo":"https://github.com/x/y","commit":"abc"},"layers":[{"url":"https://example.com/l.tar","sha256":"\(layerSHA)","size":10}]}],
         "templates":[{"id":"t","name":"Terminal","plugins":["hello-pty"]}],
         "revoked":[{"id":"hello-pty","version":"0.9","reason":"leaks"}]}
        """.utf8)
    }

    func sign(_ data: Data) throws -> String { try key.signature(for: Data(SHA256.hash(data: data))).base64EncodedString() }

    @Test func acceptsASignedIndex() throws {
        let data = index()
        let decoded = try Store.verify(index: data, signature: try sign(data), key: publicKey, lastVersion: 4)
        #expect(decoded.plugins.map(\.id) == ["hello-pty"])
        #expect(decoded.templates.first?.plugins == ["hello-pty"])
        #expect(!Store.isExpired(decoded))
        var old = InstalledApp(decoded.plugins[0], granted: [])
        old.version = "0.9"
        #expect(decoded.revocation(of: old)?.reason == "leaks")
    }

    @Test func refusesTamperingRollbackAndNewerStores() throws {
        let data = index()
        var tampered = data
        tampered[tampered.count - 3] ^= 1
        #expect(throws: Store.Refusal.badSignature) { try Store.verify(index: tampered, signature: try sign(data), key: publicKey, lastVersion: nil) }
        #expect(throws: Store.Refusal.badSignature) { try Store.verify(index: data, signature: try sign(data), lastVersion: nil) } // other key
        #expect(throws: Store.Refusal.rollback(have: 6, got: 5)) { try Store.verify(index: data, signature: try sign(data), key: publicKey, lastVersion: 6) }
        let newer = index(minApi: 2)
        #expect(throws: Store.Refusal.tooNew) { try Store.verify(index: newer, signature: try sign(newer), key: publicKey, lastVersion: nil) }
    }

    @Test func expiredIndexStillDecodesButIsExpired() throws {
        let data = index(expires: "2020-01-01T00:00:00Z")
        #expect(Store.isExpired(try Store.verify(index: data, signature: try sign(data), key: publicKey, lastVersion: nil)))
    }

    @Test func dropsPluginsItCannotUse() throws {
        for data in [index(layerSHA: "zz"), index(api: 2)] {
            #expect(try Store.verify(index: data, signature: try sign(data), key: publicKey, lastVersion: nil).plugins.isEmpty)
        }
    }

    @Test func pinnedKeyIsAValidEd25519Key() throws {
        #expect(try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: Store.publicKey)!).rawRepresentation.count == 32)
    }
}
