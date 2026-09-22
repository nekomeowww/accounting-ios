import GRDB
import LedgerDomain

extension Ledger: FetchableRecord, PersistableRecord {
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy { .uppercaseString }
}

extension Participant: FetchableRecord, PersistableRecord {
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy { .uppercaseString }
}

extension Member: FetchableRecord, PersistableRecord {
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy { .uppercaseString }
}

extension Expense: FetchableRecord, PersistableRecord {
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy { .uppercaseString }
}

extension ExpenseLine: FetchableRecord, PersistableRecord {
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy { .uppercaseString }
}

extension LineConsumer: FetchableRecord, PersistableRecord {
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy { .uppercaseString }
}

extension ExpensePayment: FetchableRecord, PersistableRecord {
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy { .uppercaseString }
}

extension Transfer: FetchableRecord, PersistableRecord {
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy { .uppercaseString }
}

extension JournalTx: FetchableRecord, PersistableRecord {
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy { .uppercaseString }
}

extension JournalEntry: FetchableRecord, PersistableRecord {
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy { .uppercaseString }
}
