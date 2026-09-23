import LedgerDomain
import LedgerPersistence
import MapKit
import SwiftUI

struct ExpensePlaceSection: View {
    var expenseId: UUID
    var ledgerId: UUID
    var occurredAt: Date
    var place: Place?
    var placeQuery: String?
    var onOpenMap: (UUID) -> Void

    @State private var searchRequest: PlaceSearchRequest?
    @State private var nameInput = ""
    @State private var showNameAlert = false

    var body: some View {
        Section("地点") {
            if let place {
                Button {
                    onOpenMap(place.id)
                } label: {
                    PlaceSummary(place: place)
                }
                .buttonStyle(.plain)
                Button("更换地点") {
                    nameInput = place.name
                    showNameAlert = true
                }
                Button("移除地点", role: .destructive) { removePlace() }
            } else if let hint = decodedHint {
                Button("重新搜索") { searchRequest = .hint(hint) }
            } else {
                Button("添加地点") {
                    nameInput = ""
                    showNameAlert = true
                }
            }
        }
        .alert("地点名称", isPresented: $showNameAlert) {
            TextField("店名", text: $nameInput)
            Button("搜索") {
                let trimmed = nameInput.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                searchRequest = .name(trimmed)
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(item: $searchRequest) { request in
            PlaceResultsSheet(
                search: { await PlaceSearch.search(hint: request.hint, ledgerId: ledgerId, occurredAt: occurredAt) },
                onSelect: setPlace
            )
        }
    }

    private var decodedHint: PlaceHint? {
        guard let placeQuery, let data = placeQuery.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PlaceHint.self, from: data)
    }

    private func setPlace(_ candidate: Candidate) {
        try? AppServices.store.setExpensePlace(expenseId: expenseId, candidate: candidate)
    }

    private func removePlace() {
        try? AppServices.store.setExpensePlace(expenseId: expenseId, candidate: nil)
    }
}

private enum PlaceSearchRequest: Identifiable {
    case hint(PlaceHint)
    case name(String)

    var id: String {
        switch self {
        case .hint(let hint): "hint-\(hint.name)-\(hint.branch ?? "")-\(hint.address ?? "")"
        case .name(let name): "name-\(name)"
        }
    }

    var hint: PlaceHint {
        switch self {
        case .hint(let hint): hint
        case .name(let name): PlaceHint(name: name)
        }
    }
}

private struct PlaceSummary: View {
    var place: Place

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PlaceSnapshotView(place: place)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                if let address = place.address, !address.isEmpty {
                    Text(address)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var title: String {
        if let branch = place.branch, !branch.isEmpty { return "\(place.name) \(branch)" }
        return place.name
    }
}

private struct PlaceResultsSheet: View {
    var search: () async -> [Candidate]
    var onSelect: (Candidate) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .searching

    private enum Phase {
        case searching
        case empty
        case results([Candidate])
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .searching:
                    ProgressView("搜索中…")
                case .empty:
                    ContentUnavailableView("没有找到地点", systemImage: "mappin.slash")
                case .results(let candidates):
                    List(candidates, id: \.self) { candidate in
                        Button {
                            onSelect(candidate)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.name)
                                if let address = candidate.address {
                                    Text(address)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("搜索地点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .task {
                let results = await search()
                phase = results.isEmpty ? .empty : .results(results)
            }
        }
    }
}

private struct PlaceSnapshotView: View {
    var place: Place

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(Color(.secondarySystemBackground))
                ProgressView()
            }
        }
        .frame(height: 140)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: place.id) { await loadSnapshot() }
    }

    private func loadSnapshot() async {
        if let cached = PlaceSnapshotCache.shared.image(for: place.id) {
            image = cached
            return
        }
        let coordinate = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 400, longitudinalMeters: 400)
        options.size = CGSize(width: 360, height: 280)
        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return }
        let rendered = Self.render(snapshot: snapshot, coordinate: coordinate)
        PlaceSnapshotCache.shared.store(rendered, for: place.id)
        image = rendered
    }

    private static func render(snapshot: MKMapSnapshotter.Snapshot, coordinate: CLLocationCoordinate2D) -> UIImage {
        UIGraphicsImageRenderer(size: snapshot.image.size).image { _ in
            snapshot.image.draw(at: .zero)
            let point = snapshot.point(for: coordinate)
            let pin = UIImage(systemName: "mappin.circle.fill")?.withTintColor(.systemRed, renderingMode: .alwaysOriginal)
            pin?.draw(at: CGPoint(x: point.x - 12, y: point.y - 24))
        }
    }
}

@MainActor
private final class PlaceSnapshotCache {
    static let shared = PlaceSnapshotCache()
    private var images: [UUID: UIImage] = [:]

    func image(for placeId: UUID) -> UIImage? { images[placeId] }
    func store(_ image: UIImage, for placeId: UUID) { images[placeId] = image }
}
