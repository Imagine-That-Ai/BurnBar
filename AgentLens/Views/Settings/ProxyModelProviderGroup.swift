import OpenBurnBarCore

struct ProxyModelProviderGroup: Identifiable {
    let providerID: String
    let providerName: String
    let models: [ProxyAdvertisedModel]

    var id: String { providerID }
}
