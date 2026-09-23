import Foundation

public struct Candidate: Hashable, Sendable, Codable {
    public var name: String
    public var address: String?
    public var phone: String?
    public var latitude: Double
    public var longitude: Double
    public var providerId: String?
    public var category: String?

    public init(name: String, address: String? = nil, phone: String? = nil, latitude: Double, longitude: Double, providerId: String? = nil, category: String? = nil) {
        self.name = name
        self.address = address
        self.phone = phone
        self.latitude = latitude
        self.longitude = longitude
        self.providerId = providerId
        self.category = category
    }
}

public enum PlaceMatching {
    public static func normalizePhone(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        guard digits.hasPrefix("81") else { return digits }
        return "0" + digits.dropFirst(2)
    }

    public static func rank(candidates: [Candidate], hint: PlaceHint?, center: (latitude: Double, longitude: Double)? = nil) -> [Candidate] {
        let hintPhone = hint?.phone.map(normalizePhone)
        let hintBranch = hint?.branch?.trimmingCharacters(in: .whitespaces)

        func phoneMatches(_ candidate: Candidate) -> Bool {
            guard let hintPhone, let phone = candidate.phone else { return false }
            return normalizePhone(phone) == hintPhone
        }
        func branchMatches(_ candidate: Candidate) -> Bool {
            guard let hintBranch, !hintBranch.isEmpty else { return false }
            return candidate.name.contains(hintBranch)
        }
        func distance(_ candidate: Candidate) -> Double {
            guard let center else { return 0 }
            return haversineMeters(center.latitude, center.longitude, candidate.latitude, candidate.longitude)
        }

        let ranked = candidates.sorted { a, b in
            let aPhone = phoneMatches(a), bPhone = phoneMatches(b)
            if aPhone != bPhone { return aPhone }
            let aBranch = branchMatches(a), bBranch = branchMatches(b)
            if aBranch != bBranch { return aBranch }
            return distance(a) < distance(b)
        }
        return Array(ranked.prefix(5))
    }
}

private func haversineMeters(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
    let earthRadius = 6_371_000.0
    let dLat = (lat2 - lat1) * .pi / 180
    let dLon = (lon2 - lon1) * .pi / 180
    let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
    return earthRadius * 2 * atan2(sqrt(a), sqrt(1 - a))
}
