import Foundation
import LedgerDomain
import Testing

@Test func phoneNormalizationTreatsCountryCodeAndDomesticFormAsEqual() {
    #expect(PlaceMatching.normalizePhone("+81 75 229 6955") == "0752296955")
    #expect(PlaceMatching.normalizePhone("075-229-6955") == "0752296955")
    #expect(PlaceMatching.normalizePhone("+81 75 229 6955") == PlaceMatching.normalizePhone("075-229-6955"))
}

@Test func rankPrefersPhoneMatchThenBranchThenDistance() {
    let near = Candidate(name: "五味八珍 熱海駅前店", phone: "0300000000", latitude: 35.0, longitude: 139.0, providerId: "near")
    let phoneMatch = Candidate(name: "ラスカ熱海店", phone: "075-229-6955", latitude: 35.5, longitude: 139.5, providerId: "phone")
    let branchMatch = Candidate(name: "五味八珍 ラスカ熱海店", latitude: 35.1, longitude: 139.1, providerId: "branch")
    let far = Candidate(name: "五味八珍 別の店", latitude: 40.0, longitude: 145.0, providerId: "far")

    let hint = PlaceHint(name: "五味八珍", branch: "ラスカ熱海店", phone: "+81 75 229 6955")
    let ranked = PlaceMatching.rank(candidates: [far, near, branchMatch, phoneMatch], hint: hint, center: (35.0, 139.0))

    #expect(ranked.map(\.providerId) == ["phone", "branch", "near", "far"])
}

@Test func rankKeepsTopFiveByDistanceWhenNoHint() {
    let candidates = (0..<8).map { i in
        Candidate(name: "店\(i)", latitude: 35.0 + Double(i) * 0.1, longitude: 139.0, providerId: "\(i)")
    }
    let ranked = PlaceMatching.rank(candidates: candidates, hint: nil, center: (35.0, 139.0))
    #expect(ranked.count == 5)
    #expect(ranked.map(\.providerId) == ["0", "1", "2", "3", "4"])
}

@Test func resolvedPlaceDefaultsToAutoWhenNoExplicitChoice() {
    let auto = Candidate(name: "五味八珍", latitude: 35.0, longitude: 139.0)
    #expect(PlaceMatching.resolvedPlace(explicit: nil, auto: auto) == auto)
    #expect(PlaceMatching.resolvedPlace(explicit: nil, auto: nil) == nil)
}

@Test func resolvedPlacePrefersExplicitCandidateOverAuto() {
    let auto = Candidate(name: "五味八珍", latitude: 35.0, longitude: 139.0)
    let picked = Candidate(name: "ラスカ熱海店", latitude: 35.5, longitude: 139.5)
    #expect(PlaceMatching.resolvedPlace(explicit: .candidate(picked), auto: auto) == picked)
}

@Test func resolvedPlaceDeclineNeverFallsBackToAuto() {
    let auto = Candidate(name: "五味八珍", latitude: 35.0, longitude: 139.0)
    #expect(PlaceMatching.resolvedPlace(explicit: .declined, auto: auto) == nil)
}
