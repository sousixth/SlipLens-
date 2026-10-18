# SlipLens — iOS Expense & Payslip Tracker (On-Device Thai OCR & Mini-QR)

**SlipLens** คือแอปพลิเคชัน iOS สำหรับสรุปรายรับ-รายจ่ายรายเดือนอัตโนมัติ โดยสแกนรูปภาพจากอัลบั้ม (**Photo Library**) ในเดือนที่เลือก เพื่อสกัดข้อมูลจาก **สลิปโอนเงินธนาคารไทย (Thai Bank Transfer Slips)**, **ใบเสร็จรับเงิน (Receipts/Bills)** และ **สลิปเงินเดือน (Payslips)** ด้วยเทคโนโลยี **Apple Vision Framework (On-Device OCR & Barcode Scanning)** และจัดเก็บข้อมูลลง **SwiftData** แบบออฟไลน์บนอุปกรณ์ 100% เพื่อความเป็นส่วนตัวสูงสุด

---

## ✨ ฟีเจอร์หลัก (Core Features)

1. **Monthly Photo Scanner (`PhotoLibraryService`)**
   - ดึงรูปภาพจาก `PHAsset` เฉพาะในเดือนและปีที่เลือก (ตามเขตเวลา `Asia/Bangkok`)
   - คัดกรองรูปถ่ายทั่วไปออกอย่างรวดเร็วด้วยการตรวจสอบสัดส่วนภาพ (Aspect Ratio Pre-check), การตรวจหา **Thai PromptPay / BOT Mini-QR** และคำสำคัญทางการเงิน (`โอนเงินสำเร็จ`, `รายการสำเร็จ`, `ใบเสร็จ`, `รหัสอ้างอิง`, `บาท`, `THB`, `Payslip`, `เงินเดือน`)
   - แสดงแถบความคืบหน้าแบบเรียลไทม์ (`ScanProgressView`) พร้อมรองรับการกดยกเลิกกลางคัน

2. **Hybrid Thai Slip, Receipt & Payslip Parser (`SlipScannerService`)**
   - **Mini-QR EMVCo TLV Parser:** ถอดรหัส QR Code มาตรฐานธนาคารแห่งประเทศไทย (BOT Slip Verification) เพื่อดึงรหัสธนาคารผู้โอน (`004` KBank, `014` SCB, `006` KTB, `002` BBL, `025` BAY, `011` ttb, `030` GSB) และรหัสอ้างอิงธุรกรรม (`Transaction Ref ID`) ที่แม่นยำ 100%
   - **Dual-Language Vision OCR (`th-TH` + `en-US`):** ใช้ `VNRecognizeTextRequest` (`.accurate`) พร้อมอัลกอริทึมจัดเรียงบรรทัดตามพิกัดแกน Y/X เพื่อรองรับสลิปที่วางหัวข้อไว้ซ้ายและตัวเลขไว้ขวา
   - **จำแนกเอกสารอัตโนมัติ 3 ประเภท (`DocumentType`):**
     - `transferSlip`: สกัดจำนวนเงิน, วัน-เวลา (แปลงปี พ.ศ. 4 หลัก และ 2 หลัก เช่น `69` $\rightarrow$ `2569` $\rightarrow$ `2026` อัตโนมัติ), รหัสอ้างอิง, ชื่อผู้โอน, ชื่อผู้รับ, ธนาคาร และบันทึกช่วยจำ
     - `receipt`: สกัดชื่อร้านค้า, ยอดสุทธิ (`รวมทั้งสิ้น` / `Grand Total`) และวันที่
     - `payslip`: สกัดรายได้รวม (`Gross Income`), ภาษี/ประกันสังคม/รายการหัก (`Deductions`) และเงินได้สุทธิ (`Net Pay`)
   - **ระบบป้องกันรายการซ้ำ (`DeduplicationIndex`):** ตรวจสอบทั้ง `PHAsset.localIdentifier`, `transactionRefID` และลายนิ้วมือธุรกรรม `(วันเวลาระดับนาที + จำนวนเงิน + ชื่อผู้รับที่ตัดคำนำหน้า)` ป้องกันการนับซ้ำหากผู้ใช้บันทึกหรือแคปหน้าจอสลิปเดิมซ้ำ

