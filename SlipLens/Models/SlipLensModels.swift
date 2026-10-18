import Foundation
import SwiftData
import SwiftUI

// MARK: - DocumentType

public enum DocumentType: String, Codable, CaseIterable, Identifiable, Sendable {
    case transferSlip = "transfer_slip"
    case receipt = "receipt"
    case payslip = "payslip"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .transferSlip:
            return "Transfer Slip (สลิปโอนเงิน)"
        case .receipt:
            return "Receipt / Bill (ใบเสร็จ)"
        case .payslip:
            return "Payslip (สลิปเงินเดือน)"
        }
    }

    public var shortName: String {
        switch self {
        case .transferSlip: return "Slip"
        case .receipt: return "Receipt"
        case .payslip: return "Payslip"
        }
    }

    public var systemImage: String {
        switch self {
        case .transferSlip:
            return "qrcode.viewfinder"
        case .receipt:
            return "doc.text.image"
        case .payslip:
            return "banknote.fill"
        }
    }

    public var isIncomeDocument: Bool {
        self == .payslip
    }
}

// MARK: - ExpenseCategory

public enum ExpenseCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case foodAndDrink = "food_and_drink"
    case transport = "transport"
    case billsAndUtilities = "bills_and_utilities"
    case shopping = "shopping"
    case others = "others"
    case salaryIncome = "salary_income"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .foodAndDrink:
            return "Food & Drink"
        case .transport:
            return "Transport"
        case .billsAndUtilities:
            return "Bills & Utilities"
        case .shopping:
            return "Shopping"
        case .others:
            return "Others"
        case .salaryIncome:
            return "Salary / Income"
        }
    }

    public var localizedThaiName: String {
        switch self {
        case .foodAndDrink:
            return "อาหารและเครื่องดื่ม"
        case .transport:
            return "การเดินทาง"
        case .billsAndUtilities:
            return "บิลและสาธารณูปโภค"
        case .shopping:
            return "ช้อปปิ้ง"
        case .others:
            return "อื่นๆ"
        case .salaryIncome:
            return "เงินเดือน/รายรับ"
        }
    }

    public var systemImage: String {
        switch self {
        case .foodAndDrink:
            return "fork.knife"
        case .transport:
            return "tram.fill"
        case .billsAndUtilities:
            return "bolt.fill"
        case .shopping:
            return "bag.fill"
        case .others:
            return "ellipsis.circle.fill"
        case .salaryIncome:
            return "arrow.down.left.circle.fill"
        }
    }

    public var tintColor: Color {
        switch self {
        case .foodAndDrink:
            return .orange
        case .transport:
            return .blue
        case .billsAndUtilities:
            return .purple
        case .shopping:
            return .pink
        case .others:
            return .gray
        case .salaryIncome:
            return .green
        }
    }

    public var isIncome: Bool {
        self == .salaryIncome
    }

    /// Expense-only categories for spending filter pickers and charts.
    public static var expenseCategories: [ExpenseCategory] {
        allCases.filter { !$0.isIncome }
    }
}

// MARK: - ReviewStatus

public enum ReviewStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case pendingReview = "pending_review"
    case verified = "verified"
    case ignored = "ignored"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .pendingReview: return "Needs Review"
        case .verified: return "Verified"
        case .ignored: return "Ignored"
        }
    }
}

// MARK: - TransactionItem (@Model)

@Model
public final class TransactionItem {
    @Attribute(.unique) public var id: UUID

    /// PhotoKit `PHAsset.localIdentifier` used to display the original slip image.
    public var assetLocalIdentifier: String

    /// Backing raw string for `DocumentType` to support SwiftData `#Predicate` queries.
    public var documentTypeRaw: String

    /// Backing raw string for `ExpenseCategory` to support SwiftData `#Predicate` queries.
    public var categoryRaw: String

    /// Backing raw string for `ReviewStatus` to support SwiftData `#Predicate` queries.
    public var reviewStatusRaw: String

    /// Primary amount in THB (for payslips, this equals `netPay`).
    public var amount: Double

    /// Extracted date/time of the transaction, or fallback to PHAsset creationDate.
    public var transactionDate: Date

    /// Normalized `"YYYY-MM"` key (in Gregorian calendar) for fast monthly queries.
    public var monthYearKey: String

    /// Transaction reference ID extracted from Mini-QR or OCR text.
    public var transactionRefID: String?

    /// Original recipient/merchant name extracted directly from OCR.
    public var rawRecipientName: String

