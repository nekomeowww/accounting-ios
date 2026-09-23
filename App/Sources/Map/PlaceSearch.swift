import Foundation
import GRDB
import LedgerDomain
import LedgerPersistence
import MapKit
import os

enum PlaceSearch {
    private static let logger = Logger(subsystem: "dev.innei.Accounting", category: "PlaceSearch")

    static func search(hint: PlaceHint, ledgerId: UUID, occurredAt: Date) async -> [Candidate] {
        let query = hint.address?.isEmpty == false ? hint.address! : [hint.name, hint.branch, hint.area].compactMap { $0 }.joined(separator: " ")
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        let region = biasRegion(ledgerId: ledgerId, occurredAt: occurredAt)

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]
        if let region {
            request.region = region
            request.regionPriority = .default
        }
        logger.debug("search query=\(query, privacy: .public) region=\(region.map { "\($0.center.latitude),\($0.center.longitude) span=\($0.span.latitudeDelta)x\($0.span.longitudeDelta)" } ?? "none", privacy: .public)")

        do {
            let response = try await MKLocalSearch(request: request).start()
            let candidates = response.mapItems.compactMap(makeCandidate)
            let center = region.map { (latitude: $0.center.latitude, longitude: $0.center.longitude) }
            let ranked = PlaceMatching.rank(candidates: candidates, hint: hint, center: center)
            logger.debug("search query=\(query, privacy: .public) mapItems=\(response.mapItems.count) ranked=\(ranked.count)")
            return ranked
        } catch let error as MKError where error.code == .placemarkNotFound {
            logger.info("search no results query=\(query, privacy: .public) error=\(error as NSError, privacy: .public)")
            return []
        } catch {
            logger.error("search failed query=\(query, privacy: .public) error=\(error as NSError, privacy: .public)")
            return []
        }
    }

    private static func biasRegion(ledgerId: UUID, occurredAt: Date) -> MKCoordinateRegion? {
        try? AppServices.store.writer.read { db -> MKCoordinateRegion? in
            let dayStart = Calendar.current.startOfDay(for: occurredAt)
            let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? occurredAt
            let sameDay = try Place.fetchAll(db, sql: """
                    SELECT DISTINCT p.* FROM place p
                    JOIN expense e ON e.placeId = p.id AND e.deletedAt IS NULL
                    WHERE p.ledgerId = ? AND e.occurredAt >= ? AND e.occurredAt < ?
                    """, arguments: [ledgerId.uuidString, dayStart, dayEnd])
            if let region = region(for: sameDay) { return region }

            let lodging = try LedgerStore.fetchLodgingPlaces(db, ledgerId: ledgerId).map(\.place)
            if let region = region(for: lodging) { return region }

            return try region(for: LedgerStore.fetchPlaces(db, ledgerId: ledgerId))
        }
    }

    private static func region(for places: [Place]) -> MKCoordinateRegion? {
        guard !places.isEmpty else { return nil }
        let lats = places.map(\.latitude)
        let lons = places.map(\.longitude)
        let center = CLLocationCoordinate2D(
            latitude: (lats.min()! + lats.max()!) / 2,
            longitude: (lons.min()! + lons.max()!) / 2
        )
        let minSpan = 0.05
        let span = MKCoordinateSpan(
            latitudeDelta: max(lats.max()! - lats.min()!, minSpan) * 1.5,
            longitudeDelta: max(lons.max()! - lons.min()!, minSpan) * 1.5
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    private static func makeCandidate(_ item: MKMapItem) -> Candidate? {
        guard let name = item.name, !name.isEmpty else { return nil }
        let coordinate = item.location.coordinate
        return Candidate(
            name: name,
            address: item.address?.fullAddress,
            phone: item.phoneNumber,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            providerId: item.identifier?.rawValue,
            category: item.pointOfInterestCategory.flatMap(categoryLabel)
        )
    }

    private static func categoryLabel(_ category: MKPointOfInterestCategory) -> String? {
        switch category {
        case .restaurant, .foodMarket: "餐饮"
        case .cafe, .bakery, .brewery, .winery: "餐饮"
        case .hotel, .campground: "住宿"
        case .airport, .publicTransport, .parking, .gasStation, .carRental: "交通"
        case .store: "购物"
        case .museum, .aquarium, .amusementPark, .zoo, .theater, .movieTheater: "门票"
        default: nil
        }
    }
}
