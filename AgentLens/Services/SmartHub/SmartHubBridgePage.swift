import Foundation

// MARK: - Smart Hub Bridge — Static Page
//
// The HTML the Nest Hub renders. Polls /state.json every 5s and re-renders
// when the server-bumped `version` increments. Designed for the 10"
// Nest Hub Max (1024×600) and 7" Nest Hub (1024×600 effective): horizontal
// row of glass provider cards, each showing token total, multi-bucket
// usage bars, account chips, and a runs+spend footer.
//
// The dashboard is data-driven: each card is built from the JSON the
// bridge emits in `SmartHubBridgeServer.providerJSON(_:)`. New providers
// drop in automatically without HTML edits as long as their card payload
// follows the same shape.

enum SmartHubBridgePage {

    static let html: String = [
        htmlDocumentStart,
        htmlBaseStyles,
        htmlLayoutStyles,
        htmlBodyMarkup,
        htmlRuntimeScript,
        htmlCardScript,
        htmlInteractionScript,
        htmlDisplayScript,
        htmlDocumentEnd
    ].joined(separator: "\n")
}
