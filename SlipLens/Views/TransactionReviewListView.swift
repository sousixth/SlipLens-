import SwiftUI
import SwiftData

// MARK: - TransactionReviewListView

public struct TransactionReviewListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TransactionItem.transactionDate, order: .reverse)
    private var allTransactions: [TransactionItem]

    @Bindable var viewModel: ExpenseTrackerViewModel

    @State private var selectedTransaction: TransactionItem?
    @State private var rulePromptTarget: RulePromptContext?

    private struct RulePromptContext: Identifiable {
        let id = UUID()
        let transaction: TransactionItem
        let chosenCategory: ExpenseCategory
        var customAlias: String
    }

    public init(viewModel: ExpenseTrackerViewModel) {
        self.viewModel = viewModel
    }

    private var pendingItems: [TransactionItem] {
        viewModel.pendingReviewTransactions(from: allTransactions)
    }

    public var body: some View {
        NavigationStack {
            Group {
                if pendingItems.isEmpty {
                    ContentUnavailableView(
                        "ตรวจสอบครบทุกรายการแล้ว",
                        systemImage: "checkmark.seal.fill",
                        description: Text("ไม่มีสลิปหรือใบเสร็จที่รอตรวจสอบในเดือน \(viewModel.selectedMonthDisplayTitle)")
                    )
                } else {
                    List {
                        Section {
                            ForEach(pendingItems) { item in
                                ReviewQueueCard(
                                    item: item,
                                    onSelectCategory: { newCat in
                                        handleCategorySelection(for: item, category: newCat)
                                    },
                                    onTapDetail: {
                                        selectedTransaction = item
                                    }
                                )
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button {
                                        withAnimation {
                                            viewModel.verifyTransaction(item, in: modelContext)
                                        }
                                    } label: {
                                        Label("ยืนยัน", systemImage: "checkmark.circle.fill")
                                    }
                                    .tint(.green)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        withAnimation {
                                            viewModel.ignoreTransaction(item, in: modelContext)
                                        }
                                    } label: {
                                        Label("ไม่ใช่สลิป (ข้าม)", systemImage: "eye.slash.fill")
                                    }
                                }
                            }
                        } header: {
                            HStack {
                                Text("รอตรวจสอบ \(pendingItems.count) รายการ")
                                Spacer()
                                Text("ปัดขวาเพื่อยืนยัน • ปัดซ้ายเพื่อข้าม")
                                    .font(.caption2)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("รอตรวจสอบ")
            .toolbar {
                if !pendingItems.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("ยืนยันทั้งหมด") {
                            withAnimation {
                                viewModel.verifyAllPending(in: allTransactions, modelContext: modelContext)
                            }
                        }
                        .fontWeight(.semibold)
                    }
                }
            }
            .sheet(item: $selectedTransaction) { item in
                TransactionDetailView(transaction: item, viewModel: viewModel)
            }
            .alert(
                "บันทึกเป็นกฎจำแนกอัตโนมัติ?",
                isPresented: Binding(
                    get: { rulePromptTarget != nil },
                    set: { if !$0 { rulePromptTarget = nil } }
                ),
                presenting: rulePromptTarget
            ) { context in
                TextField("ชื่อเรียกผู้รับ (เช่น ร้านข้าวมันไก่)", text: Binding(
                    get: { rulePromptTarget?.customAlias ?? context.customAlias },
                    set: { rulePromptTarget?.customAlias = $0 }
                ))

                Button("บันทึกกฎและอัปเดตทุกรายการ") {
                    let alias = rulePromptTarget?.customAlias ?? context.customAlias
                    viewModel.updateTransactionAndSaveRule(
                        item: context.transaction,
                        newCategory: context.chosenCategory,
                        customAlias: alias,
                        amount: context.transaction.amount,
                        memo: context.transaction.memo,
                        saveAsPayeeRule: true,
                        retroactivelyApplyRule: true,
                        in: modelContext
                    )
                    rulePromptTarget = nil
                }

                Button("เปลี่ยนเฉพาะรายการนี้") {
                    viewModel.updateTransactionAndSaveRule(
                        item: context.transaction,
                        newCategory: context.chosenCategory,
                        customAlias: context.transaction.displayRecipientName,
                        amount: context.transaction.amount,
                        memo: context.transaction.memo,
                        saveAsPayeeRule: false,
                        retroactivelyApplyRule: false,
                        in: modelContext
                    )
                    rulePromptTarget = nil
                }

                Button("ยกเลิก", role: .cancel) {
                    rulePromptTarget = nil
                }
            } message: { context in
                Text(
                    "ต้องการจำว่า \"\(context.transaction.rawRecipientName)\" อยู่ในหมวด \"\(context.chosenCategory.localizedThaiName)\" สำหรับสลิปครั้งถัดไปหรือไม่?"
                )
            }
        }
    }

    private func handleCategorySelection(for item: TransactionItem, category: ExpenseCategory) {
        rulePromptTarget = RulePromptContext(
            transaction: item,
            chosenCategory: category,
            customAlias: item.displayRecipientName
        )
    }
}

