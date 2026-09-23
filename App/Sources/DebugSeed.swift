#if DEBUG
import Foundation
import GRDB
import LedgerDomain
import LedgerPersistence

private func seedPlace(_ providerId: String, _ name: String, _ lat: Double, _ lon: Double, address: String? = nil, phone: String? = nil, category: String? = nil) -> Candidate {
    Candidate(name: name, address: address, phone: phone, latitude: lat, longitude: lon, providerId: "seed-\(providerId)", category: category)
}

enum DebugSeed {
    private static let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    private static func date(_ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tokyo
        return calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    static func reset(_ store: LedgerStore) throws {
        try store.writer.write { db in
            for table in ["message", "conversation", "exchangeRate", "journalEntry", "journalTx", "lineConsumer", "expensePayment", "expenseLine", "expense", "place", "transfer", "member", "participant", "ledger"] {
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
            var endsAt: Date? = nil
            var merchant: String
            var payer: Participant
            var amount: Int64
            var currency: String
            var consumers: [ConsumerDraft]
            var note: String? = nil
            var original: Money? = nil
            var method: String? = nil
            var category: String? = nil
            var place: Candidate? = nil
            var lines: [LineDraft]? = nil
        }

        let shared: [Row] = [
            Row(date: date(9, 15, 15), endsAt: date(9, 18, 10), merchant: "Airbnb 东京·墨田区 3晚", payer: whitewater, amount: 34697, currency: "USD", consumers: four, note: "确认码 HMTDPDW5BA", category: "住宿", place: seedPlace("airbnb-tokyo", "Airbnb 东京·墨田区", 35.7101, 139.8107, category: "住宿")),
            Row(date: date(9, 18), endsAt: date(9, 21), merchant: "TOYOTA 租车 热海站店 3天", payer: whitewater, amount: 37950, currency: "JPY", consumers: four, note: "予約番号 99922445400", category: "交通", place: seedPlace("toyota-atami", "TOYOTA レンタカー 熱海駅前店", 35.1036, 139.0775, category: "交通")),
            Row(date: date(9, 21, 15), endsAt: date(9, 24, 10), merchant: "Airbnb 京都·下京区 3晚", payer: whitewater, amount: 71046, currency: "USD", consumers: four, note: "确认码 HMZRCTZBDT", category: "住宿", place: seedPlace("airbnb-kyoto", "Airbnb 京都·下京区", 34.9968, 135.7590, category: "住宿")),
            Row(date: date(9, 15, 8), merchant: "机票 去程", payer: innei, amount: 269800, currency: "CNY", consumers: two, note: "仅 innei+白水 2 人分", category: "交通"),
            Row(date: date(9, 24, 18), merchant: "机票 回程", payer: innei, amount: 187600, currency: "CNY", consumers: two, note: "仅 innei+白水 2 人分", category: "交通"),
            Row(date: date(9, 18, 15), endsAt: date(9, 20, 10), merchant: "Airbnb 伊东设计师公寓 301 2晚", payer: whitewater, amount: 52523, currency: "USD", consumers: four, note: "确认码 HMNETDRJZ8", category: "住宿", place: seedPlace("airbnb-ito", "Airbnb 伊东设计师公寓 301", 34.9659, 139.1019, category: "住宿")),
            Row(date: date(9, 20, 15), endsAt: date(9, 21, 10), merchant: "石花海別邸 海うさぎ 1晚", payer: whitewater, amount: 86603, currency: "USD", consumers: four, note: "1 间双床房", category: "住宿", place: seedPlace("sekkaiso", "石花海別邸 海うさぎ", 34.9143, 139.1340, category: "住宿")),
            Row(date: date(9, 19, 19), merchant: "晚餐 吃鱼", payer: innei, amount: 5460, currency: "JPY", consumers: two, note: "仅 innei+白水 2 人分", category: "餐饮"),
            Row(date: date(9, 20, 14), merchant: "伊豆高原 猫咪博物馆", payer: innei, amount: 5600, currency: "JPY", consumers: four, note: "4人门票", category: "门票", place: seedPlace("izu-cat-museum", "伊豆高原 猫の博物館", 34.8980, 139.1287, category: "门票")),
            Row(date: date(9, 20, 19), merchant: "晚餐 拉面居酒屋", payer: neko, amount: 5200, currency: "JPY", consumers: four, category: "餐饮"),
            Row(date: date(9, 21, 10), merchant: "热海布丁", payer: innei, amount: 1800, currency: "JPY", consumers: four, note: "特制焦糖布丁 4个，现金支付找零¥500", method: "cash", category: "餐饮", place: seedPlace("atami-purin", "熱海プリン", 35.1025, 139.0758, category: "餐饮")),
            Row(date: date(9, 18, 20, 4), merchant: "五味八珍 ラスカ热海店", payer: whitewater, amount: 3135, currency: "JPY", consumers: two, note: "热海站前 ラスカ热海，白水垫付", category: "餐饮", place: seedPlace("gomihachichin", "五味八珍 ラスカ熱海店", 35.1040, 139.0776, category: "餐饮")),
            Row(date: date(9, 21, 19), merchant: "麺屋 猪一", payer: whitewater, amount: 9700, currency: "JPY", consumers: four, note: "京都・四条", category: "餐饮", place: seedPlace("menya-inoichi", "麺屋 猪一", 35.0036, 135.7663, category: "餐饮")),
            Row(date: date(9, 22, 12), merchant: "新潟カツ丼タレカツ 京都本店", payer: innei, amount: 1950, currency: "JPY", consumers: two, note: "猪排饭，与白水 2人分", category: "餐饮", place: seedPlace("tarekatsu", "新潟カツ丼 タレカツ 京都本店", 35.0065, 135.7678, category: "餐饮")),
            Row(date: date(9, 21, 12, 43), merchant: "新干线 热海→京都", payer: neko, amount: 49960, currency: "JPY", consumers: four, note: "こだま823 熱海12:43発 + のぞみ259 名古屋14:41発", category: "交通", place: seedPlace("atami-station", "新幹線 熱海駅", 35.1037, 139.0778, category: "交通")),
            Row(date: date(9, 17, 15), merchant: "teamLab Planets TOKYO", payer: neko, amount: 18400, currency: "JPY", consumers: four, note: "neko 信用卡垫付", method: "card", category: "门票", place: seedPlace("teamlab-planets", "teamLab Planets TOKYO", 35.6491, 139.7898, category: "门票")),
            Row(date: date(9, 23, 12), merchant: "北極星 四条河原町店", payer: innei, amount: 4190, currency: "JPY", consumers: two, note: "カレーオムライス+ビーフオムライス+エビフライセット+フルーツミックスアイス；现金¥10,200 找零¥6,010", method: "cash", category: "餐饮"),
            Row(date: date(9, 23, 10), merchant: "白狐守", payer: innei, amount: 2000, currency: "JPY", consumers: two, note: "御守 2 个，各 ¥1,000", category: "购物"),
            Row(date: date(9, 23, 11), merchant: "伏見稲荷 参道茶屋", payer: innei, amount: 2620, currency: "JPY", consumers: [], note: "手写小票；innei 现金垫付", method: "cash", category: "餐饮",
                lines: [LineDraft(name: "そば", amountMinor: 1600, consumers: [ConsumerDraft(whitewater.id)]),
                        LineDraft(name: "抹茶ミルク金時", amountMinor: 1020, consumers: [ConsumerDraft(innei.id)])]),
            Row(date: date(9, 23, 19), merchant: "麵屋優光", payer: innei, amount: 2580, currency: "JPY", consumers: [], note: "晚上吃面；innei 垫付整单", category: "餐饮",
                lines: [LineDraft(name: "鶏白湯らーめん", amountMinor: 1250, consumers: [ConsumerDraft(innei.id)]),
                        LineDraft(name: "淡竹", amountMinor: 900, consumers: [ConsumerDraft(whitewater.id)]),
                        LineDraft(name: "餃子", amountMinor: 430, consumers: two)]),
        ]

        let mine = [ConsumerDraft(innei.id)]
        let personal: [Row] = [
            Row(date: date(9, 19, 9), merchant: "Lawson", payer: innei, amount: 1204, currency: "JPY", consumers: mine, category: "餐饮", place: seedPlace("lawson-ito", "Lawson", 34.9660, 139.1020, category: "餐饮")),
            Row(date: date(9, 20, 12), merchant: "KFC 伊东Duo店", payer: innei, amount: 1190, currency: "JPY", consumers: mine, note: "一人食午餐", category: "餐饮", place: seedPlace("kfc-ito-duo", "KFC 伊東デュオ店", 34.9681, 139.0986, category: "餐饮")),
            Row(date: date(9, 20, 16), merchant: "7-Eleven 伊豆白田店", payer: innei, amount: 338, currency: "JPY", consumers: mine, category: "餐饮", place: seedPlace("711-shirata", "7-Eleven 伊豆白田店", 34.8455, 139.1178, category: "餐饮")),
            Row(date: date(9, 21, 11), merchant: "麦当劳 热海站前店", payer: innei, amount: 1110, currency: "JPY", consumers: mine, note: "月见汉堡套餐+炸虾块", category: "餐饮", place: seedPlace("mcdonalds-atami", "マクドナルド 熱海駅前店", 35.1033, 139.0770, category: "餐饮")),
            Row(date: date(9, 22, 14), merchant: "京都 IP書店", payer: innei, amount: 2090, currency: "JPY", consumers: mine, note: "サンリオ和ごころ 990 + しぐれうい御守り風アクリル 1,100", category: "购物", place: seedPlace("kyoto-ip-books", "京都 IP書店", 35.0040, 135.7688, category: "购物")),
            Row(date: date(9, 22, 15), merchant: "高島屋 京都", payer: innei, amount: 1804, currency: "JPY", consumers: mine, note: "カードラッピング 500+520 + クリスマスカード 620", category: "购物", place: seedPlace("takashimaya-kyoto", "高島屋 京都店", 35.0035, 135.7690, phone: "075-221-8811", category: "购物")),
            Row(date: date(9, 22, 12, 30), merchant: "麺や 鳥の鶏次 KYOTO 四条河原町店", payer: innei, amount: 1360, currency: "JPY", consumers: mine, note: "鶏白湯ラーメン 午餐", category: "餐饮", place: seedPlace("torinokeiji", "麺や 鳥の鶏次 KYOTO 四条河原町店", 35.0045, 135.7695, category: "餐饮")),
            Row(date: date(9, 22, 16), merchant: "マツモトキヨシ 京都四条河原町店", payer: innei, amount: 1389, currency: "JPY", consumers: mine, note: "オフテクス ティアージェW 657 + ソフトサンティア 627 + キレートレモン 105", category: "购物", place: seedPlace("matsukiyo-kyoto", "マツモトキヨシ 京都四条河原町店", 35.0038, 135.7686, phone: "075-253-6160", category: "购物")),
            Row(date: date(9, 22, 17), merchant: "京都まるん 祇園店", payer: innei, amount: 660, currency: "JPY", consumers: mine, note: "ピンズ 1点，含税10%", category: "购物", place: seedPlace("kyoto-marun", "京都まるん 祇園店", 35.0037, 135.7751, address: "〒605-0073 京都市東山区祇園町北側244", category: "购物")),
            Row(date: date(9, 22, 17, 30), merchant: "なわーど ラッシュ", payer: innei, amount: 540, currency: "JPY", consumers: mine, note: "レモン風味（果汁1%・ガラス瓶）", category: "餐饮"),
            Row(date: date(9, 22, 18), merchant: "ごちそう焼むすび おにまる 京都四条河原町店", payer: innei, amount: 1703, currency: "CNY", consumers: mine, note: "焼むすび，支付宝实付", original: Money(minor: 399, currency: "JPY"), method: "alipay", category: "餐饮", place: seedPlace("onimaru", "ごちそう焼むすび おにまる 京都四条河原町店", 35.0031, 135.7679, category: "餐饮")),
            Row(date: date(9, 23, 9), merchant: "ダイコクドラッグ 伏見稲荷参道店", payer: innei, amount: 85, currency: "JPY", consumers: mine, note: "メンソレータム 薬用リップ スティックXD，¥78+税", category: "购物"),
            Row(date: date(9, 15, 12), endsAt: date(9, 24, 12), merchant: "Suica 充值", payer: innei, amount: 8000, currency: "JPY", consumers: mine, note: "本次日本行程本地交通，地铁/巴士", category: "交通"),
            Row(date: date(9, 23, 15), merchant: "モンベル トレッキング サンブロック アンブレラ 55", payer: innei, amount: 6380, currency: "JPY", consumers: mine, note: "折りたたみ傘，SV シルバー，品番 1128560", category: "购物"),
            Row(date: date(9, 22, 18, 30), merchant: "Sanrio Gallery 京都店", payer: innei, amount: 1100, currency: "JPY", consumers: mine, note: "サンリオ グッズ，含税10%", category: "购物", place: seedPlace("sanrio-kyoto", "Sanrio Gallery 京都店", 35.0033, 135.7672, phone: "075-229-6955", category: "购物")),
        ]

        for row in shared + personal {
            let expense = try store.createExpense(ExpenseDraft(
                ledgerId: ledger.id, merchant: row.merchant, note: row.note, category: row.category,
                occurredAt: row.date, endsAt: row.endsAt, timeZone: tokyo.identifier, currency: row.currency, original: row.original,
                lines: row.lines ?? [LineDraft(name: row.merchant, amountMinor: row.amount, consumers: row.consumers)],
                payments: [PaymentDraft(row.payer.id, amountMinor: row.amount, method: row.method)]
            ))
            if let place = row.place {
                try store.setExpensePlace(expenseId: expense.id, candidate: place)
            }
        }
        try store.setRates(ledgerId: ledger.id, ["USD": Decimal(string: "6.71")!, "JPY": Decimal(string: "0.043")!], source: .manual)
    }
}
#endif
