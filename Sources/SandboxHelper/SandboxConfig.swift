import Foundation
import V2MacCore

/// A mini VM (plan "Mini VM"): one pod in the shared Linux VM, with its own exit. `index` picks its
/// veth, subnet and ports (sandbox.sh); `uuid` is its VLESS user on the sandbox core.
struct MiniVM: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var index: Int
    var uuid: String
    /// The V2Mac server it exits through; nil blocks all its traffic.
    var exit: String?
    var disposable = false
    /// Its installed apps (plan "One Mac app per app per mini VM").
    var apps: [InstalledApp] = []
    /// Clipboard switches per direction (plan "Clipboard"); an app also needs the `clipboard` permission.
    var pasteIn = true
    var copyOut = true

    var relayPort: Int { 11000 + index }
    var tproxyPort: Int { 12000 + index }
    var tag: String { "vm-\(id)" }
    /// Its colour: icons and the Sandbox window.
    var hue: Double { (Double(index) * 0.618_034).truncatingRemainder(dividingBy: 1) }

    static func new(name: String, exit: String?, taken: [MiniVM]) -> MiniVM? {
        let used = Set(taken.map(\.index))
        guard let index = (1...250).first(where: { !used.contains($0) }) else { return nil }
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        return MiniVM(id: id, name: name, index: index, uuid: UUID().uuidString.lowercased(), exit: exit)
    }
}

extension MiniVM {
    // vms.json from before M3 has no `apps`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                  index: try c.decode(Int.self, forKey: .index), uuid: try c.decode(String.self, forKey: .uuid),
                  exit: try c.decodeIfPresent(String.self, forKey: .exit),
                  disposable: try c.decodeIfPresent(Bool.self, forKey: .disposable) ?? false,
                  apps: try c.decodeIfPresent([InstalledApp].self, forKey: .apps) ?? [],
                  pasteIn: try c.decodeIfPresent(Bool.self, forKey: .pasteIn) ?? true,
                  copyOut: try c.decodeIfPresent(Bool.self, forKey: .copyOut) ?? true)
    }
}

/// The configs the gateway runs (plan §4), built here so they are golden-tested.
enum SandboxConfig {
    /// Host side of one mini VM: its VLESS inbound (fed by the vsock relay) and an authenticated
    /// SOCKS inbound the helper checks the exit through.
    struct Ports: Equatable, Sendable {
        var inbound: Int
        var check: Int
    }

    static let checkUser = "check"

    /// The sandbox core: per mini VM, inbound `vm-<id>` (VLESS, its own UUID) and `check-<id>` both
    /// route to outbound `vm-<id>`, which is the server V2Mac handed out or a blackhole. Unmatched
    /// traffic hits the first outbound, a blackhole.
    static func hostCore(vms: [MiniVM], ports: [String: Ports], outbounds: [String: JSONValue], apiPort: Int, checkPassword: String) -> JSONValue {
        var inbounds: [JSONValue] = [[
            "tag": "api", "listen": "127.0.0.1", "port": .number(Double(apiPort)),
            "protocol": "dokodemo-door", "settings": ["address": "127.0.0.1"],
        ]]
        var outs: [JSONValue] = [["tag": "block", "protocol": "blackhole"]]
        var rules: [JSONValue] = [["inboundTag": ["api"], "outboundTag": "api"]]
        for vm in vms {
            guard let port = ports[vm.id] else { continue }
            inbounds.append([
                "tag": .string(vm.tag), "listen": "127.0.0.1", "port": .number(Double(port.inbound)), "protocol": "vless",
                "settings": ["clients": [["id": .string(vm.uuid)]], "decryption": "none"],
            ])
            inbounds.append([
                "tag": .string("check-\(vm.id)"), "listen": "127.0.0.1", "port": .number(Double(port.check)), "protocol": "socks",
                "settings": ["auth": "password", "accounts": [["user": .string(checkUser), "pass": .string(checkPassword)]], "udp": false],
            ])
            outs.append(exitOutbound(outbounds[vm.id], tag: vm.tag))
            rules.append(["inboundTag": [.string(vm.tag), .string("check-\(vm.id)")], "outboundTag": .string(vm.tag)])
        }
        return [
            "log": ["loglevel": "warning"],
            "api": ["tag": "api", "services": ["HandlerService"]],
            "inbounds": .array(inbounds),
            "outbounds": .array(outs),
            "routing": ["rules": .array(rules)],
        ]
    }

