import LedgerDomain
import SwiftUI

struct LedgerListView: View {
    var ledgers: [Ledger]
    var onSelect: (Ledger) -> Void

    var body: some View {
        if ledgers.isEmpty {
            ContentUnavailableView("还没有账本", systemImage: "book.closed")
        } else {
            List(ledgers) { ledger in
                Button { onSelect(ledger) } label: {
                    LabeledContent(ledger.name, value: ledger.defaultCurrency)
                }
                .tint(.primary)
            }
        }
    }
}
