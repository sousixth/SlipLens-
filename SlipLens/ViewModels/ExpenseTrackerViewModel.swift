import Foundation
import SwiftUI
import SwiftData
import Observation

// MARK: - CategorySpendingSummary (Swift Charts Data Model)

public struct CategorySpendingSummary: Identifiable, Sendable, Equatable {
    public let category: ExpenseCategory
    public let totalAmount: Double
    public let percentage: Double
    public let transactionCount: Int

    public var id: String { category.id }

    public init(
        category: ExpenseCategory,
        totalAmount: Double,
        percentage: Double,
        transactionCount: Int
    ) {
        self.category = category
        self.totalAmount = totalAmount
        self.percentage = percentage
        self.transactionCount = transactionCount
    }
}

// MARK: - ExpenseTrackerViewModel

@Observable
@MainActor
public final class ExpenseTrackerViewModel {

    // MARK: - Selected Month/Year State

    public var selectedYear: Int
    public var selectedMonth: Int

    // MARK: - Scan Progress State

    public private(set) var isScanning: Bool = false
    public private(set) var processedCount: Int = 0
    public private(set) var totalAssetsToScan: Int = 0
    public private(set) var matchedNewSlipsCount: Int = 0
    public private(set) var skippedDuplicatesCount: Int = 0
    public var activeErrorMessage: String?

    private var scanTask: Task<Void, Never>?

    private let photoLibraryService: PhotoLibraryService
    private let categoryEngine: CategoryEngine

    // MARK: - Initialization

    public init(
        photoLibraryService: PhotoLibraryService = .shared,
        categoryEngine: CategoryEngine = .shared
    ) {
        self.photoLibraryService = photoLibraryService
        self.categoryEngine = categoryEngine

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Bangkok") ?? .current
        let nowComponents = calendar.dateComponents([.year, .month], from: .now)
        self.selectedYear = nowComponents.year ?? 2026
        self.selectedMonth = nowComponents.month ?? 10
    }

    // MARK: - Computed Month Properties

    public var selectedMonthYearKey: String {
        String(format: "%04d-%02d", selectedYear, selectedMonth)
    }

