import Foundation
import Testing
@testable import SandboxHelper
import V2MacCore

@Suite struct SandboxConfigTests {
    let a = MiniVM(id: "aaaa", name: "Work", index: 1, uuid: "11111111-1111-1111-1111-111111111111", exit: "s1")
    let b = MiniVM(id: "bbbb", name: "Home", index: 2, uuid: "22222222-2222-2222-2222-222222222222", exit: nil)
    let server: JSONValue = ["protocol": "vless", "tag": "proxy",
                             "settings": ["vnext": [["address": "1.2.3.4", "port": 443, "users": [["id": "33333333-3333-3333-3333-333333333333", "encryption": "none"]]]]],
                             "streamSettings": ["security": "tls"]]

    var host: JSONValue {
        SandboxConfig.hostCore(vms: [a, b], ports: ["aaaa": .init(inbound: 2001, check: 2002), "bbbb": .init(inbound: 2003, check: 2004)],
                               outbounds: ["aaaa": server], apiPort: 2000, checkPassword: "pw")
    }

    @Test func hostCoreRoutesEachMiniVMToItsOwnExitAndBlocksTheRest() throws {
        let outbounds = try #require(host["outbounds"]?.arrayValue)
        #expect(outbounds.map { $0["tag"]?.stringValue } == ["block", "vm-aaaa", "vm-bbbb"])
        #expect(outbounds[0]["protocol"] == "blackhole") // unmatched traffic
        #expect(outbounds[1]["settings"] == server["settings"])
        #expect(outbounds[2]["protocol"] == "blackhole") // no exit picked: fail closed
        let inbounds = try #require(host["inbounds"]?.arrayValue)
        #expect(inbounds.allSatisfy { $0["listen"] == "127.0.0.1" })
        #expect(inbounds[1] == ["tag": "vm-aaaa", "listen": "127.0.0.1", "port": 2001, "protocol": "vless",
                                "settings": ["clients": [["id": "11111111-1111-1111-1111-111111111111"]], "decryption": "none"]])
        #expect(inbounds[2]["settings"]?["auth"] == "password")
        #expect(host["routing"]?["rules"]?[1] == ["inboundTag": ["vm-aaaa", "check-aaaa"], "outboundTag": "vm-aaaa"])
    }

    @Test func guestXrayAnswersDNSFakeBlocksPrivateAndRelaysPerMiniVM() throws {
        let guest = SandboxConfig.guestXray(vms: [a, b])
        #expect(guest["dns"] == ["servers": ["fakedns"]])
        #expect(guest["inbounds"]?[1] == ["tag": "vm-bbbb", "listen": "0.0.0.0", "port": 12002, "protocol": "dokodemo-door",
                                          "settings": ["network": "tcp,udp", "followRedirect": true],
                                          "streamSettings": ["sockopt": ["tproxy": "tproxy"]],
                                          "sniffing": ["enabled": true, "destOverride": ["fakedns"]]])
        #expect(guest["outbounds"]?[2]?["settings"]?["vnext"]?[0]?["port"] == 11001)
        let rules = try #require(guest["routing"]?["rules"]?.arrayValue)
        #expect(rules[0]["outboundTag"] == "dns-out")
        #expect(rules[1]["outboundTag"] == "block")
        #expect(rules[1]["ip"]?.arrayValue?.contains("10.0.0.0/8") == true)
        #expect(rules[3] == ["inboundTag": ["vm-bbbb"], "outboundTag": "host-bbbb"])
    }

    @Test func gatewayRulesTProxyEachVethAndDropEverythingElse() {
        #expect(SandboxConfig.gatewayNFT(vms: [a, b]) == """
        table inet v2mac
        delete table inet v2mac
        table inet v2mac {
          chain prerouting {
            type filter hook prerouting priority mangle; policy drop;
            iifname "lo" accept
            iifname "vg1" meta nfproto ipv4 meta l4proto { tcp, udp } meta mark set 1 tproxy ip to :12001 accept
            iifname "vg2" meta nfproto ipv4 meta l4proto { tcp, udp } meta mark set 1 tproxy ip to :12002 accept
          }
          chain input {
            type filter hook input priority filter; policy drop;
            iifname "lo" accept
            meta mark 1 accept
          }
          chain forward {
            type filter hook forward priority filter; policy drop;
          }
        }

        """)
    }

    @Test func newMiniVMTakesTheFirstFreeIndex() {
        #expect(MiniVM.new(name: "x", exit: nil, taken: [a])?.index == 2)
        #expect(MiniVM.new(name: "x", exit: nil, taken: [b])?.index == 1)
    }

    /// The real xray must accept both configs (skipped without ../app/Vendor/core/xray).
    @Test func xrayAcceptsBothConfigs() throws {
        let xray = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../app/Vendor/core/xray").standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: xray.path) else { return }
        for config in [host, SandboxConfig.guestXray(vms: [a, b])] {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("sandbox-\(UUID().uuidString).json")
            try config.data().write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            let process = Process()
            process.executableURL = xray
            process.arguments = ["run", "-test", "-c", file.path]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = out
            try process.run()
            process.waitUntilExit()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            #expect(process.terminationStatus == 0, "\(text)")
        }
    }
}
