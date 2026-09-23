import GRDB
import LedgerDomain
import LedgerPersistence
import MapKit
import SwiftUI
import UIKit

final class MapPinAnnotation: NSObject, MKAnnotation {
    let pin: LedgerPersistence.MapPin

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: pin.place.latitude, longitude: pin.place.longitude)
    }

    var title: String? { MapPinAnnotation.amountLabel(for: pin) }
    var subtitle: String? { pin.place.name }

    init(pin: LedgerPersistence.MapPin) {
        self.pin = pin
    }

    static func amountLabel(for pin: LedgerPersistence.MapPin) -> String {
        if let total = pin.total { return total.formatted }
        let currencies = Set(pin.expenses.map(\.currency))
        guard let currency = currencies.count == 1 ? currencies.first : nil else {
            return pin.expenses.first.map { Money(minor: $0.totalMinor, currency: $0.currency).formatted } ?? ""
        }
        return Money(minor: pin.expenses.reduce(0) { $0 + $1.totalMinor }, currency: currency).formatted
    }
}

final class LedgerMapViewController: UIViewController {
    var onPreviewVisibilityChanged: ((Bool) -> Void)?
    var onOpenExpense: ((UUID) -> Void)?
    private(set) var isPreviewVisible = false

    private let ledgerId: UUID
    private let mapView = MKMapView()
    private let emptyLabel = UILabel()
    private var previewHost: UIHostingController<MapPreviewCard>?
    private var pinsById: [UUID: LedgerPersistence.MapPin] = [:]
    private var selectedPinId: UUID?
    private var observation: AnyDatabaseCancellable?
    private var settlementCurrency: String?
    private var rates: [String: Decimal] = [:]
    private var didFitInitialPins = false

    init(ledgerId: UUID) {
        self.ledgerId = ledgerId
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureMapView()
        configureEmptyLabel()
        loadRates()
        observe()
    }

    private func configureMapView() {
        mapView.translatesAutoresizingMaskIntoConstraints = false
        mapView.delegate = self
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleMapTap))
        tap.cancelsTouchesInView = false
        mapView.addGestureRecognizer(tap)
        view.addSubview(mapView)
        NSLayoutConstraint.activate([
            mapView.topAnchor.constraint(equalTo: view.topAnchor),
            mapView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mapView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureEmptyLabel() {
        emptyLabel.text = "还没有带地点的消费。记账时说出店名或分店，Agent 会帮你找到位置。"
        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.font = .preferredFont(forTextStyle: .subheadline)
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 32),
            emptyLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -32),
        ])
    }

    private func loadRates() {
        let store = AppServices.store
        try? store.writer.read { db in
            settlementCurrency = try Ledger.fetchOne(db, key: ledgerId.uuidString)?.settlementCurrency
            rates = Dictionary(uniqueKeysWithValues: try LedgerStore.fetchRates(db, ledgerId: ledgerId).map { ($0.currency, $0.rate) })
        }
    }

    private func observe() {
        let store = AppServices.store
        observation = store.observeMapPins(ledgerId: ledgerId).start(in: store.writer, scheduling: .immediate, onError: { _ in }) { [weak self] pins in
            self?.apply(pins)
        }
    }

    private func apply(_ pins: [LedgerPersistence.MapPin]) {
        pinsById = Dictionary(uniqueKeysWithValues: pins.map { ($0.id, $0) })
        emptyLabel.isHidden = !pins.isEmpty

        let existing = mapView.annotations.compactMap { $0 as? MapPinAnnotation }
        mapView.removeAnnotations(existing)
        mapView.addAnnotations(pins.map(MapPinAnnotation.init))

        if !didFitInitialPins, !pins.isEmpty {
            didFitInitialPins = true
            fit(pins)
        }

        if let selectedPinId, let pin = pinsById[selectedPinId] {
            showPreview(for: pin)
        } else if selectedPinId != nil {
            hidePreview()
        }
    }

    private func fit(_ pins: [LedgerPersistence.MapPin]) {
        if pins.count == 1, let pin = pins.first {
            let region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: pin.place.latitude, longitude: pin.place.longitude),
                latitudinalMeters: 500, longitudinalMeters: 500
            )
            mapView.setRegion(region, animated: false)
        } else {
            mapView.showAnnotations(mapView.annotations, animated: false)
        }
    }

    @objc private func handleMapTap(_ gesture: UITapGestureRecognizer) {
        for annotation in mapView.selectedAnnotations {
            mapView.deselectAnnotation(annotation, animated: true)
        }
    }

    private func showPreview(for pin: LedgerPersistence.MapPin) {
        let card = MapPreviewCard(pin: pin, settlementCurrency: settlementCurrency, rates: rates) { [weak self] expenseId in
            self?.onOpenExpense?(expenseId)
        }
        if let previewHost {
            previewHost.rootView = card
        } else {
            let host = UIHostingController(rootView: card)
            host.view.backgroundColor = .clear
            addChild(host)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                host.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            ])
            host.didMove(toParent: self)
            previewHost = host
        }
        isPreviewVisible = true
        onPreviewVisibilityChanged?(true)
    }

    private func hidePreview() {
        guard let previewHost else { return }
        previewHost.willMove(toParent: nil)
        previewHost.view.removeFromSuperview()
        previewHost.removeFromParent()
        self.previewHost = nil
        isPreviewVisible = false
        onPreviewVisibilityChanged?(false)
    }
}

extension LedgerMapViewController: MKMapViewDelegate {
    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        if let cluster = annotation as? MKClusterAnnotation {
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "cluster") as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: cluster, reuseIdentifier: "cluster")
            view.annotation = cluster
            view.markerTintColor = .systemGray
            view.canShowCallout = false
            return view
        }
        guard let pinAnnotation = annotation as? MapPinAnnotation else { return nil }
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: "pin") as? MKMarkerAnnotationView
            ?? MKMarkerAnnotationView(annotation: pinAnnotation, reuseIdentifier: "pin")
        view.annotation = pinAnnotation
        view.canShowCallout = false
        view.clusteringIdentifier = "place"
        view.markerTintColor = CategoryStyle.color(for: pinAnnotation.pin.dominantCategory)
        view.glyphImage = UIImage(systemName: CategoryStyle.symbol(for: pinAnnotation.pin.dominantCategory))
        view.glyphText = pinAnnotation.pin.expenseCount > 1 ? "\(pinAnnotation.pin.expenseCount)" : nil
        return view
    }

    func mapView(_ mapView: MKMapView, clusterAnnotationForMemberAnnotations memberAnnotations: [MKAnnotation]) -> MKClusterAnnotation {
        let cluster = MKClusterAnnotation(memberAnnotations: memberAnnotations)
        let pins = memberAnnotations.compactMap { ($0 as? MapPinAnnotation)?.pin }
        let totals = pins.compactMap(\.total)
        if totals.count == pins.count, let currency = totals.first?.currency, totals.allSatisfy({ $0.currency == currency }) {
            cluster.title = Money(minor: totals.reduce(0) { $0 + $1.minor }, currency: currency).formatted
        } else {
            cluster.title = "\(pins.count) 个地点"
        }
        return cluster
    }

    func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
        guard let pinAnnotation = annotation as? MapPinAnnotation else { return }
        selectedPinId = pinAnnotation.pin.id
        showPreview(for: pinAnnotation.pin)
    }

    func mapView(_ mapView: MKMapView, didDeselect annotation: MKAnnotation) {
        guard annotation is MapPinAnnotation else { return }
        selectedPinId = nil
        hidePreview()
    }
}
