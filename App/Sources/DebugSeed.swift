#if DEBUG
import Foundation
import GRDB
import LedgerDomain
import LedgerPersistence

enum DebugSeed {
    private static let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    private static func date(_ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tokyo
        return calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    static func reset(_ store: LedgerStore) throws {
        try store.writer.write { db in
            for table in ["message", "conversation", "exchangeRate", "journalEntry", "journalTx", "lineConsumer", "expensePayment", "expenseLine", "expense", "transfer", "member", "participant", "ledger"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }
        try seedIfEmpty(store)
    }

    static func counts(_ store: LedgerStore) throws -> [(String, Int)] {
        try store.writer.read { db in
            try ["ledger", "participant", "expense", "journalEntry", "exchangeRate", "message"].map { table in
                (table, try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0)
            }
        }
    }

    static func seedIfEmpty(_ store: LedgerStore) throws {
        let hasLedger = try store.writer.read { try Ledger.fetchCount($0) > 0 }
        guard !hasLedger else { return }
        let (ledger, innei) = try store.createLedger(name: "日本旅行 2026.09", currency: "JPY", settlementCurrency: "CNY", myName: "innei")
        let whitewater = try store.addParticipant(ledgerId: ledger.id, name: "whitewater")
        let neko = try store.addParticipant(ledgerId: ledger.id, name: "neko")
        let rizumu = try store.addParticipant(ledgerId: ledger.id, name: "rizumu")
        let four = [whitewater, innei, neko, rizumu].map { ConsumerDraft($0.id) }
        let two = [whitewater, innei].map { ConsumerDraft($0.id) }

        struct Row {
            var date: Date
            var merchant: String
            var payer: Participant
            var amount: Int64
            var currency: String
            var consumers: [ConsumerDraft]
            var note: String? = nil
            var method: String? = nil
            var category: String? = nil
        }

        let shared: [Row] = [
            Row(date: date(9, 15), merchant: "Airbnb 东京·墨田区 3晚", payer: whitewater, amount: 34697, currency: "USD", consumers: four, note: "确认码 HMTDPDW5BA", category: "住宿"),
            Row(date: date(9, 18), merchant: "TOYOTA 租车 热海站店 3天", payer: whitewater, amount: 37950, currency: "JPY", consumers: four, note: "予約番号 99922445400", category: "交通"),
            Row(date: date(9, 21), merchant: "Airbnb 京都·下京区 3晚", payer: whitewater, amount: 71046, currency: "USD", consumers: four, note: "确认码 HMZRCTZBDT", category: "住宿"),
            Row(date: date(9, 15, 8), merchant: "机票 去程", payer: innei, amount: 269800, currency: "CNY", consumers: two, note: "仅 innei+白水 2 人分", category: "交通"),
            Row(date: date(9, 24, 18), merchant: "机票 回程", payer: innei, amount: 187600, currency: "CNY", consumers: two, note: "仅 innei+白水 2 人分", category: "交通"),
            Row(date: date(9, 18), merchant: "Airbnb 伊东设计师公寓 301 2晚", payer: whitewater, amount: 52523, currency: "USD", consumers: four, note: "确认码 HMNETDRJZ8", category: "住宿"),
            Row(date: date(9, 20), merchant: "石花海別邸 海うさぎ 1晚", payer: whitewater, amount: 86603, currency: "USD", consumers: four, note: "1 间双床房", category: "住宿"),
            Row(date: date(9, 19, 19), merchant: "晚餐 吃鱼", payer: innei, amount: 5460, currency: "JPY", consumers: two, note: "仅 innei+白水 2 人分", category: "餐饮"),
            Row(date: date(9, 20, 14), merchant: "伊豆高原 猫咪博物馆", payer: innei, amount: 5600, currency: "JPY", consumers: four, note: "4人门票", category: "门票"),
            Row(date: date(9, 20, 19), merchant: "晚餐 拉面居酒屋", payer: neko, amount: 5200, currency: "JPY", consumers: four, category: "餐饮"),
            Row(date: date(9, 21, 10), merchant: "热海布丁", payer: innei, amount: 1800, currency: "JPY", consumers: four, note: "特制焦糖布丁 4个，现金支付找零¥500", method: "cash", category: "餐饮"),
            Row(date: date(9, 18, 20, 4), merchant: "五味八珍 ラスカ热海店", payer: whitewater, amount: 3135, currency: "JPY", consumers: two, note: "热海站前 ラスカ热海，白水垫付", category: "餐饮"),
            Row(date: date(9, 21, 19), merchant: "麺屋 猪一", payer: whitewater, amount: 9700, currency: "JPY", consumers: four, note: "京都・四条", category: "餐饮"),
            Row(date: date(9, 22, 12), merchant: "新潟カツ丼タレカツ 京都本店", payer: innei, amount: 1950, currency: "JPY", consumers: two, note: "猪排饭，与白水 2人分", category: "餐饮"),
            Row(date: date(9, 21, 12, 43), merchant: "新干线 热海→京都", payer: neko, amount: 49960, currency: "JPY", consumers: four, note: "こだま823 熱海12:43発 + のぞみ259 名古屋14:41発", category: "交通"),
            Row(date: date(9, 17, 15), merchant: "teamLab Planets TOKYO", payer: neko, amount: 18400, currency: "JPY", consumers: four, note: "neko 信用卡垫付", method: "card", category: "门票"),
        ]

        let mine = [ConsumerDraft(innei.id)]
        let personal: [Row] = [
            Row(date: date(9, 19, 9), merchant: "Lawson", payer: innei, amount: 1204, currency: "JPY", consumers: mine, category: "便利店"),
            Row(date: date(9, 20, 12), merchant: "KFC 伊东Duo店", payer: innei, amount: 1190, currency: "JPY", consumers: mine, note: "一人食午餐", category: "餐饮"),
            Row(date: date(9, 20, 16), merchant: "7-Eleven 伊豆白田店", payer: innei, amount: 338, currency: "JPY", consumers: mine, category: "便利店"),
            Row(date: date(9, 21, 11), merchant: "麦当劳 热海站前店", payer: innei, amount: 1110, currency: "JPY", consumers: mine, note: "月见汉堡套餐+炸虾块", category: "餐饮"),
            Row(date: date(9, 22, 14), merchant: "京都 IP書店", payer: innei, amount: 2090, currency: "JPY", consumers: mine, note: "サンリオ和ごころ 990 + しぐれうい御守り風アクリル 1,100", category: "购物"),
            Row(date: date(9, 22, 15), merchant: "高島屋 京都", payer: innei, amount: 1804, currency: "JPY", consumers: mine, note: "カードラッピング 500+520 + クリスマスカード 620", category: "购物"),
            Row(date: date(9, 22, 12, 30), merchant: "麺や 鳥の鶏次 KYOTO 四条河原町店", payer: innei, amount: 1360, currency: "JPY", consumers: mine, note: "鶏白湯ラーメン 午餐", category: "餐饮"),
            Row(date: date(9, 22, 16), merchant: "マツモトキヨシ 京都四条河原町店", payer: innei, amount: 1389, currency: "JPY", consumers: mine, note: "オフテクス ティアージェW 657 + ソフトサンティア 627 + キレートレモン 105", category: "药妆"),
            Row(date: date(9, 22, 17), merchant: "京都まるん 祇園店", payer: innei, amount: 660, currency: "JPY", consumers: mine, note: "ピンズ 1点，含税10%", category: "购物"),
            Row(date: date(9, 22, 17, 30), merchant: "なわーど ラッシュ", payer: innei, amount: 540, currency: "JPY", consumers: mine, note: "レモン風味（果汁1%・ガラス瓶）", category: "饮料"),
            Row(date: date(9, 22, 18), merchant: "ごちそう焼むすび おにまる 京都四条河原町店", payer: innei, amount: 1703, currency: "CNY", consumers: mine, note: "焼むすび，支付宝实付，原价 ¥399", method: "alipay", category: "餐饮"),
            Row(date: date(9, 22, 18, 30), merchant: "Sanrio Gallery 京都店", payer: innei, amount: 1100, currency: "JPY", consumers: mine, note: "サンリオ グッズ，含税10%", category: "购物"),
        ]

        for row in shared + personal {
            try store.createExpense(ExpenseDraft(
                ledgerId: ledger.id, merchant: row.merchant, note: row.note, category: row.category,
                occurredAt: row.date, timeZone: tokyo.identifier, currency: row.currency,
                lines: [LineDraft(name: row.merchant, amountMinor: row.amount, consumers: row.consumers)],
                payments: [PaymentDraft(row.payer.id, amountMinor: row.amount, method: row.method)]
            ))
        }
        try store.setRates(ledgerId: ledger.id, ["USD": Decimal(string: "6.71")!, "JPY": Decimal(string: "0.043")!], source: .manual)
    }
}
#endif