// MARK: - ReviewQueueCard

private struct ReviewQueueCard: View {
    let item: TransactionItem
    let onSelectCategory: (ExpenseCategory) -> Void
    let onTapDetail: () -> Void

    private var shortBankLabel: String {
        guard let bank = item.bankName, !bank.isEmpty else {
            return item.documentType.shortName
        }
        if bank.contains("SCB") { return "SCB" }
        if bank.contains("KBank") { return "KBank" }
        if bank.contains("KTB") { return "KTB" }
        if bank.contains("BBL") { return "BBL" }
        if bank.contains("ttb") { return "ttb" }
        if bank.contains("BAY") || bank.contains("Krungsri") { return "Krungsri" }
        if bank.contains("GSB") { return "GSB" }
        return bank
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onTapDetail) {
                HStack(alignment: .center, spacing: 12) {
                    AssetThumbnailView(
                        localIdentifier: item.assetLocalIdentifier,
                        targetSize: CGSize(width: 52, height: 52),
                        cornerRadius: 10
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.displayRecipientName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        HStack(spacing: 4) {
                            Text(item.transactionDate, format: .dateTime.day().month(.abbreviated).hour().minute())
                            Text("•")
                            Text(shortBankLabel)
                                .fontWeight(.medium)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                    VStack(alignment: .trailing, spacing: 4) {
                        Text((item.isIncome ? "+" : "") + DashboardView.formatTHB(item.amount))
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(item.isIncome ? .green : .primary)
                            .lineLimit(1)

                        HStack(spacing: 4) {
                            if item.qrPayload != nil {
                                Image(systemName: "qrcode")
                                    .foregroundStyle(.blue)
                            }
                            Text(item.isIncome ? "รายรับ" : item.category.localizedThaiName)
                                .foregroundStyle(item.category.tintColor)
                        }
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            .buttonStyle(.plain)

            // Quick Category Pills (including 1-tap "เงินเข้า/รายรับ" pill first!)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // 1-Tap Incoming Money / Income Pill
                    let isIncomeSelected = item.category == .salaryIncome
                    Button {
                        onSelectCategory(.salaryIncome)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.left.circle.fill")
                            Text("เงินเข้า/รายรับ")
                        }
                        .font(.caption.weight(isIncomeSelected ? .bold : .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            isIncomeSelected
                                ? Color.green.opacity(0.25)
                                : Color.green.opacity(0.12),
                            in: Capsule()
                        )
                        .foregroundStyle(.green)
                        .fixedSize()
                    }
                    .buttonStyle(.plain)

                    ForEach(ExpenseCategory.expenseCategories) { category in
                        let isSelected = item.category == category
                        Button {
                            onSelectCategory(category)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: category.systemImage)
                                Text(category.localizedThaiName)
                            }
                            .font(.caption.weight(isSelected ? .bold : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                isSelected
                                    ? category.tintColor.opacity(0.22)
                                    : Color.secondary.opacity(0.12),
                                in: Capsule()
                            )
                            .foregroundStyle(isSelected ? category.tintColor : .primary)
                            .fixedSize()
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