    /// User-friendly alias from `PayeeMappingRule` or edited manually.
    public var displayRecipientName: String

    /// Optional sender name extracted from bank transfer slips.
    public var senderName: String?

    /// Detected Thai bank code or bank name (e.g., "KBank", "SCB", "KTB", "BBL").
    public var bankName: String?

    /// Note / memo line extracted from the slip ("บันทึกช่วยจำ").
    public var memo: String?

    // MARK: Payslip Specific Fields
    public var grossIncome: Double?
    public var taxAndDeductions: Double?
    public var netPay: Double?

    // MARK: Metadata & Audit Fields
    public var rawOCRText: String
    public var qrPayload: String?
    public var confidenceScore: Double
    public var deduplicationFingerprint: String
    public var createdAt: Date

    // MARK: Computed Type-Safe Accessors

    public var documentType: DocumentType {
        get { DocumentType(rawValue: documentTypeRaw) ?? .transferSlip }
        set { documentTypeRaw = newValue.rawValue }
    }

    public var category: ExpenseCategory {
        get { ExpenseCategory(rawValue: categoryRaw) ?? .others }
        set { categoryRaw = newValue.rawValue }
    }

    public var reviewStatus: ReviewStatus {
        get { ReviewStatus(rawValue: reviewStatusRaw) ?? .pendingReview }
        set { reviewStatusRaw = newValue.rawValue }
    }

    public var isIncome: Bool {
        documentType == .payslip || category == .salaryIncome
    }

    public init(
        id: UUID = UUID(),
        assetLocalIdentifier: String,
        documentType: DocumentType,
        category: ExpenseCategory,
        reviewStatus: ReviewStatus = .pendingReview,
        amount: Double,
        transactionDate: Date,
        transactionRefID: String? = nil,
        rawRecipientName: String,
        displayRecipientName: String? = nil,
        senderName: String? = nil,
        bankName: String? = nil,
        memo: String? = nil,
        grossIncome: Double? = nil,
        taxAndDeductions: Double? = nil,
        netPay: Double? = nil,
        rawOCRText: String,
        qrPayload: String? = nil,
        confidenceScore: Double = 0.8,
        createdAt: Date = .now
    ) {
        self.id = id
        self.assetLocalIdentifier = assetLocalIdentifier
        self.documentTypeRaw = documentType.rawValue
        self.categoryRaw = category.rawValue
        self.reviewStatusRaw = reviewStatus.rawValue
        self.amount = amount
        self.transactionDate = transactionDate
        self.monthYearKey = Self.makeMonthYearKey(for: transactionDate)
        self.transactionRefID = Self.cleanReferenceID(transactionRefID)
        self.rawRecipientName = rawRecipientName
        self.displayRecipientName = displayRecipientName ?? rawRecipientName
        self.senderName = senderName
        self.bankName = bankName
        self.memo = memo
        self.grossIncome = grossIncome
        self.taxAndDeductions = taxAndDeductions
        self.netPay = netPay
        self.rawOCRText = rawOCRText
        self.qrPayload = qrPayload
        self.confidenceScore = confidenceScore
        self.deduplicationFingerprint = Self.computeDeduplicationFingerprint(
            transactionRefID: transactionRefID,
            date: transactionDate,
            amount: amount,
            rawRecipientName: rawRecipientName
        )
        self.createdAt = createdAt
    }

    // MARK: Static Formatting & Deduplication Helpers

    public static func makeMonthYearKey(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Bangkok") ?? .current
        let components = calendar.dateComponents([.year, .month], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        return String(format: "%04d-%02d", year, month)
    }

    public static func cleanReferenceID(_ refID: String?) -> String? {
        guard let refID = refID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !refID.isEmpty else {
            return nil
        }
        return refID.uppercased()
    }

    public static func normalizePayeeKey(_ rawName: String) -> String {
        let strippedTitles = [
            "นาย", "นางสาว", "นาง", "น.ส.", "ด.ช.", "ด.ญ.",
            "MR.", "MR", "MRS.", "MRS", "MS.", "MS", "MISS",
            "บจก.", "บมจ.", "หจก.", "บริษัท", "จำกัด", "(มหาชน)", "ร้าน"
        ]
        var working = rawName
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        for title in strippedTitles {
            if working.hasPrefix(title + " ") {
                working = String(working.dropFirst(title.count)).trimmingCharacters(in: .whitespaces)
            } else if working.hasPrefix(title) && title.contains(".") {
                working = String(working.dropFirst(title.count)).trimmingCharacters(in: .whitespaces)
            }
        }

        let compact = working
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return compact
    }

    /// Generates a deterministic fingerprint using either the exact `transactionRefID`
    /// or `(minute-granularity timestamp + amount + normalized recipient name)`.
    public static func computeDeduplicationFingerprint(
        transactionRefID: String?,
        date: Date,
        amount: Double,
        rawRecipientName: String
    ) -> String {
        if let cleanedRef = cleanReferenceID(transactionRefID), cleanedRef.count >= 6 {
            return "REF:\(cleanedRef)"
        }
        let minuteBucket = Int(date.timeIntervalSince1970 / 60.0)
        let formattedAmount = String(format: "%.2f", amount)
        let normalizedRecipient = normalizePayeeKey(rawRecipientName)
        return "COMP:\(minuteBucket)|\(formattedAmount)|\(normalizedRecipient)"
    }
}

// MARK: - PayeeMappingRule (@Model)

@Model
public final class PayeeMappingRule {
    @Attribute(.unique) public var id: UUID