3. **Smart Payee Mapping & Auto-Categorization (`CategoryEngine`)**
   - จดจำกฎการแปลงชื่อผู้รับดิบจากสลิป (เช่น `"นาย สมชาย ใจดี"` หรือ `"SCB Manee SHOP"`) ให้เป็นชื่อที่เข้าใจง่าย (เช่น `"ร้านข้าวมันไก่"`) พร้อมผูกกับหมวดหมู่ (`Food & Drink`, `Transport`, `Bills & Utilities`, `Shopping`, `Others`, `Salary / Income`)
   - เมื่อผู้ใช้เปลี่ยนหมวดหมู่หรือแก้ไขชื่อผู้รับ สามารถเลือกให้ระบบจดจำเป็นกฎอัตโนมัติ (`PayeeMappingRule`) และอัปเดตย้อนหลังให้กับสลิปทุกรายการของผู้รับคนเดียวกันได้ทันที

4. **Dashboard & Analytics UI (`SwiftUI` + `Swift Charts`)**
   - **Dashboard (`DashboardView`):** สรุปรายรับรวมจาก Payslip, รายจ่ายรวมจากสลิป/ใบเสร็จ, ยอดคงเหลือสุทธิ (Net Balance) และกราฟ **Donut Chart / Bar Chart** แยกตามหมวดหมู่
   - **Scan & Review Queue (`TransactionReviewListView`):** คิวตรวจสอบสลิปที่เพิ่งสแกนพบ ปัดขวาเพื่อยืนยัน ปัดซ้ายเพื่อซ่อนรูปที่ไม่ใช่สลิป หรือแตะเลือกหมวดหมู่ด่วนได้ทันที
   - **Transaction Detail (`TransactionDetailView`):** แสดงรูปภาพสลิปต้นฉบับจาก `PHAsset` (ซูมดูภาพเต็มได้) พร้อมแก้ไขข้อมูลและตรวจสอบข้อความดิบจาก OCR

---

## 🛠 Tech Stack & Architecture

| หมวดหมู่ | เทคโนโลยีที่ใช้ |
| :--- | :--- |
| **Language & Concurrency** | Swift 6 (`async/await`, `actor`, `Sendable`, `@Observable`) |
| **UI Framework** | SwiftUI (Target: **iOS 17.0+**) |
| **Architecture** | MVVM (Model-View-ViewModel) + Service Layer |
| **Local Database** | SwiftData (`@Model`, `@Query`, `ModelContainer` — Offline 100%) |
| **Photo Library** | PhotoKit (`PHAsset`, `PHImageManager`, `PHFetchOptions`) |
| **OCR & QR Engine** | Vision (`VNRecognizeTextRequest` [`th-TH`, `en-US`], `VNDetectBarcodesRequest`) |
| **Data Visualization** | Swift Charts (`SectorMark`, `BarMark`) |
| **CI/CD & Project Gen** | XcodeGen (`project.yml`), GitHub Actions (`macos-15` / Xcode 16) |

---

## 📂 โครงสร้างโปรเจกต์ (Project Structure)

```text
SlipLens/
├── .github/workflows/
│   └── build-unsigned-ipa.yml          # GitHub Actions สร้างไฟล์ .ipa อัตโนมัติบน macOS
├── project.yml                         # ไฟล์ตั้งค่า XcodeGen สำหรับสร้าง SlipLens.xcodeproj
├── SlipLens/
│   ├── Info.plist                      # ตั้งค่าสิทธิ์ NSPhotoLibraryUsageDescription
│   ├── SlipLensApp.swift               # จุดเริ่มต้นแอป (@main), ModelContainer และ TabView
│   ├── Models/
│   │   └── SlipLensModels.swift        # SwiftData Models (TransactionItem, PayeeMappingRule, Enums)
│   ├── Services/
│   │   ├── SlipScannerService.swift    # Vision OCR (ไทย/อังกฤษ), Thai Mini-QR Parser & Regex
│   │   ├── PhotoLibraryService.swift   # ดึงรูปภาพรายเดือนจาก PhotoKit แบบ Async + Progress
│   │   └── CategoryEngine.swift        # ระบบจับคู่ชื่อผู้รับและจัดหมวดหมู่อัตโนมัติ
│   ├── ViewModels/
│   │   └── ExpenseTrackerViewModel.swift # MVVM State, คำนวณยอดรายเดือน และจัดการคิวสแกน
│   └── Views/
│       ├── DashboardView.swift         # หน้าหลัก สรุปยอด + กราฟ Donut/Bar (Swift Charts)
│       ├── ScanProgressView.swift      # แถบสถานะการสแกน และ AssetThumbnailView
│       ├── TransactionReviewListView.swift # คิวตรวจสอบรายการใหม่ (Swipe to Verify / Ignore)
│       └── TransactionDetailView.swift # หน้ารายละเอียด แก้ไขรายการ ดูภาพสลิปเต็ม และจัดการกฎผู้รับ
```

