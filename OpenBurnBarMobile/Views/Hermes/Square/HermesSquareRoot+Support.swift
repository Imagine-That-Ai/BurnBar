import SwiftUI
import os.log
import OpenBurnBarAssistantModels
import OpenBurnBarMedia
import OpenBurnBarUI
import FirebaseAuth

// MARK: - HermesSquareRoot + Support

enum HermesSquarePendingThreadRoute {
    static func hermesInboxID(for threadID: String?) -> String? {
        HermesSquareAgentsColumnRouting.inboxID(runtime: .hermes, threadID: threadID)
    }

    @MainActor
    static func consumeHermesInboxID() -> String? {
        hermesInboxID(for: AssistantPendingThread.shared.consume(.hermes))
    }

    @MainActor
    static func consumePendingRoute() -> (runtime: AssistantRuntimeID, inboxID: String)? {
        for runtime in AssistantRuntimeID.allCases {
            guard let inboxID = HermesSquareAgentsColumnRouting.inboxID(
                runtime: runtime,
                threadID: AssistantPendingThread.shared.consume(runtime)
            ) else { continue }
            return (runtime, inboxID)
        }
        return nil
    }
}

enum HermesSquareNavigationRetarget {
    static func sequence(
        current: HermesSquareRoot.NavTarget?,
        requested: HermesSquareRoot.NavTarget
    ) -> [HermesSquareRoot.NavTarget?] {
        if current == requested {
            return [nil, requested]
        }
        return [requested]
    }
}

struct HermesSquareCloudSessionDetailView: View {
    let row: CloudConversationSearchRow
    @State private var activityStore = ActivityStore()
    @State private var bodyText: String?
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.title)
                        .font(.title3.bold())
                        .foregroundStyle(DesignSystemColors.textPrimary)
                    HStack(spacing: 8) {
                        if let provider = row.provider {
                            Label(provider, systemImage: "cpu")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(DesignSystemColors.textMuted)
                }

                if let bodyText {
                    Text(bodyText)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(DesignSystemColors.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if let errorText {
                    Text(errorText)
                        .font(.callout)
                        .foregroundStyle(MobileTheme.error)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Opening encrypted session…")
                            .font(.callout)
                            .foregroundStyle(DesignSystemColors.textMuted)
                    }
                }
            }
            .padding(18)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Cloud Session")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                bodyText = try await activityStore.loadCloudConversationBody(for: row)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

extension View {
    /// Medium/large sheet with a scrolling body and a Done button — the shape
    /// every Agents desk overflow sheet uses. Collapses three identical
    /// `NavigationStack` bodies into one place to keep the chrome in step.
    func deskSheet(
        _ title: String,
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> some View
    ) -> some View {
        sheet(isPresented: isPresented) {
            NavigationStack {
                ScrollView {
                    content()
                        .padding(16)
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { isPresented.wrappedValue = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}
