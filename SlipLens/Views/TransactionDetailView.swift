import SwiftUI
import SwiftData

// MARK: - TransactionDetailView

public struct TransactionDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let transaction: TransactionItem
    @Bindable var viewModel: ExpenseTrackerViewModel

    @State private var editedAlias: String
    @State private var editedCategory: ExpenseCategory
    @State private var editedAmountString: String
    @State private var editedMemo: String
    @State private var saveAsRule: Bool = true
    @State private var retroactivelyApplyRule: Bool = true
    @State private var showFullSlipImage: Bool = false

    public init(transaction: TransactionItem, viewModel: ExpenseTrackerViewModel) {
        self.transaction = transaction
        self.viewModel = viewModel
        _editedAlias = State(initialValue: transaction.displayRecipientName)
        _editedCategory = State(initialValue: transaction.category)
        _editedAmountString = State(initialValue: String(format: "%.2f", transaction.amount))
        _editedMemo = State(initialValue: transaction.memo ?? "")
    }

    public var body: some View {
        NavigationStack {
            Form {
                // 1. Original Slip Preview from PHAsset
                Section("รูปภาพสลิปต้นฉบับ (PhotoKit Asset)") {
                    VStack(spacing: 10) {
                        Button {
                            showFullSlipImage = true
                        } label: {
                            AssetThumbnailView(
                                localIdentifier: transaction.assetLocalIdentifier,
                                targetSize: CGSize(width: 240, height: 320),
                                cornerRadius: 14
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)

                        Text("แตะที่รูปเพื่อขยายดูภาพเต็ม")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }

                // 2. Editable Transaction & Categorization Fields
                Section("ข้อมูลรายการและหมวดหมู่") {
                    LabeledContent("ประเภทเอกสาร") {
                        Label(transaction.documentType.displayName, systemImage: transaction.documentType.systemImage)
                            .font(.subheadline)
                    }

                    HStack {
                        Text("จำนวนเงิน (THB)")
                        Spacer()
                        TextField("0.00", text: $editedAmountString)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(.headline.monospacedDigit())
                    }

                    Picker("หมวดหมู่ (Category)", selection: $editedCategory) {
                        ForEach(ExpenseCategory.allCases) { category in
                            Label(category.localizedThaiName, systemImage: category.systemImage)
                                .tag(category)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("ชื่อที่แสดง (Custom Alias)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("เช่น ร้านข้าวมันไก่, ค่าไฟคอนโด", text: $editedAlias)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("บันทึกช่วยจำ (Memo)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("เพิ่มบันทึกช่วยจำ...", text: $editedMemo)
                    }
                }

                // 3. Smart Payee Mapping Rule Options
                if !transaction.isIncome {
                    Section {
                        Toggle(
                            "จดจำผู้รับ \"\(transaction.rawRecipientName)\" เป็นกฎอัตโนมัติ",
                            isOn: $saveAsRule
                        )
                        if saveAsRule {
                            Toggle(
                                "อัปเดตหมวดหมู่ย้อนหลังให้สลิปของผู้รับรายนี้ทั้งหมด",
                                isOn: $retroactivelyApplyRule
                            )
                        }
                    } header: {
                        Text("ระบบจัดหมวดหมู่อัจฉริยะ (Smart Payee Rule)")
                    } footer: {
                        Text("เมื่อเปิดใช้งาน ครั้งต่อไปที่สแกนพบสลิปโอนเงินไปยัง \"\(transaction.rawRecipientName)\" ระบบจะตั้งชื่อและจัดหมวดหมู่ให้อัตโนมัติ")
                    }
                }

                // 4. Payslip Specific Breakdown (if Payslip)
                if transaction.documentType == .payslip {
                    Section("รายละเอียดสลิปเงินเดือน (Payslip Breakdown)") {
                        if let gross = transaction.grossIncome {
                            LabeledContent("รายได้รวม (Gross Income)", value: DashboardView.formatTHB(gross))
                        }
                        if let tax = transaction.taxAndDeductions {
                            LabeledContent("ภาษีและรายการหัก (Deductions)", value: DashboardView.formatTHB(tax))
                        }
                        if let net = transaction.netPay {
                            LabeledContent("เงินได้สุทธิ (Net Pay)", value: DashboardView.formatTHB(net))
                                .fontWeight(.bold)
                        }
                    }
                }

                // 5. Extracted OCR & Mini-QR Audit Metadata
                Section("ข้อมูลที่สกัดได้จาก Vision OCR & Mini-QR") {
                    LabeledContent("ชื่อผู้รับจากสลิป (Raw)", value: transaction.rawRecipientName)
                    if let sender = transaction.senderName {
                        LabeledContent("ผู้โอน (Sender)", value: sender)
                    }
                    if let bank = transaction.bankName {
                        LabeledContent("ธนาคาร (Bank)", value: bank)
                    }
                    if let refID = transaction.transactionRefID {
                        LabeledContent("รหัสอ้างอิง (Ref ID)", value: refID)
                            .font(.caption.monospaced())
                    }
                    LabeledContent(
                        "วัน-เวลาในสลิป",
                        value: transaction.transactionDate.formatted(date: .abbreviated, time: .shortened)
                    )
                    LabeledContent(
                        "ความแม่นยำ OCR",
                        value: String(format: "%.0f%%", transaction.confidenceScore * 100)
                    )

                    DisclosureGroup("ข้อความดิบจาก OCR (Raw Text)") {
                        Text(transaction.rawOCRText)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                // 6. Ignore / Delete Action
                Section {
                    Button(role: .destructive) {
                        viewModel.ignoreTransaction(transaction, in: modelContext)
                        dismiss()
                    } label: {
                        Label("ไม่ใช่สลิป / ซ่อนรายการนี้ (Ignore)", systemImage: "eye.slash.fill")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
            .navigationTitle("รายละเอียดรายการ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("ปิด") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("บันทึก") {
                        let parsedAmount = Double(
                            editedAmountString.replacingOccurrences(of: ",", with: "")
                        ) ?? transaction.amount

                        viewModel.updateTransactionAndSaveRule(
                            item: transaction,
                            newCategory: editedCategory,
                            customAlias: editedAlias,
                            amount: parsedAmount,
                            memo: editedMemo.isEmpty ? nil : editedMemo,
                            saveAsPayeeRule: saveAsRule,
                            retroactivelyApplyRule: retroactivelyApplyRule,
                            in: modelContext
                        )
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
            .fullScreenCover(isPresented: $showFullSlipImage) {
                FullScreenAssetPreview(localIdentifier: transaction.assetLocalIdentifier)
            }
        }
    }
}

// MARK: - FullScreenAssetPreview

private struct FullScreenAssetPreview: View {
    @Environment(\.dismiss) private var dismiss
    let localIdentifier: String

    @State private var uiImage: UIImage?
    @State private var scale: CGFloat = 1.0

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if let uiImage {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    scale = max(1.0, min(value, 4.0))
                                }
                                .onEnded { _ in
                                    withAnimation(.spring) {
                                        if scale < 1.1 { scale = 1.0 }
                                    }
                                }
                        )
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("ปิด") {
                        dismiss()
                    }
                    .foregroundStyle(.white)
                }
            }
            .task {
                uiImage = try? await PhotoLibraryService.shared.loadUIImage(
                    localIdentifier: localIdentifier,
                    targetSize: CGSize(width: 2000, height: 2000),
                    deliveryMode: .highQualityFormat
                )
            }
        }
    }
}

// MARK: - PayeeRulesListView

public struct PayeeRulesListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PayeeMappingRule.updatedAt, order: .reverse)
    private var rules: [PayeeMappingRule]

    public init() {}

    public var body: some View {
        NavigationStack {
            Group {
                if rules.isEmpty {
                    ContentUnavailableView(
                        "ยังไม่มีกฎจำแนกผู้รับ",
                        systemImage: "wand.and.stars",
                        description: Text("เมื่อคุณแก้ไขหมวดหมู่หรือตั้งชื่อร้านค้าในหน้าตรวจสอบ ระบบจะบันทึกเป็นกฎอัตโนมัติที่นี่")
                    )
                } else {
                    List {
                        ForEach(rules) { rule in
                            HStack(spacing: 12) {
                                Image(systemName: rule.category.systemImage)
                                    .font(.title3)
                                    .foregroundStyle(rule.category.tintColor)
                                    .frame(width: 34, height: 34)
                                    .background(rule.category.tintColor.opacity(0.15), in: Circle())

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(rule.customAlias)
                                        .font(.subheadline.weight(.semibold))
                                    Text("ชื่อในสลิป: \(rule.rawPayeeExample)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(rule.category.localizedThaiName)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(rule.category.tintColor)
                                    Text("ใช้แล้ว \(rule.matchCount) ครั้ง")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                modelContext.delete(rules[index])
                            }
                            try? modelContext.save()
                        }
                    }
                }
            }
            .navigationTitle("กฎผู้รับเงิน (Payee Rules)")
        }
    }
}
