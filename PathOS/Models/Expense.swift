import Foundation
import SwiftData

nonisolated enum ExpenseCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case food
    case groceries
    case transport
    case shopping
    case entertainment
    case bills
    case health
    case other

    var id: String { rawValue }

    var label: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .food: "fork.knife"
        case .groceries: "cart.fill"
        case .transport: "car.fill"
        case .shopping: "bag.fill"
        case .entertainment: "ticket.fill"
        case .bills: "doc.text.fill"
        case .health: "cross.case.fill"
        case .other: "square.grid.2x2.fill"
        }
    }
}

@Model
final class Expense {
    var id: UUID = UUID()
    var merchant: String = ""
    var amount: Double = 0
    var currencyCode: String = "INR"
    var categoryRaw: String = ExpenseCategory.other.rawValue
    var date: Date = Date()
    var note: String = ""

    init(merchant: String, amount: Double, currencyCode: String = "INR", category: ExpenseCategory, date: Date = Date(), note: String = "") {
        self.merchant = merchant
        self.amount = amount
        self.currencyCode = currencyCode
        self.categoryRaw = category.rawValue
        self.date = date
        self.note = note
    }

    var category: ExpenseCategory {
        get { ExpenseCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }
}