---

## 🚀 วิธีบิลด์และติดตั้งลง iPhone เครื่องจริง

### วิธีที่ 1: ใช้เครื่อง Windows (ไม่ต้องมีเครื่อง Mac และไม่ต้องมีบัญชี Apple Developer $99)

โปรเจกต์นี้ตั้งค่า **GitHub Actions** ไว้ให้คอมไพล์ไฟล์ `.ipa` บนคลาวด์ macOS อัตโนมัติทุกครั้งที่ Push โค้ด:

1. **ดาวน์โหลดไฟล์ `.ipa` จาก GitHub Actions**
   - ไปที่แท็บ **Actions** ของ Repository บน GitHub
   - คลิกที่รันล่าสุดของ **`Build Unsigned iOS IPA (For Sideloadly / AltStore)`**
   - เลื่อนลงมาที่หัวข้อ **Artifacts** แล้วดาวน์โหลด **`SlipLens-Unsigned-IPA`** (แตกไฟล์ `.zip` ออกมาจะได้ `SlipLens-Unsigned.ipa`)

2. **ติดตั้งลง iPhone ด้วย Sideloadly**
   - ติดตั้งโปรแกรม **[Sideloadly](https://sideloadly.io/)** บนเครื่อง Windows
   - เสียบสาย USB เชื่อมต่อ iPhone เข้ากับคอมพิวเตอร์
   - เปิด Sideloadly ลากไฟล์ `SlipLens-Unsigned.ipa` เข้าไป กรอก **Apple ID** ของคุณ แล้วกด **Start**

3. **เปิดสิทธิ์บน iPhone (ทำครั้งแรกครั้งเดียว)**
   - ไปที่ **Settings > General > VPN & Device Management** $\rightarrow$ แตะเลือก Apple ID ของคุณแล้วกด **Trust (เชื่อถือ)**
   - ไปที่ **Settings > Privacy & Security > Developer Mode** $\rightarrow$ เปิดใช้งาน **Developer Mode** แล้วรีสตาร์ทเครื่อง

---

### วิธีที่ 2: เปิดพัฒนาต่อด้วย Xcode บนเครื่อง macOS

1. ติดตั้ง **XcodeGen** (หากยังไม่มี):
   ```bash
   brew install xcodegen
   ```
2. สร้างไฟล์โปรเจกต์ `SlipLens.xcodeproj`:
   ```bash
   xcodegen generate
   open SlipLens.xcodeproj
   ```
3. ใน Xcode ไปที่แท็บ **Signing & Capabilities** เลือก **Team** ของคุณ เสียบสาย iPhone แล้วกด **Run (`Cmd + R`)** ได้ทันที

---

## 🔒 ความเป็นส่วนตัว (Privacy & Security)
- **100% On-Device Processing:** การอ่านข้อความจากสลิปและ QR Code ทั้งหมดทำงานผ่านชิป Neural Engine บนอุปกรณ์ด้วย Apple Vision Framework
- **Zero Cloud Uploads:** รูปภาพสลิปและข้อมูลทางการเงินทั้งหมดถูกเก็บไว้ในฐานข้อมูล `SwiftData` ภายในเครื่องเท่านั้น ไม่มีการส่งข้อมูลออกไปยังเซิร์ฟเวอร์ภายนอก
