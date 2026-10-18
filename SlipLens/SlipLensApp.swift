import SwiftUI
import SwiftData

@main
public struct SlipLensApp: App {
    private let sharedModelContainer: ModelContainer

    public init() {
        let schema = Schema([
            TransactionItem.self,
            PayeeMappingRule.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            self.sharedModelContainer = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to initialize SwiftData ModelContainer: \(error)")
        }
    }

    public var body: some Scene {
        WindowGroup {
            MainTabContainerView()
        }
        .modelContainer(sharedModelContainer)
    }
}

// MARK: - MainTabContainerView

public struct MainTabContainerView: View {
    @Query private var allTransactions: [TransactionItem]
    @State private var viewModel = ExpenseTrackerViewModel()

    public init() {}

    private var pendingBadgeCount: Int {
        viewModel.pendingReviewTransactions(from: allTransactions).count
    }

    public var body: some View {
        TabView {
            DashboardView(viewModel: viewModel)
                .tabItem {
                    Label("ภาพรวม (Dashboard)", systemImage: "chart.pie.fill")
                }

            TransactionReviewListView(viewModel: viewModel)
                .tabItem {
                    Label("รอตรวจสอบ (Review)", systemImage: "checklist")
                }
                .badge(pendingBadgeCount)

            PayeeRulesListView()
                .tabItem {
                    Label("กฎผู้รับ (Rules)", systemImage: "wand.and.stars")
                }
        }
    }
}
