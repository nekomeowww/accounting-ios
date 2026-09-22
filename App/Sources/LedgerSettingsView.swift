import GRDB
import LedgerDomain
import LedgerPersistence
import SwiftUI
import UIKit

@MainActor @Observable
final class LedgerSettingsModel {
    struct Snapshot: Equatable {
        var ledger: Ledger?
        var rates: [ExchangeRate] = []
        var inUse: [String] = []
    }

    let ledgerId: UUID
    private(set) var snapshot = Snapshot()
    private(set) var fetching = false
    var message: String?
    @ObservationIgnored private var observation: AnyDatabaseCancellable?

    init(ledgerId: UUID) {
        self.ledgerId = ledgerId
        let store = AppServices.store
        observation = ValueObservation.tracking { db in
            Snapshot(
                ledger: try Ledger.fetchOne(db, key: ledgerId.uuidString),
                rates: try LedgerStore.fetchRates(db, ledgerId: ledgerId),
                inUse: try LedgerStore.fetchCurrenciesInUse(db, ledgerId: ledgerId)
            )
        }.start(in: store.writer, scheduling: .immediate, onError: { _ in }) { [weak self] in self?.snapshot = $0 }
    }

    var settlement: String { snapshot.ledger?.settlementCurrency ?? "" }

    var foreignCurrencies: [String] {
        Set(snapshot.inUse + snapshot.rates.map(\.currency)).subtracting([settlement]).sorted()
    }

    var settlementOptions: [String] {
        Set(snapshot.inUse + [settlement, "CNY", "USD", "JPY", "HKD", "EUR"]).sorted()
    }

    func rate(for currency: String) -> ExchangeRate? {
        snapshot.rates.first { $0.currency == currency }
    }

    func setSettlement(_ currency: String) {
        guard currency != settlement else { return }
        try? AppServices.store.setSettlementCurrency(ledgerId: ledgerId, currency: currency)
        message = nil
    }

    func setManualRate(_ currency: String, _ rate: Decimal?) {
        guard let rate, rate > 0, rate != self.rate(for: currency)?.rate else { return }
        try? AppServices.store.setRates(ledgerId: ledgerId, [currency: rate], source: .manual)
    }

    func fetchRates() async {
        let wanted = foreignCurrencies
        guard !wanted.isEmpty else { return }
        fetching = true
        defer { fetching = false }
        do {
            let result = try await ExchangeRateFetcher.fetch(settlement: settlement, currencies: wanted)
            try AppServices.store.setRates(ledgerId: ledgerId, result.rates, source: .fetched, asOf: result.asOf)
            let skipped = wanted.filter { result.rates[$0] == nil }
            message = skipped.isEmpty ? nil : "数据源不支持 \(skipped.joined(separator: "、"))，请手动填写"
        } catch {
            message = error.localizedDescription
        }
    }
}

struct LedgerSettingsView: View {
    @State var model: LedgerSettingsModel

    var body: some View {
        Form {
            Section {
                Picker("结算币种", selection: Binding(get: { model.settlement }, set: { model.setSettlement($0) })) {
                    ForEach(model.settlementOptions, id: \.self) { Text($0).tag($0) }
                }
            } footer: {
                Text("余额统一折算成结算币种。切换后原有汇率会清空。")
            }
            Section {
                ForEach(model.foreignCurrencies, id: \.self) { currency in
                    RateRow(currency: currency, settlement: model.settlement, rate: model.rate(for: currency)) {
                        model.setManualRate(currency, $0)
                    }
                }
                Button {
                    Task { await model.fetchRates() }
                } label: {
                    HStack {
                        Text("更新汇率")
                        if model.fetching {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(model.fetching || model.foreignCurrencies.isEmpty)
            } header: {
                Text("汇率")
            } footer: {
                Text(model.message ?? "汇率不会自动更新。点「更新汇率」从欧洲央行数据拉取一次，之后仍可手改。")
            }
        }
    }
}

private struct RateRow: View {
    var currency: String
    var settlement: String
    var rate: ExchangeRate?
    var onCommit: (Decimal?) -> Void
    @State private var value: Decimal?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("1 \(currency) =")
                TextField("未设置", value: $value, format: .number.precision(.fractionLength(0...8)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                Text(settlement)
                    .foregroundStyle(.secondary)
            }
            Text(sourceLabel)
                .font(.caption)
                .foregroundStyle(rate == nil ? .orange : .secondary)
        }
        .onAppear { value = rate?.rate }
        .onChange(of: rate?.rate) { _, new in value = new }
        .onChange(of: value) { _, new in onCommit(new) }
    }

    private var sourceLabel: String {
        guard let rate else { return "缺少汇率，余额暂不计入该币种" }
        switch rate.source {
        case .fetched: return "欧洲央行 · \(rate.asOf ?? "")"
        case .manual: return "手动"
        }
    }
}

final class LedgerSettingsViewController: UIHostingController<LedgerSettingsView> {
    init(ledgerId: UUID) {
        super.init(rootView: LedgerSettingsView(model: LedgerSettingsModel(ledgerId: ledgerId)))
        title = "账本设置"
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}