    /// Normalized uppercase lookup key produced by `TransactionItem.normalizePayeeKey(_:)`.
    @Attribute(.unique) public var normalizedPayeeKey: String

    /// Example raw recipient string captured when the rule was created (e.g. "นาย สมชาย ใจดี").
    public var rawPayeeExample: String

    /// Custom user-defined display name (e.g. "ร้านข้าวมันไก่").
    public var customAlias: String

    /// Backing raw string for `ExpenseCategory`.
    public var categoryRaw: String

    /// Number of times this rule has been applied automatically.
    public var matchCount: Int

    public var updatedAt: Date

    public var category: ExpenseCategory {
        get { ExpenseCategory(rawValue: categoryRaw) ?? .others }
        set { categoryRaw = newValue.rawValue }
    }

    public init(
        id: UUID = UUID(),
        rawPayeeName: String,
        customAlias: String,
        category: ExpenseCategory,
        matchCount: Int = 1,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.normalizedPayeeKey = TransactionItem.normalizePayeeKey(rawPayeeName)
        self.rawPayeeExample = rawPayeeName
        self.customAlias = customAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? rawPayeeName
            : customAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        self.categoryRaw = category.rawValue
        self.matchCount = matchCount
        self.updatedAt = updatedAt
    }
}

// MARK: - Sendable Snapshot DTOs for Concurrency

/// Thread-safe value type returned by `SlipScannerService` before inserting into `ModelContext`.
public struct ScannedDocumentCandidate: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let assetLocalIdentifier: String
    public let documentType: DocumentType
    public let suggestedCategory: ExpenseCategory
    public let amount: Double
    public let transactionDate: Date
    public let transactionRefID: String?
    public let rawRecipientName: String
    public let senderName: String?
    public let bankName: String?
    public let memo: String?
    public let grossIncome: Double?
    public let taxAndDeductions: Double?
    public let netPay: Double?
    public let rawOCRText: String
    public let qrPayload: String?
    public let confidenceScore: Double

    public var deduplicationFingerprint: String {
        TransactionItem.computeDeduplicationFingerprint(
            transactionRefID: transactionRefID,
            date: transactionDate,
            amount: amount,
            rawRecipientName: rawRecipientName
        )
    }

    public init(
        id: UUID = UUID(),
        assetLocalIdentifier: String,
        documentType: DocumentType,
        suggestedCategory: ExpenseCategory,
        amount: Double,
        transactionDate: Date,
        transactionRefID: String? = nil,
        rawRecipientName: String,
        senderName: String? = nil,
        bankName: String? = nil,
        memo: String? = nil,
        grossIncome: Double? = nil,
        taxAndDeductions: Double? = nil,
        netPay: Double? = nil,
        rawOCRText: String,
        qrPayload: String? = nil,
        confidenceScore: Double
    ) {
        self.id = id
        self.assetLocalIdentifier = assetLocalIdentifier
        self.documentType = documentType
        self.suggestedCategory = suggestedCategory
        self.amount = amount
        self.transactionDate = transactionDate
        self.transactionRefID = TransactionItem.cleanReferenceID(transactionRefID)
        self.rawRecipientName = rawRecipientName
        self.senderName = senderName
        self.bankName = bankName
        self.memo = memo
        self.grossIncome = grossIncome
        self.taxAndDeductions = taxAndDeductions
        self.netPay = netPay
        self.rawOCRText = rawOCRText
        self.qrPayload = qrPayload
        self.confidenceScore = confidenceScore
    }
}
