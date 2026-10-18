import Foundation
import Vision
import CoreGraphics
import UIKit
import SwiftData

// MARK: - SlipScannerError

public enum SlipScannerError: LocalizedError, Sendable {
    case invalidCGImage
    case notFinancialDocument
    case unparseableAmount

    public var errorDescription: String? {
        switch self {
        case .invalidCGImage:
            return "Unable to decode CGImage from the photo asset."
        case .notFinancialDocument:
            return "The image does not match slip, receipt, or payslip criteria."
        case .unparseableAmount:
            return "Could not extract a valid monetary amount from the document."
        }
    }
}

// MARK: - ThaiMiniQRData

/// Parsed payload from Bank of Thailand (BOT) EMVCo Mini-QR on Thai e-Slips.
public struct ThaiMiniQRData: Sendable, Equatable {
    public let rawPayload: String
    public let sendingBankCode: String?
    public let bankDisplayName: String?
    public let transactionRefID: String
    public let amount: Double?
}

// MARK: - DeduplicationIndex

/// Lightweight, thread-safe snapshot of existing SwiftData records for O(1) duplicate detection.
public struct DeduplicationIndex: Sendable {
    public var assetIdentifiers: Set<String>
    public var referenceIDs: Set<String>
    public var compositeFingerprints: Set<String>

    public init(
        assetIdentifiers: Set<String> = [],
        referenceIDs: Set<String> = [],
        compositeFingerprints: Set<String> = []
    ) {
        self.assetIdentifiers = assetIdentifiers
        self.referenceIDs = referenceIDs
        self.compositeFingerprints = compositeFingerprints
    }

    /// Builds a snapshot on the caller's actor from existing `TransactionItem` records.
    public init(existingItems: [TransactionItem]) {
        var assets = Set<String>()
        var refs = Set<String>()
        var fingerprints = Set<String>()

        for item in existingItems {
            assets.insert(item.assetLocalIdentifier)
            if let ref = TransactionItem.cleanReferenceID(item.transactionRefID) {
                refs.insert(ref)
            }
            fingerprints.insert(item.deduplicationFingerprint)
        }

        self.assetIdentifiers = assets
        self.referenceIDs = refs
        self.compositeFingerprints = fingerprints
    }

    public func contains(_ candidate: ScannedDocumentCandidate) -> Bool {
        if assetIdentifiers.contains(candidate.assetLocalIdentifier) {
            return true
        }
        if let ref = TransactionItem.cleanReferenceID(candidate.transactionRefID),
           ref.count >= 6,
           referenceIDs.contains(ref) {
            return true
        }
        if compositeFingerprints.contains(candidate.deduplicationFingerprint) {
            return true
        }
        return false
    }

    public mutating func insert(_ candidate: ScannedDocumentCandidate) {
        assetIdentifiers.insert(candidate.assetLocalIdentifier)
        if let ref = TransactionItem.cleanReferenceID(candidate.transactionRefID), ref.count >= 6 {
            referenceIDs.insert(ref)
        }
        compositeFingerprints.insert(candidate.deduplicationFingerprint)
    }
}

// MARK: - RecognizedTextLine

/// Represents a reconstructed horizontal row of text from Vision bounding boxes.
private struct RecognizedTextLine: Sendable {
    let text: String
    let normalizedY: CGFloat // Vision Y (0 = bottom, 1 = top)
    let confidence: Float
}

// MARK: - SlipScannerService

