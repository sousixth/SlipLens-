import SwiftUI
import SwiftData
import Charts

// MARK: - DashboardView

public struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TransactionItem.transactionDate, order: .reverse)
    private var allTransactions: [TransactionItem]

    @Bindable var viewModel: ExpenseTrackerViewModel
    @State private var selectedChartType: ChartStyle = .donut
    @State private var selectedTransactionForDetail: TransactionItem?

    public enum ChartStyle: String, CaseIterable, Identifiable {
        case donut = "Donut"
        case bar = "Bar"
        public var id: String { rawValue }
    }

    public init(viewModel: ExpenseTrackerViewModel) {
        self.viewModel = viewModel
    }

    private var monthTransactions: [TransactionItem] {
        viewModel.activeTransactionsForSelectedMonth(from: allTransactions)
    }

    private var categorySummaries: [CategorySpendingSummary] {
        viewModel.categorySpendingBreakdown(from: monthTransactions)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    monthSelectorHeader

                    if viewModel.isScanning {
                        ScanProgressView(viewModel: viewModel)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    summaryCardsSection

                    categoryChartSection

                    transactionsListSection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("SlipLens")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.startMonthlyScan(in: modelContext)
                    } label: {
                        Label("สแกนเดือนนี้", systemImage: "viewfinder.circle.fill")
                            .fontWeight(.semibold)
                    }
                    .disabled(viewModel.isScanning)
                }
            }
            .sheet(item: $selectedTransactionForDetail) { transaction in
                TransactionDetailView(
                    transaction: transaction,
                    viewModel: viewModel
                )
            }
            .alert(
                "การสแกนคลังภาพ",
                isPresented: Binding(
                    get: { viewModel.activeErrorMessage != nil },
                    set: { if !$0 { viewModel.activeErrorMessage = nil } }
                )
            ) {
                Button("ตกลง", role: .cancel) {
                    viewModel.activeErrorMessage = nil
                }
            } message: {
                Text(viewModel.activeErrorMessage ?? "")
            }
        }
    }

    // MARK: - Month Selector Header

    private var monthSelectorHeader: some View {
        HStack {
            Button {
                withAnimation(.snappy) {
                    viewModel.stepMonth(by: -1)
                }
            } label: {
                Image(systemName: "chevron.left.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(spacing: 2) {
                Text(viewModel.selectedMonthDisplayTitle)
                    .font(.headline)
                Text("\(monthTransactions.count) รายการ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                withAnimation(.snappy) {
                    viewModel.stepMonth(by: 1)
                }
            } label: {
                Image(systemName: "chevron.right.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Summary Cards Section (Income, Expense, Net Balance)

    private var summaryCardsSection: some View {
        let income = viewModel.totalIncome(from: monthTransactions)
        let expense = viewModel.totalExpense(from: monthTransactions)
        let net = viewModel.netBalance(from: monthTransactions)

        return VStack(spacing: 12) {
            HStack(spacing: 12) {
                metricCard(
                    title: "รายรับ (Payslips)",
                    amount: income,
                    icon: "arrow.down.left.circle.fill",
                    tint: .green
                )

                metricCard(
                    title: "รายจ่าย (Slips/Bills)",
                    amount: expense,
                    icon: "arrow.up.right.circle.fill",
                    tint: .red
                )
            }

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("คงเหลือสุทธิ (Net Balance)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(Self.formatTHB(net, showSign: true))
                        .font(.title2.weight(.bold).monospacedDigit())
                        .foregroundStyle(net >= 0 ? Color.primary : Color.red)
                }
                Spacer()
                Button {
                    viewModel.startMonthlyScan(in: modelContext)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles.rectangle.stack.fill")
                        Text(viewModel.isScanning ? "กำลังสแกน..." : "สแกนสลิปในอัลบั้ม")
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
                }
                .disabled(viewModel.isScanning)
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func metricCard(
        title: String,
        amount: Double,
        icon: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(Self.formatTHB(amount))
                .font(.headline.weight(.bold).monospacedDigit())
                .minimumScaleFactor(0.75)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Swift Charts Section

    private var categoryChartSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("สัดส่วนค่าใช้จ่ายตามหมวดหมู่")
                    .font(.headline)
                Spacer()
                Picker("Chart Style", selection: $selectedChartType) {
                    ForEach(ChartStyle.allCases) { style in
                        Text(style.rawValue).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
            }

            if categorySummaries.isEmpty {
                ContentUnavailableView(
                    "ยังไม่มีข้อมูลรายจ่ายในเดือนนี้",
                    systemImage: "chart.pie",
                    description: Text("กดปุ่ม \"สแกนสลิปในอัลบั้ม\" เพื่อดึงข้อมูลจากสลิปโอนเงินและใบเสร็จอัตโนมัติ")
                )
                .frame(height: 210)
            } else {
                if selectedChartType == .donut {
                    Chart(categorySummaries) { item in
                        SectorMark(
                            angle: .value("Amount", item.totalAmount),
                            innerRadius: .ratio(0.60),
                            angularInset: 2.0
                        )
                        .cornerRadius(6)
                        .foregroundStyle(item.category.tintColor)
                    }
                    .frame(height: 210)
                } else {
                    Chart(categorySummaries) { item in
                        BarMark(
                            x: .value("Amount (THB)", item.totalAmount),
                            y: .value("Category", item.category.localizedThaiName)
                        )
                        .cornerRadius(6)
                        .foregroundStyle(item.category.tintColor)
                        .annotation(position: .trailing) {
                            Text(String(format: "%.0f%%", item.percentage))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(height: CGFloat(max(180, categorySummaries.count * 44)))
                }

                Divider()

                // Category Breakdown Legend Rows
                VStack(spacing: 10) {
                    ForEach(categorySummaries) { summary in
                        HStack(spacing: 12) {
                            Circle()
                                .fill(summary.category.tintColor)
                                .frame(width: 10, height: 10)

                            Image(systemName: summary.category.systemImage)
                                .foregroundStyle(summary.category.tintColor)
                                .frame(width: 22)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(summary.category.localizedThaiName)
                                    .font(.subheadline.weight(.medium))
                                Text("\(summary.transactionCount) รายการ")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 2) {
                                Text(Self.formatTHB(summary.totalAmount))
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                                Text(String(format: "%.1f%%", summary.percentage))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Recent Transactions Section

    private var transactionsListSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("รายการในเดือนนี้")
                    .font(.headline)
                Spacer()
                Text("\(monthTransactions.count) รายการ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if monthTransactions.isEmpty {
                Text("ยังไม่มีรายการที่สแกนพบในเดือนนี้")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(monthTransactions) { item in
                        Button {
                            selectedTransactionForDetail = item
                        } label: {
                            TransactionRowView(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Currency Formatter

    public static func formatTHB(_ value: Double, showSign: Bool = false) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencySymbol = "฿"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        let formatted = formatter.string(from: NSNumber(value: abs(value))) ?? String(format: "฿%.2f", abs(value))
        if showSign {
            return value >= 0 ? "+\(formatted)" : "-\(formatted)"
        }
        return value < 0 ? "-\(formatted)" : formatted
    }
}

// MARK: - TransactionRowView

public struct TransactionRowView: View {
    let item: TransactionItem

    public init(item: TransactionItem) {
        self.item = item
    }

    public var body: some View {
        HStack(spacing: 12) {
            AssetThumbnailView(
                localIdentifier: item.assetLocalIdentifier,
                targetSize: CGSize(width: 50, height: 50),
                cornerRadius: 10
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.displayRecipientName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if item.reviewStatus == .pendingReview {
                        Text("รอตรวจ")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }

                HStack(spacing: 6) {
                    Label(item.category.localizedThaiName, systemImage: item.category.systemImage)
                        .font(.caption)
                        .foregroundStyle(item.category.tintColor)

                    Text("•")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(item.transactionDate, format: .dateTime.day().month(.abbreviated).hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(
                    (item.isIncome ? "+" : "-") + DashboardView.formatTHB(item.amount)
                )
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(item.isIncome ? .green : .primary)

                Text(item.documentType.shortName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
