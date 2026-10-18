import Foundation
import SwiftData

// MARK: - PayeeResolutionResult

public struct PayeeResolutionResult: Sendable {
    public let displayAlias: String
    public let category: ExpenseCategory
    public let matchedRuleID: UUID?

    public init(displayAlias: String, category: ExpenseCategory, matchedRuleID: UUID? = nil) {
        self.displayAlias = displayAlias
        self.category = category
        self.matchedRuleID = matchedRuleID
    }
}

// MARK: - CategoryEngine

@MainActor
public final class CategoryEngine {

    public static let shared = CategoryEngine()

    public init() {}

    /// Resolves a candidate's raw recipient name against saved `PayeeMappingRule` records in SwiftData.
    /// Falls back to the heuristic category suggested by `SlipScannerService` if no rule matches.
    public func resolvePayee(
        rawRecipientName: String,
        fallbackCategory: ExpenseCategory,
        documentType: DocumentType,
        in modelContext: ModelContext
    ) -> PayeeResolutionResult {
        if documentType == .payslip {
            return PayeeResolutionResult(
                displayAlias: rawRecipientName,
                category: .salaryIncome,
                matchedRuleID: nil
            )
        }

        let normalizedKey = TransactionItem.normalizePayeeKey(rawRecipientName)
        guard !normalizedKey.isEmpty else {
            return PayeeResolutionResult(displayAlias: rawRecipientName, category: fallbackCategory)
        }

        let descriptor = FetchDescriptor<PayeeMappingRule>()
        let allRules = (try? modelContext.fetch(descriptor)) ?? []

        // 1. Exact normalized key match
        if let exactRule = allRules.first(where: { $0.normalizedPayeeKey == normalizedKey }) {
            exactRule.matchCount += 1
            exactRule.updatedAt = .now
            return PayeeResolutionResult(
                displayAlias: exactRule.customAlias,
                category: exactRule.category,
                matchedRuleID: exactRule.id
            )
        }

        // 2. Substring/Prefix match for shop names (e.g., "SCB MANEE SHOP" or branch suffixes)
        if let partialRule = allRules.first(where: { rule in
            guard rule.normalizedPayeeKey.count >= 4 else { return false }
            return normalizedKey.contains(rule.normalizedPayeeKey)
                || rule.normalizedPayeeKey.contains(normalizedKey)
        }) {
            partialRule.matchCount += 1
            partialRule.updatedAt = .now
            return PayeeResolutionResult(
                displayAlias: partialRule.customAlias,
                category: partialRule.category,
                matchedRuleID: partialRule.id
            )
        }

        return PayeeResolutionResult(
            displayAlias: rawRecipientName,
            category: fallbackCategory,
            matchedRuleID: nil
        )
    }

    /// Converts a `ScannedDocumentCandidate` into a `TransactionItem` and applies any matching `PayeeMappingRule`.
    @discardableResult
    public func insertTransaction(
        from candidate: ScannedDocumentCandidate,
        in modelContext: ModelContext
    ) -> TransactionItem {
        let resolution = resolvePayee(
            rawRecipientName: candidate.rawRecipientName,
            fallbackCategory: candidate.suggestedCategory,
            documentType: candidate.documentType,
            in: modelContext
        )

        // If a saved rule matched with high confidence, mark as verified automatically
        let initialStatus: ReviewStatus = (resolution.matchedRuleID != nil && candidate.confidenceScore >= 0.85)
            ? .verified
            : .pendingReview

        let item = TransactionItem(
            assetLocalIdentifier: candidate.assetLocalIdentifier,
            documentType: candidate.documentType,
            category: resolution.category,
            reviewStatus: initialStatus,
            amount: candidate.amount,
            transactionDate: candidate.transactionDate,
            transactionRefID: candidate.transactionRefID,
            rawRecipientName: candidate.rawRecipientName,
            displayRecipientName: resolution.displayAlias,
            senderName: candidate.senderName,
            bankName: candidate.bankName,
            memo: candidate.memo,
            grossIncome: candidate.grossIncome,
            taxAndDeductions: candidate.taxAndDeductions,
            netPay: candidate.netPay,
            rawOCRText: candidate.rawOCRText,
            qrPayload: candidate.qrPayload,
            confidenceScore: candidate.confidenceScore
        )

        modelContext.insert(item)
        return item
    }

    /// Creates or updates a `PayeeMappingRule` when the user customizes a recipient's category or alias,
    /// and optionally applies it to all existing transactions from the same recipient.
    @discardableResult
    public func savePayeeRule(
        rawPayeeName: String,
        customAlias: String,
        category: ExpenseCategory,
        retroactivelyUpdateTransactions: Bool = true,
        in modelContext: ModelContext
    ) -> PayeeMappingRule {
        let normalizedKey = TransactionItem.normalizePayeeKey(rawPayeeName)
        let cleanedAlias = customAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? rawPayeeName
            : customAlias.trimmingCharacters(in: .whitespacesAndNewlines)

        let descriptor = FetchDescriptor<PayeeMappingRule>()
        let existingRules = (try? modelContext.fetch(descriptor)) ?? []

        let rule: PayeeMappingRule
        if let existing = existingRules.first(where: { $0.normalizedPayeeKey == normalizedKey }) {
            existing.customAlias = cleanedAlias
            existing.category = category
            existing.updatedAt = .now
            rule = existing
        } else {
            let newRule = PayeeMappingRule(
                rawPayeeName: rawPayeeName,
                customAlias: cleanedAlias,
                category: category
            )
            modelContext.insert(newRule)
            rule = newRule
        }

        if retroactivelyUpdateTransactions {
            let txDescriptor = FetchDescriptor<TransactionItem>()
            let allTransactions = (try? modelContext.fetch(txDescriptor)) ?? []
            var matchCounter = 0

            for tx in allTransactions where !tx.isIncome {
                let txKey = TransactionItem.normalizePayeeKey(tx.rawRecipientName)
                if txKey == normalizedKey {
                    tx.displayRecipientName = cleanedAlias
                    tx.category = category
                    matchCounter += 1
                }
            }
            rule.matchCount = max(rule.matchCount, matchCounter)
        }

        try? modelContext.save()
        return rule
    }
}