    public var selectedMonthDisplayTitle: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Bangkok") ?? .current
        guard let date = calendar.date(from: DateComponents(year: selectedYear, month: selectedMonth, day: 1)) else {
            return selectedMonthYearKey
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "th_TH")
        formatter.calendar = Calendar(identifier: .buddhist)
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: date)
    }

    public var scanFractionCompleted: Double {
        guard totalAssetsToScan > 0 else { return 0.0 }
        return min(1.0, Double(processedCount) / Double(totalAssetsToScan))
    }

    public func stepMonth(by offset: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Bangkok") ?? .current
        guard let current = calendar.date(from: DateComponents(year: selectedYear, month: selectedMonth, day: 1)),
              let target = calendar.date(byAdding: .month, value: offset, to: current) else {
            return
        }
        let comps = calendar.dateComponents([.year, .month], from: target)
        if let y = comps.year, let m = comps.month {
            selectedYear = y
            selectedMonth = m
        }
    }

    // MARK: - Analytics & Filtering Helpers

    public func activeTransactionsForSelectedMonth(from allItems: [TransactionItem]) -> [TransactionItem] {
        let key = selectedMonthYearKey
        return allItems
            .filter { $0.monthYearKey == key && $0.reviewStatus != .ignored }
            .sorted { $0.transactionDate > $1.transactionDate }
    }

    public func pendingReviewTransactions(from allItems: [TransactionItem]) -> [TransactionItem] {
        let key = selectedMonthYearKey
        return allItems
            .filter { $0.monthYearKey == key && $0.reviewStatus == .pendingReview }
            .sorted { $0.transactionDate > $1.transactionDate }
    }

    public func totalIncome(from monthItems: [TransactionItem]) -> Double {
        monthItems
            .filter { $0.isIncome }
            .reduce(0.0) { $0 + $1.amount }
    }

    public func totalExpense(from monthItems: [TransactionItem]) -> Double {
        monthItems
            .filter { !$0.isIncome }
            .reduce(0.0) { $0 + $1.amount }
    }

    public func netBalance(from monthItems: [TransactionItem]) -> Double {
        totalIncome(from: monthItems) - totalExpense(from: monthItems)
    }

    public func categorySpendingBreakdown(from monthItems: [TransactionItem]) -> [CategorySpendingSummary] {
        let expenseItems = monthItems.filter { !$0.isIncome }
        let grandTotal = expenseItems.reduce(0.0) { $0 + $1.amount }
        guard grandTotal > 0 else { return [] }

        var grouped: [ExpenseCategory: (total: Double, count: Int)] = [:]
        for item in expenseItems {
            let current = grouped[item.category] ?? (0.0, 0)
            grouped[item.category] = (current.total + item.amount, current.count + 1)
        }

        return grouped.map { category, stats in
            CategorySpendingSummary(
                category: category,
                totalAmount: stats.total,
                percentage: (stats.total / grandTotal) * 100.0,
                transactionCount: stats.count
            )
        }
        .sorted { $0.totalAmount > $1.totalAmount }
    }

    // MARK: - Monthly Photo Scan Orchestration

    public func startMonthlyScan(in modelContext: ModelContext) {
        guard !isScanning else { return }

        isScanning = true
        processedCount = 0
        totalAssetsToScan = 0
        matchedNewSlipsCount = 0
        skippedDuplicatesCount = 0
        activeErrorMessage = nil

        let targetYear = selectedYear
        let targetMonth = selectedMonth

        // Build O(1) DeduplicationIndex from all stored transactions (including ignored items)
        let existingItems = (try? modelContext.fetch(FetchDescriptor<TransactionItem>())) ?? []
        let dedupIndex = DeduplicationIndex(existingItems: existingItems)

        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await photoLibraryService.scanMonth(
                    year: targetYear,
                    month: targetMonth,
                    deduplicationIndex: dedupIndex
                ) { [weak self] progress in
                    await MainActor.run {
                        guard let self else { return }
                        self.processedCount = progress.processedCount
                        self.totalAssetsToScan = progress.totalAssets
                        self.matchedNewSlipsCount = progress.matchedCount
                        self.skippedDuplicatesCount = progress.skippedDuplicateCount

                        if let candidate = progress.latestCandidate {
                            self.categoryEngine.insertTransaction(from: candidate, in: modelContext)
                            try? modelContext.save()
                        }
                    }
                }
                self.isScanning = false
            } catch is CancellationError {
                self.isScanning = false
            } catch {
                self.isScanning = false
                self.activeErrorMessage = error.localizedDescription
            }
        }
    }

    public func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    // MARK: - Review Queue & Categorization Mutations

    public func verifyTransaction(_ item: TransactionItem, in modelContext: ModelContext) {
        item.reviewStatus = .verified
        try? modelContext.save()
    }

    public func verifyAllPending(in allItems: [TransactionItem], modelContext: ModelContext) {
        for item in pendingReviewTransactions(from: allItems) {
            item.reviewStatus = .verified
        }
        try? modelContext.save()
    }

    public func ignoreTransaction(_ item: TransactionItem, in modelContext: ModelContext) {
        item.reviewStatus = .ignored
        try? modelContext.save()
    }

    public func updateTransactionAndSaveRule(
        item: TransactionItem,
        newCategory: ExpenseCategory,
        customAlias: String,
        amount: Double,
        memo: String?,
        saveAsPayeeRule: Bool,
        retroactivelyApplyRule: Bool,
        in modelContext: ModelContext
    ) {
        let cleanedAlias = customAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        item.category = newCategory
        item.displayRecipientName = cleanedAlias.isEmpty ? item.rawRecipientName : cleanedAlias
        item.amount = amount
        item.memo = memo?.trimmingCharacters(in: .whitespacesAndNewlines)
        item.reviewStatus = .verified

        if saveAsPayeeRule && !item.isIncome {
            categoryEngine.savePayeeRule(
                rawPayeeName: item.rawRecipientName,
                customAlias: item.displayRecipientName,
                category: newCategory,
                retroactivelyUpdateTransactions: retroactivelyApplyRule,
                in: modelContext
            )
        } else {
            try? modelContext.save()
        }
    }
}
