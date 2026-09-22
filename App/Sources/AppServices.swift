import Foundation
import LedgerDomain
import LedgerPersistence

enum AppServices {
    static let actorId: UUID = {
        let key = "actorId"
        if let raw = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: raw) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }()

    static let store: LedgerStore = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let store = try! LedgerStore.onDisk(at: dir.appending(path: "ledger.sqlite"), actorId: actorId)
        #if DEBUG
        try! DebugSeed.seedIfEmpty(store)
        #endif
        return store
    }()
}
