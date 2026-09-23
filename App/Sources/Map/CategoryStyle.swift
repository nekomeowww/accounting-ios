import UIKit

enum CategoryStyle {
    static func symbol(for category: String?) -> String {
        switch category {
        case "餐饮": "fork.knife"
        case "交通": "tram.fill"
        case "住宿": "bed.double.fill"
        case "门票": "ticket.fill"
        case "购物": "bag.fill"
        case "便利店": "cart.fill"
        default: "mappin"
        }
    }

    static func color(for category: String?) -> UIColor {
        switch category {
        case "餐饮": .systemOrange
        case "交通": .systemBlue
        case "住宿": .systemPurple
        case "门票": .systemPink
        case "购物": .systemTeal
        case "便利店": .systemGreen
        default: .systemGray
        }
    }
}
