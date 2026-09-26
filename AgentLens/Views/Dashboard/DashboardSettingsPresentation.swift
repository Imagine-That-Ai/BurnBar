import Observation

@MainActor
@Observable
final class DashboardSettingsPresentation {
    var isPresented = false
    private(set) var itemID: String?

    func present(itemID: String? = nil) {
        self.itemID = itemID
        isPresented = true
    }

    func dismiss() {
        isPresented = false
        itemID = nil
    }
}