    /// The handed-out server retagged for this mini VM, or a blackhole: no exit means no traffic.
    static func exitOutbound(_ outbound: JSONValue?, tag: String) -> JSONValue {
        (outbound ?? ["protocol": "blackhole"]).setting("tag", to: .string(tag))
    }

    /// Never sent to an exit: other mini VMs, the gateway, the host's networks.
    static let privateRanges: [JSONValue] = [
        "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
        "172.16.0.0/12", "192.168.0.0/16", "224.0.0.0/4", "255.255.255.255/32",
    ]

    /// xray-in-vm (gateway netns): per mini VM a TPROXY inbound → VLESS to its relay; DNS answered
    /// from the fake DNS pool, so the VM never resolves a name itself.
    static func guestXray(vms: [MiniVM]) -> JSONValue {
        var inbounds: [JSONValue] = []
        var outs: [JSONValue] = [["tag": "block", "protocol": "blackhole"], ["tag": "dns-out", "protocol": "dns"]]
        var rules: [JSONValue] = [
            ["port": "53", "network": "udp", "outboundTag": "dns-out"],
            ["ip": .array(privateRanges), "outboundTag": "block"],
        ]
        for vm in vms {
            inbounds.append([
                "tag": .string(vm.tag), "listen": "0.0.0.0", "port": .number(Double(vm.tproxyPort)), "protocol": "dokodemo-door",
                "settings": ["network": "tcp,udp", "followRedirect": true],
                "streamSettings": ["sockopt": ["tproxy": "tproxy"]],
                "sniffing": ["enabled": true, "destOverride": ["fakedns"]],
            ])
            outs.append([
                "tag": .string("host-\(vm.id)"), "protocol": "vless",
                "settings": ["vnext": [["address": "127.0.0.1", "port": .number(Double(vm.relayPort)),
                                        "users": [["id": .string(vm.uuid), "encryption": "none"]]]]],
            ])
            rules.append(["inboundTag": [.string(vm.tag)], "outboundTag": .string("host-\(vm.id)")])
        }
        return [
            "log": ["loglevel": "warning"],
            "dns": ["servers": ["fakedns"]],
            "fakedns": [["ipPool": "198.18.0.0/15", "poolSize": 65535]],
            "inbounds": .array(inbounds),
            "outbounds": .array(outs),
            "routing": ["domainStrategy": "AsIs", "rules": .array(rules)],
        ]
    }

    /// The gateway netns firewall: from a pod's veth only TCP and UDP, all TPROXY'd to that mini
    /// VM's inbound; everything else (ICMP, IPv6, forwarding between pods) is dropped.
    static func gatewayNFT(vms: [MiniVM]) -> String {
        let tproxy = vms.map {
            "    iifname \"vg\($0.index)\" meta nfproto ipv4 meta l4proto { tcp, udp } meta mark set 1 tproxy ip to :\($0.tproxyPort) accept\n"
        }.joined()
        return """
        table inet v2mac
        delete table inet v2mac
        table inet v2mac {
          chain prerouting {
            type filter hook prerouting priority mangle; policy drop;
            iifname "lo" accept
        \(tproxy)  }
          chain input {
            type filter hook input priority filter; policy drop;
            iifname "lo" accept
            meta mark 1 accept
          }
          chain forward {
            type filter hook forward priority filter; policy drop;
          }
        }

        """
    }
}
