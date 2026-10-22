import Foundation
import V2MacCore

/// `/run/v2mac/exit.json` for every app (plan §6): where its mini VM's exit is, so apps can match
/// language, time zone and location to it. Country point and time zone come offline from zone.tab;
/// a zone whose city matches the exit's city wins over the country's first one.
struct ExitFacts: Codable, Equatable {
    var ip: String
    var country: String?
    var city: String?
    var latitude: Double?
    var longitude: Double?
    var timezone: String?

    init(_ info: ExitInfo, zoneTab: String) {
        ip = info.ip
        country = info.countryCode
        city = info.city
        guard let code = info.countryCode?.uppercased() else { return }
        let zones = zoneTab.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let f = line.split(separator: "\t")
            return f.count >= 3 && f[0] == code ? String(f[2]) : nil
        }
        let wanted = info.city?.lowercased().replacingOccurrences(of: " ", with: "_")
        timezone = zones.first { zone in wanted.map { zone.lowercased().hasSuffix("/" + $0) } ?? false } ?? zones.first
        if let point = CountryPlaces.read(zoneTab)[code] {
            latitude = point.latitude
            longitude = point.longitude
        }
    }

    static let zoneTab = (try? String(contentsOf: CountryPlaces.systemFile, encoding: .utf8)) ?? ""

    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