public actor SlipScannerService {

    public static let shared = SlipScannerService()

    public init() {}

    // MARK: - Keyword Dictionaries

    private static let slipKeywords: [String] = [
        "โอนเงินสำเร็จ", "รายการสำเร็จ", "ทำรายการสำเร็จ", "โอนเงิน",
        "รหัสอ้างอิง", "เลขที่รายการ", "เลขที่อ้างอิง", "ค่าธรรมเนียม",
        "บันทึกช่วยจำ", "พร้อมเพย์", "PROMPTPAY", "TRANSFER SUCCESSFUL",
        "TRANSACTION ID", "REF NO", "K PLUS", "SCB EASY", "KRUNGTHAI NEXT",
        "BUALUANG MBANKING", "KMA", "TTB TOUCH", "MYMO"
    ]

    private static let receiptKeywords: [String] = [
        "ใบเสร็จรับเงิน", "ใบเสร็จ", "ใบกำกับภาษี", "ใบกำกับภาษีอย่างย่อ",
        "TAX INVOICE", "ABB", "RECEIPT", "CASHIER", "รวมทั้งสิ้น",
        "ยอดสุทธิ", "GRAND TOTAL", "NET TOTAL", "SUBTOTAL", "VAT 7%"
    ]

    private static let payslipKeywords: [String] = [
        "สลิปเงินเดือน", "ใบแจ้งเงินเดือน", "เงินเดือน", "PAYSLIP",
        "PAY SLIP", "SALARY SLIP", "EARNINGS", "DEDUCTIONS",
        "รวมรายได้", "รวมรายการหัก", "เงินได้สุทธิ", "รับสุทธิ",
        "ประกันสังคม", "ภาษีหัก ณ ที่จ่าย", "กองทุนสำรองเลี้ยงชีพ", "NET PAY"
    ]

    private static let currencyKeywords: [String] = [
        "บาท", "THB", "฿", "BAHT"
    ]

    private static let bankCodeMap: [String: String] = [
        "002": "Bangkok Bank (BBL)",
        "004": "Kasikornbank (KBank)",
        "006": "Krungthai Bank (KTB)",
        "011": "TMBThanachart (ttb)",
        "014": "Siam Commercial Bank (SCB)",
        "022": "CIMB Thai",
        "024": "UOB Thailand",
        "025": "Krungsri (BAY)",
        "030": "Government Savings Bank (GSB)",
        "034": "BAAC (ธ.ก.ส.)",
        "069": "KKP (เกียรตินาคินภัทร)",
        "073": "LH Bank"
    ]

    // MARK: - Public API

    /// Fast heuristic pre-check based on image pixel dimensions before running heavy OCR.
    /// Rejects extreme panoramic photos while allowing portrait phone screenshots and standard slips.
    public nonisolated func passesAspectRatioPrecheck(pixelWidth: Int, pixelHeight: Int) -> Bool {
        guard pixelWidth >= 200, pixelHeight >= 200 else { return false }
        let width = Double(pixelWidth)
        let height = Double(pixelHeight)
        let aspect = height / width
        // Thai bank slips, screenshots, receipts, and landscape A4 payslips fall between 0.45 and 3.6
        return aspect >= 0.45 && aspect <= 3.6
    }

    /// Runs Vision Barcode + Text Recognition on a `CGImage`, classifies the document,
    /// and extracts structured financial fields.
    public func scanImage(
        cgImage: CGImage,
        assetLocalIdentifier: String,
        fallbackDate: Date
    ) async throws -> ScannedDocumentCandidate {
        let visionOutput = try performVisionRequests(on: cgImage)
        let miniQR = visionOutput.qrPayloads.compactMap(Self.parseThaiMiniQR).first

        let orderedLines = Self.reconstructLines(from: visionOutput.observations)
        let fullText = orderedLines.map(\.text).joined(separator: "\n")
        let normalizedUpperText = fullText.uppercased()

        guard Self.isLikelyFinancialDocument(
            upperText: normalizedUpperText,
            hasValidMiniQR: miniQR != nil
        ) else {
            throw SlipScannerError.notFinancialDocument
        }

        let documentType = Self.classifyDocument(
            upperText: normalizedUpperText,
            hasMiniQR: miniQR != nil
        )

        let avgConfidence: Double = {
            guard !orderedLines.isEmpty else { return 0.75 }
            let sum = orderedLines.reduce(0.0) { $0 + Double($1.confidence) }
            return min(1.0, max(0.1, sum / Double(orderedLines.count)))
        }()

        switch documentType {
        case .transferSlip:
            return try Self.extractTransferSlip(
                lines: orderedLines,
                fullText: fullText,
                miniQR: miniQR,
                assetLocalIdentifier: assetLocalIdentifier,
                fallbackDate: fallbackDate,
                confidence: avgConfidence
            )
        case .receipt:
            return try Self.extractReceipt(
                lines: orderedLines,
                fullText: fullText,
                qrPayload: visionOutput.qrPayloads.first,
                assetLocalIdentifier: assetLocalIdentifier,
                fallbackDate: fallbackDate,
                confidence: avgConfidence
            )
        case .payslip:
            return try Self.extractPayslip(
                lines: orderedLines,
                fullText: fullText,
                assetLocalIdentifier: assetLocalIdentifier,
                fallbackDate: fallbackDate,
                confidence: avgConfidence
            )
        }
    }

    // MARK: - Vision Execution

    private struct VisionRawOutput {
        let observations: [VNRecognizedTextObservation]
        let qrPayloads: [String]
    }

    private func performVisionRequests(on cgImage: CGImage) throws -> VisionRawOutput {
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.recognitionLanguages = ["th-TH", "en-US"]
        textRequest.usesLanguageCorrection = true
        textRequest.minimumTextHeight = 0.012

        let barcodeRequest = VNDetectBarcodesRequest()
        barcodeRequest.symbologies = [.qr]

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        try handler.perform([textRequest, barcodeRequest])

        let textObservations = textRequest.results ?? []
        let qrPayloads = (barcodeRequest.results ?? []).compactMap { $0.payloadStringValue }

        return VisionRawOutput(observations: textObservations, qrPayloads: qrPayloads)
    }

    /// Groups observations that share approximately the same vertical Y coordinate into a single line
    /// ordered left-to-right, and sorts lines top-to-bottom.
    private static func reconstructLines(
        from observations: [VNRecognizedTextObservation]
    ) -> [RecognizedTextLine] {
        struct Fragment {
            let text: String
            let minX: CGFloat
            let midY: CGFloat
            let confidence: Float
        }

        let fragments: [Fragment] = observations.compactMap { obs in
            guard let top = obs.topCandidates(1).first else { return nil }
            let trimmed = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return Fragment(
                text: trimmed,
                minX: obs.boundingBox.minX,
                midY: obs.boundingBox.midY,
                confidence: top.confidence
            )
        }

        // Sort top-to-bottom (higher midY in Vision coordinates is higher on screen)
        let sortedByY = fragments.sorted { $0.midY > $1.midY }
        let yTolerance: CGFloat = 0.016

        var rows: [[Fragment]] = []
        for fragment in sortedByY {
            if let lastRowIndex = rows.indices.last,
               let firstInRow = rows[lastRowIndex].first,
               abs(firstInRow.midY - fragment.midY) <= yTolerance {
                rows[lastRowIndex].append(fragment)
            } else {
                rows.append([fragment])
            }
        }

        return rows.map { row in
            let sortedLeftToRight = row.sorted { $0.minX < $1.minX }
            let combinedText = sortedLeftToRight.map(\.text).joined(separator: " ")
            let avgConf = sortedLeftToRight.reduce(Float(0)) { $0 + $1.confidence } / Float(sortedLeftToRight.count)
            let avgY = sortedLeftToRight.reduce(CGFloat(0)) { $0 + $1.midY } / CGFloat(sortedLeftToRight.count)
            return RecognizedTextLine(text: combinedText, normalizedY: avgY, confidence: avgConf)
        }
    }

    // MARK: - Thai Mini-QR EMVCo TLV Parser

    /// Parses Bank of Thailand (BOT) Slip Verification Mini-QR & PromptPay EMVCo TLV payloads.
    public static func parseThaiMiniQR(_ payload: String) -> ThaiMiniQRData? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 18 else { return nil }

        let topLevelTLV = parseTLV(trimmed)
        var sendingBankCode: String?
        var transactionRefID: String?
        var embeddedAmount: Double?

        if let amountStr = topLevelTLV["54"], let parsedAmount = Double(amountStr), parsedAmount > 0 {
            embeddedAmount = parsedAmount
        }

        // Standard BOT Slip Verify Mini-QR embeds sub-TLV inside Tag "00"
        if let tag00Value = topLevelTLV["00"], tag00Value.count > 10 {
            let subTLV = parseTLV(tag00Value)
            // Subtag 00 = "000001" (API ID), Subtag 01 = Sending Bank (3 digits), Subtag 02 = TransRef
            if let bank = subTLV["01"], let ref = subTLV["02"], !ref.isEmpty {
                sendingBankCode = bank
                transactionRefID = ref
            }
        }

        // Some banks place slip verification data in Tag 29, 30, or 51
        for tagKey in ["29", "30", "51", "62"] where transactionRefID == nil {
            if let nestedRaw = topLevelTLV[tagKey] {
                let subTLV = parseTLV(nestedRaw)
                if let ref = subTLV["02"] ?? subTLV["01"] ?? subTLV["05"], ref.count >= 8 {
                    transactionRefID = ref
                }
            }
        }

        // Fallback: If payload starts with "00" and contains a clear alphanumeric reference token
        if transactionRefID == nil, trimmed.hasPrefix("00") {
            let pattern = #"(?:0103(\d{3})02\d{2}([A-Za-z0-9]{10,35}))"#
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(
                   in: trimmed,
                   range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
               ),
               let bankRange = Range(match.range(at: 1), in: trimmed),
               let refRange = Range(match.range(at: 2), in: trimmed) {
                sendingBankCode = String(trimmed[bankRange])
                transactionRefID = String(trimmed[refRange])
            }
        }

        guard let validRef = transactionRefID, validRef.count >= 6 else {
            return nil
        }

        let bankName = sendingBankCode.flatMap { bankCodeMap[$0] }
        return ThaiMiniQRData(
            rawPayload: trimmed,
            sendingBankCode: sendingBankCode,
            bankDisplayName: bankName,
            transactionRefID: validRef,
            amount: embeddedAmount
        )
    }

    private static func parseTLV(_ input: String) -> [String: String] {
        var result: [String: String] = [:]
        var index = input.startIndex

        while index < input.endIndex {
            guard let tagEnd = input.index(index, offsetBy: 2, limitedBy: input.endIndex),
                  let lenEnd = input.index(tagEnd, offsetBy: 2, limitedBy: input.endIndex) else {
                break
            }
            let tag = String(input[index..<tagEnd])
            let lenStr = String(input[tagEnd..<lenEnd])
            guard let length = Int(lenStr), length >= 0,
                  let valueEnd = input.index(lenEnd, offsetBy: length, limitedBy: input.endIndex) else {
                break
            }
            let value = String(input[lenEnd..<valueEnd])
            result[tag] = value
            index = valueEnd
        }
        return result
    }

    // MARK: - Classification & Financial Validation

    private static func isLikelyFinancialDocument(
        upperText: String,
        hasValidMiniQR: Bool
    ) -> Bool {
        if hasValidMiniQR {
            return true
        }
        let hasCurrency = currencyKeywords.contains { upperText.contains($0) }
        let matchedSlip = slipKeywords.contains { upperText.contains($0) }
        let matchedReceipt = receiptKeywords.contains { upperText.contains($0) }
        let matchedPayslip = payslipKeywords.contains { upperText.contains($0) }

        if matchedSlip || matchedReceipt || matchedPayslip {
            return true
        }
        // Require both currency keyword and at least one formatted decimal amount
        if hasCurrency && firstRegexMatch(in: upperText, pattern: #"\b\d{1,3}(?:,\d{3})*\.\d{2}\b"#) != nil {
            return true
        }
        return false
    }

    private static func classifyDocument(
        upperText: String,
        hasMiniQR: Bool
    ) -> DocumentType {
        let payslipHits = payslipKeywords.filter { upperText.contains($0) }.count
        if payslipHits >= 2 || upperText.contains("สลิปเงินเดือน") || upperText.contains("PAYSLIP") {
            return .payslip
        }

        if hasMiniQR {
            return .transferSlip
        }

        let slipHits = slipKeywords.filter { upperText.contains($0) }.count
        let receiptHits = receiptKeywords.filter { upperText.contains($0) }.count

        if slipHits >= receiptHits && slipHits > 0 {
            return .transferSlip
        }
        if receiptHits > 0 {
            return .receipt
        }
        return .transferSlip
    }

    // MARK: - 1. Transfer Slip Extractor

    private static func extractTransferSlip(
        lines: [RecognizedTextLine],
        fullText: String,
        miniQR: ThaiMiniQRData?,
        assetLocalIdentifier: String,
        fallbackDate: Date,
        confidence: Double
    ) throws -> ScannedDocumentCandidate {
        let lineStrings = lines.map(\.text)

        // 1. Amount (Prefer Mini-QR amount if present, otherwise OCR)
        guard let amount = miniQR?.amount ?? extractSlipAmount(from: lineStrings, fullText: fullText),
              amount > 0 else {
            throw SlipScannerError.unparseableAmount
        }

        // 2. Date & Time
        let transactionDate = resolveTransactionDate(from: fullText, fallbackDate: fallbackDate)

        // 3. Transaction Reference ID
        let refID = miniQR?.transactionRefID ?? extractReferenceID(from: lineStrings, fullText: fullText)

        // 4. Bank Name
        let detectedBank = miniQR?.bankDisplayName ?? detectBankName(from: fullText)

        // 5. Sender & Recipient Names
        let (sender, recipient) = extractSlipParties(from: lineStrings)

        // 6. Memo ("บันทึกช่วยจำ")
        let memo = extractMemo(from: lineStrings)

        // 7. Initial Heuristic Category
        let suggestedCategory = guessCategory(
            recipient: recipient,
            memo: memo,
            documentType: .transferSlip
        )

        return ScannedDocumentCandidate(
            assetLocalIdentifier: assetLocalIdentifier,
            documentType: .transferSlip,
            suggestedCategory: suggestedCategory,
            amount: amount,
            transactionDate: transactionDate,
            transactionRefID: refID,
            rawRecipientName: recipient,
            senderName: sender,
            bankName: detectedBank,
            memo: memo,
            rawOCRText: fullText,
            qrPayload: miniQR?.rawPayload,
            confidenceScore: miniQR != nil ? max(confidence, 0.95) : confidence
        )
    }

    // MARK: - 2. Receipt Extractor

    private static func extractReceipt(
        lines: [RecognizedTextLine],
        fullText: String,
        qrPayload: String?,
        assetLocalIdentifier: String,
        fallbackDate: Date,
        confidence: Double
    ) throws -> ScannedDocumentCandidate {
        let lineStrings = lines.map(\.text)

        guard let totalAmount = extractReceiptTotalAmount(from: lineStrings, fullText: fullText),
              totalAmount > 0 else {
            throw SlipScannerError.unparseableAmount
        }

        let transactionDate = resolveTransactionDate(from: fullText, fallbackDate: fallbackDate)
        let merchantName = extractMerchantName(from: lineStrings)
        let refID = extractReferenceID(from: lineStrings, fullText: fullText)
        let suggestedCategory = guessCategory(
            recipient: merchantName,
            memo: nil,
            documentType: .receipt
        )

        return ScannedDocumentCandidate(
            assetLocalIdentifier: assetLocalIdentifier,
            documentType: .receipt,
            suggestedCategory: suggestedCategory,
            amount: totalAmount,
            transactionDate: transactionDate,
            transactionRefID: refID,
            rawRecipientName: merchantName,
            rawOCRText: fullText,
            qrPayload: qrPayload,
            confidenceScore: confidence
        )
    }

    // MARK: - 3. Payslip Extractor

    private static func extractPayslip(
        lines: [RecognizedTextLine],
        fullText: String,
        assetLocalIdentifier: String,
        fallbackDate: Date,
        confidence: Double
    ) throws -> ScannedDocumentCandidate {
        let lineStrings = lines.map(\.text)

        let grossIncome = extractLabeledAmount(
            in: lineStrings,
            labels: ["รวมรายได้", "รายได้รวม", "TOTAL EARNINGS", "TOTAL INCOME", "GROSS PAY", "เงินเดือน"]
        )
        let deductions = extractLabeledAmount(
            in: lineStrings,
            labels: ["รวมรายการหัก", "รายการหักรวม", "TOTAL DEDUCTIONS", "ภาษีหัก ณ ที่จ่าย", "TAX"]
        )
        let netPayExplicit = extractLabeledAmount(
            in: lineStrings,
            labels: ["เงินได้สุทธิ", "รับสุทธิ", "รายได้สุทธิ", "NET PAY", "NET SALARY"]
        )

        let resolvedNetPay: Double? = {
            if let netPayExplicit, netPayExplicit > 0 {
                return netPayExplicit
            }
            if let gross = grossIncome, let ded = deductions, gross > ded {
                return gross - ded
            }
            return grossIncome ?? extractSlipAmount(from: lineStrings, fullText: fullText)
        }()

        guard let finalNetPay = resolvedNetPay, finalNetPay > 0 else {
            throw SlipScannerError.unparseableAmount
        }

        let transactionDate = resolveTransactionDate(from: fullText, fallbackDate: fallbackDate)
        let employerName = extractEmployerName(from: lineStrings)

        return ScannedDocumentCandidate(
            assetLocalIdentifier: assetLocalIdentifier,
            documentType: .payslip,
            suggestedCategory: .salaryIncome,
            amount: finalNetPay,
            transactionDate: transactionDate,
            transactionRefID: nil,
            rawRecipientName: employerName,
            grossIncome: grossIncome ?? finalNetPay,
            taxAndDeductions: deductions ?? 0.0,
            netPay: finalNetPay,
            rawOCRText: fullText,
            qrPayload: nil,
            confidenceScore: confidence
        )
    }

    private static func resolveTransactionDate(from text: String, fallbackDate: Date) -> Date {
        guard let extracted = extractThaiDateTime(from: text) else {
            return fallbackDate
        }
        // Keep extracted date only if it falls in the same month/year as the photo's creationDate
        if TransactionItem.makeMonthYearKey(for: extracted) == TransactionItem.makeMonthYearKey(for: fallbackDate) {
            return extracted
        }
        return fallbackDate
    }

    // MARK: - Regex & Field Extraction Helpers

    private static func extractSlipAmount(from lines: [String], fullText: String) -> Double? {
        // Priority 1: Line with explicit amount label ("จำนวนเงิน", "จำนวน", "Amount")
        let amountLabels = ["จำนวนเงิน", "จำนวน", "ยอดโอน", "ยอดชำระ", "AMOUNT", "TOTAL"]
        for (index, line) in lines.enumerated() {
            let upper = line.uppercased()
            // Ignore fee lines ("ค่าธรรมเนียม")
            if upper.contains("ค่าธรรมเนียม") || upper.contains("FEE") {
                continue
            }
            if amountLabels.contains(where: { upper.contains($0) }) {
                if let amount = parseFirstCurrencyNumber(in: line), amount > 0 {
                    return amount
                }
                if index + 1 < lines.count,
                   let nextLineAmount = parseFirstCurrencyNumber(in: lines[index + 1]),
                   nextLineAmount > 0 {
                    return nextLineAmount
                }
            }
        }

        // Priority 2: Line containing "บาท" or "THB" that isn't a fee line
        for line in lines {
            let upper = line.uppercased()
            if upper.contains("ค่าธรรมเนียม") || upper.contains("FEE") {
                continue
            }
            if upper.contains("บาท") || upper.contains("THB") || upper.contains("฿") {
                if let amount = parseFirstCurrencyNumber(in: line), amount > 0 {
                    return amount
                }
            }
        }

        // Priority 3: Largest decimal number formatted as X,XXX.XX in the slip
        let allDecimals = parseAllDecimalAmounts(in: fullText)
        return allDecimals.filter { $0 > 0 }.max()
    }

    private static func extractReceiptTotalAmount(from lines: [String], fullText: String) -> Double? {
        let totalLabels = [
            "รวมทั้งสิ้น", "ยอดสุทธิ", "รวมสุทธิ", "ยอดชำระ", "รวมเงิน",
            "GRAND TOTAL", "NET TOTAL", "TOTAL AMOUNT", "TOTAL"
        ]
        for (index, line) in lines.enumerated().reversed() {
            let upper = line.uppercased()
            if totalLabels.contains(where: { upper.contains($0) }) {
                if let amount = parseFirstCurrencyNumber(in: line), amount > 0 {
                    return amount
                }
                if index + 1 < lines.count,
                   let nextAmount = parseFirstCurrencyNumber(in: lines[index + 1]),
                   nextAmount > 0 {
                    return nextAmount
                }
            }
        }
        return extractSlipAmount(from: lines, fullText: fullText)
    }

    private static func extractLabeledAmount(in lines: [String], labels: [String]) -> Double? {
        for (index, line) in lines.enumerated() {
            let upper = line.uppercased()
            if labels.contains(where: { upper.contains($0) }) {
                if let value = parseFirstCurrencyNumber(in: line), value > 0 {
                    return value
                }
                if index + 1 < lines.count,
                   let nextValue = parseFirstCurrencyNumber(in: lines[index + 1]),
                   nextValue > 0 {
                    return nextValue
                }
            }
        }
        return nil
    }

    private static func parseFirstCurrencyNumber(in text: String) -> Double? {
        let pattern = #"(?<!\d)(\d{1,3}(?:,\d{3})+|\d+)\.(\d{2})(?!\d)"#
        guard let match = firstRegexMatch(in: text, pattern: pattern) else {
            return nil
        }
        let cleaned = match.replacingOccurrences(of: ",", with: "")
        return Double(cleaned)
    }

    private static func parseAllDecimalAmounts(in text: String) -> [Double] {
        let pattern = #"(?<!\d)(\d{1,3}(?:,\d{3})+|\d+)\.(\d{2})(?!\d)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: nsRange).compactMap { result in
            guard let range = Range(result.range, in: text) else { return nil }
            let raw = text[range].replacingOccurrences(of: ",", with: "")
            return Double(raw)
        }
    }

    // MARK: - Thai Date & Time Parser (Buddhist Era & Gregorian)

    private static let thaiMonthMap: [(token: String, month: Int)] = [
        ("มกราคม", 1), ("กุมภาพันธ์", 2), ("มีนาคม", 3), ("เมษายน", 4),
        ("พฤษภาคม", 5), ("มิถุนายน", 6), ("กรกฎาคม", 7), ("สิงหาคม", 8),
        ("กันยายน", 9), ("ตุลาคม", 10), ("พฤศจิกายน", 11), ("ธันวาคม", 12),
        ("ม.ค.", 1), ("ก.พ.", 2), ("มี.ค.", 3), ("เม.ย.", 4),
        ("พ.ค.", 5), ("มิ.ย.", 6), ("ก.ค.", 7), ("ส.ค.", 8),
        ("ก.ย.", 9), ("ต.ค.", 10), ("พ.ย.", 11), ("ธ.ค.", 12),
        ("ม.ค", 1), ("ก.พ", 2), ("มี.ค", 3), ("เม.ย", 4),
        ("พ.ค", 5), ("มิ.ย", 6), ("ก.ค", 7), ("ส.ค", 8),
        ("ก.ย", 9), ("ต.ค", 10), ("พ.ย", 11), ("ธ.ค", 12),
        ("JAN", 1), ("FEB", 2), ("MAR", 3), ("APR", 4),
        ("MAY", 5), ("JUN", 6), ("JUL", 7), ("AUG", 8),
        ("SEP", 9), ("OCT", 10), ("NOV", 11), ("DEC", 12)
    ]

    public static func extractThaiDateTime(from text: String) -> Date? {
        let upper = text.uppercased()

        // Extract optional HH:mm(:ss)
        var hour = 12
        var minute = 0
        let timePattern = #"\b([01]?\d|2[0-3]):([0-5]\d)(?::([0-5]\d))?\b"#
        if let regex = try? NSRegularExpression(pattern: timePattern),
           let match = regex.firstMatch(in: upper, range: NSRange(upper.startIndex..<upper.endIndex, in: upper)),
           let hRange = Range(match.range(at: 1), in: upper),
           let mRange = Range(match.range(at: 2), in: upper) {
            hour = Int(upper[hRange]) ?? 12
            minute = Int(upper[mRange]) ?? 0
        }

        // Pattern A: Day + Thai/English Month Name + 2/4-digit Year (e.g., "18 ต.ค. 69", "18 ต.ค. 2569", "18 OCT 2026")
        for (token, monthNumber) in thaiMonthMap {
            let escapedToken = NSRegularExpression.escapedPattern(for: token)
            let pattern = #"(\d{1,2})\s*"# + escapedToken + #"\.?\s*(\d{2,4})"#
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: upper, range: NSRange(upper.startIndex..<upper.endIndex, in: upper)),
               let dayRange = Range(match.range(at: 1), in: upper),
               let yearRange = Range(match.range(at: 2), in: upper),
               let day = Int(upper[dayRange]),
               let rawYear = Int(upper[yearRange]) {
                if let date = buildGregorianDate(
                    day: day,
                    month: monthNumber,
                    rawYear: rawYear,
                    hour: hour,
                    minute: minute
                ) {
                    return date
                }
            }
        }

        // Pattern B: Numeric DD/MM/YYYY or DD-MM-YYYY
        let numericDatePattern = #"\b(\d{1,2})[/-](\d{1,2})[/-](\d{2,4})\b"#
        if let regex = try? NSRegularExpression(pattern: numericDatePattern),
           let match = regex.firstMatch(in: upper, range: NSRange(upper.startIndex..<upper.endIndex, in: upper)),
           let dRange = Range(match.range(at: 1), in: upper),
           let mRange = Range(match.range(at: 2), in: upper),
           let yRange = Range(match.range(at: 3), in: upper),
           let day = Int(upper[dRange]),
           let month = Int(upper[mRange]),
           let rawYear = Int(upper[yRange]) {
            return buildGregorianDate(day: day, month: month, rawYear: rawYear, hour: hour, minute: minute)
        }

        return nil
    }

    private static func buildGregorianDate(
        day: Int,
        month: Int,
        rawYear: Int,
        hour: Int,
        minute: Int
    ) -> Date? {
        guard (1...31).contains(day), (1...12).contains(month) else { return nil }
        let gregorianYear: Int
        if rawYear >= 2400 {
            // 4-digit Thai Buddhist Era (e.g., 2569 -> 2026)
            gregorianYear = rawYear - 543
        } else if rawYear >= 1970 && rawYear < 2400 {
            gregorianYear = rawYear
        } else if rawYear >= 60 && rawYear <= 99 {
            // 2-digit Thai Buddhist Era (e.g., 67 -> 2567 -> 2024, 69 -> 2569 -> 2026)
            gregorianYear = (2500 + rawYear) - 543
        } else if rawYear >= 20 && rawYear < 60 {
            // 2-digit Gregorian year (e.g., 26 -> 2026)
            gregorianYear = 2000 + rawYear
        } else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Bangkok") ?? .current
        var components = DateComponents()
        components.year = gregorianYear
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)
    }

    // MARK: - Reference ID, Parties, Bank & Memo Helpers

    private static func extractReferenceID(from lines: [String], fullText: String) -> String? {
        let refKeywords = [
            "เลขที่รายการ", "รหัสอ้างอิง", "เลขที่อ้างอิง", "หมายเลขอ้างอิง",
            "TRANSACTION ID", "REF NO", "REFERENCE", "REF."
        ]

        for (index, line) in lines.enumerated() {
            let upper = line.uppercased()
            if refKeywords.contains(where: { upper.contains($0) }) {
                if let token = firstRegexMatch(in: line, pattern: #"[A-Za-z0-9]{10,35}"#) {
                    return token
                }
                if index + 1 < lines.count,
                   let nextToken = firstRegexMatch(in: lines[index + 1], pattern: #"[A-Za-z0-9]{10,35}"#) {
                    return nextToken
                }
            }
        }

        return firstRegexMatch(in: fullText, pattern: #"\b\d{14,25}[A-Za-z0-9]{0,6}\b"#)
    }

    private static func detectBankName(from fullText: String) -> String? {
        let upper = fullText.uppercased()
        let rules: [(keywords: [String], name: String)] = [
            (["กสิกรไทย", "KASIKORNBANK", "K PLUS", "MAKE BY KBANK"], "Kasikornbank (KBank)"),
            (["ไทยพาณิชย์", "SCB EASY", "SCB"], "Siam Commercial Bank (SCB)"),
            (["กรุงไทย", "KRUNGTHAI", "KTB"], "Krungthai Bank (KTB)"),
            (["กรุงเทพ", "BANGKOK BANK", "BUALUANG"], "Bangkok Bank (BBL)"),
            (["กรุงศรี", "KRUNGSRI", "KMA"], "Krungsri (BAY)"),
            (["ทหารไทยธนชาต", "TTB", "TTB TOUCH"], "TMBThanachart (ttb)"),
            (["ออมสิน", "GSB", "MYMO"], "Government Savings Bank (GSB)"),
            (["TRUEMONEY", "ทรูมันนี่"], "TrueMoney Wallet")
        ]
        for rule in rules {
            if rule.keywords.contains(where: { upper.contains($0) }) {
                return rule.name
            }
        }
        return nil
    }

    private static func extractSlipParties(from lines: [String]) -> (sender: String?, recipient: String) {
        let senderMarkers = ["จาก", "ผู้โอน", "FROM"]
        let recipientMarkers = ["ไปยัง", "ไปที่", "ผู้รับเงิน", "โอนเงินไปที่", "บัญชีผู้รับ", "TO"]
        let namePrefixes = [
            "นาย", "นางสาว", "นาง", "น.ส.", "บจก.", "บมจ.", "หจก.",
            "บริษัท", "ร้าน", "MR.", "MRS.", "MS.", "MISS"
        ]

        var sender: String?
        var recipient: String?

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let upper = trimmed.uppercased()

            if sender == nil, senderMarkers.contains(where: { upper.hasPrefix($0) || upper == $0 }) {
                let inline = stripMarkerPrefix(from: trimmed, markers: senderMarkers)
                if isPlausiblePartyName(inline) {
                    sender = inline
                } else if index + 1 < lines.count, isPlausiblePartyName(lines[index + 1]) {
                    sender = lines[index + 1]
                }
            }

            if recipient == nil, recipientMarkers.contains(where: { upper.hasPrefix($0) || upper == $0 }) {
                let inline = stripMarkerPrefix(from: trimmed, markers: recipientMarkers)
                if isPlausiblePartyName(inline) {
                    recipient = inline
                } else if index + 1 < lines.count, isPlausiblePartyName(lines[index + 1]) {
                    recipient = lines[index + 1]
                } else if index + 2 < lines.count, isPlausiblePartyName(lines[index + 2]) {
                    recipient = lines[index + 2]
                }
            }
        }

        // Fallback: Find all lines starting with Thai/English honorifics or shop prefixes
        // On Thai slips, the first party is the sender and the second party is the recipient.
        if recipient == nil {
            let candidateNames = lines.filter { line in
                let u = line.trimmingCharacters(in: .whitespaces).uppercased()
                return namePrefixes.contains(where: { u.hasPrefix($0) }) && isPlausiblePartyName(line)
            }
            if candidateNames.count >= 2 {
                if sender == nil { sender = candidateNames[0] }
                recipient = candidateNames[1]
            } else if let single = candidateNames.first {
                recipient = single
            }
        }

        let resolvedRecipient = cleanPartyName(recipient ?? "Unknown Recipient (ไม่ระบุผู้รับ)")
        let resolvedSender = sender.map(cleanPartyName)
        return (resolvedSender, resolvedRecipient)
    }

    private static func stripMarkerPrefix(from line: String, markers: [String]) -> String {
        var result = line.trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in markers {
            if result.uppercased().hasPrefix(marker) {
                result = String(result.dropFirst(marker.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " :-\t"))
                break
            }
        }
        return result
    }

    private static func isPlausiblePartyName(_ text: String) -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 3, cleaned.count <= 80 else { return false }
        let upper = cleaned.uppercased()
        let forbidden = [
            "โอนเงินสำเร็จ", "รายการสำเร็จ", "จำนวนเงิน", "ค่าธรรมเนียม",
            "เลขที่รายการ", "รหัสอ้างอิง", "สแกนตรวจสอบ", "บาท", "XXX-"
        ]
        if forbidden.contains(where: { upper.contains($0) }) {
            return false
        }
        return true
    }

    private static func cleanPartyName(_ raw: String) -> String {
        // Mask out trailing masked account numbers like "xxx-x-x1234-x"
        let withoutMaskedAccount = raw.replacingOccurrences(
            of: #"\b[xX\d]{3,4}-[xX\d]-[xX\d]{4,6}-[xX\d]\b"#,
            with: "",
            options: .regularExpression
        )
        return withoutMaskedAccount
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func extractMemo(from lines: [String]) -> String? {
        let memoKeywords = ["บันทึกช่วยจำ", "หมายเหตุ", "MEMO", "NOTE"]
        for (index, line) in lines.enumerated() {
            let upper = line.uppercased()
            for keyword in memoKeywords where upper.contains(keyword) {
                let inline = stripMarkerPrefix(from: line, markers: memoKeywords)
                if !inline.isEmpty && inline.uppercased() != keyword {
                    return inline
                }
                if index + 1 < lines.count {
                    let next = lines[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !next.isEmpty && !next.contains("สแกน") {
                        return next
                    }
                }
            }
        }
        return nil
    }

    private static func extractMerchantName(from lines: [String]) -> String {
        for line in lines.prefix(5) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let upper = trimmed.uppercased()
            if trimmed.count >= 3,
               !upper.contains("ใบเสร็จ"),
               !upper.contains("ใบกำกับภาษี"),
               !upper.contains("TAX INVOICE"),
               !upper.contains("RECEIPT") {
                return cleanPartyName(trimmed)
            }
        }
        return "Receipt Merchant (ร้านค้า)"
    }

    private static func extractEmployerName(from lines: [String]) -> String {
        for line in lines.prefix(5) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let upper = trimmed.uppercased()
            if upper.contains("บริษัท") || upper.contains("บจก") || upper.contains("บมจ")
                || upper.contains("CO.,") || upper.contains("LTD") || upper.contains("CORP") {
                return cleanPartyName(trimmed)
            }
        }
        return lines.first.map(cleanPartyName) ?? "Employer (เงินเดือน)"
    }

    // MARK: - Built-in Heuristic Category Guesser (Fallback before PayeeMappingRule)

    public static func guessCategory(
        recipient: String,
        memo: String?,
        documentType: DocumentType
    ) -> ExpenseCategory {
        if documentType == .payslip {
            return .salaryIncome
        }
        let combined = "\(recipient) \(memo ?? "")".uppercased()

        let foodTokens = [
            "CAFE", "COFFEE", "STARBUCKS", "AMAZON", "พันธุ์ไทย", "เต่าบิน", "TAOBIN",
            "KFC", "MCDONALD", "MK", "SIZZLER", "SHABU", "SUSHI", "ข้าวมันไก่", "ก๋วยเตี๋ยว",
            "อาหาร", "กาแฟ", "ชานม", "7-ELEVEN", "CP ALL", "ซีพี ออลล์", "GRABFOOD", "LINEMAN",
            "SHOPEEFOOD", "FOODPANDA", "ร้านอาหาร", "กะเพรา", "ส้มตำ", "BAKERY"
        ]
        if foodTokens.contains(where: { combined.contains($0) }) {
            return .foodAndDrink
        }

        let transportTokens = [
            "BTS", "MRT", "BEM", "ทางด่วน", "EASY PASS", "PTT", "ปตท", "BANGCHAK", "บางจาก",
            "SHELL", "ESSO", "CALTEX", "GRAB", "BOLT", "TAXI", "แท็กซี่", "วิน", "น้ำมัน", "จอดรถ"
        ]
        if transportTokens.contains(where: { combined.contains($0) }) {
            return .transport
        }

        let utilityTokens = [
            "การไฟฟ้า", "MEA", "PEA", "การประปา", "MWA", "PWA", "AIS", "TRUE", "DTAC",
            "3BB", "NT", "ค่าไฟ", "ค่าน้ำ", "ค่าเน็ต", "ค่าเช่า", "คอนโด", "นิติบุคคล", "ประกัน"
        ]
        if utilityTokens.contains(where: { combined.contains($0) }) {
            return .billsAndUtilities
        }

        let shoppingTokens = [
            "SHOPEE", "LAZADA", "TIKTOK SHOP", "CENTRAL", "ROBINSON", "LOTUS", "โลตัส",
            "BIG C", "บิ๊กซี", "MAKRO", "แม็คโคร", "IKEA", "UNIQLO", "WATSONS", "EVEANDBOY",
            "HOMEPRO", "MR.D.I.Y", "DONKI", "TOPS"
        ]
        if shoppingTokens.contains(where: { combined.contains($0) }) {
            return .shopping
        }

        return .others
    }

    private static func firstRegexMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange),
              let range = Range(match.range, in: text) else {
            return nil
        }
        return String(text[range])
    }
}
