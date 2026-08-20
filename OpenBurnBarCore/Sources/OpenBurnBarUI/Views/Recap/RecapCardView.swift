import SwiftUI
import OpenBurnBarInsights
import OpenBurnBarRecap

/// Picks a card's layout from its resolved size and wraps it in the shared plate.
///
/// Size is the only dispatch axis: the ranker has already decided how much room
/// an insight earns, and the layouts differ enough that the same insight at two
/// sizes genuinely reads differently rather than just being scaled.
public struct RecapCardView: View {

    public let card: RecapCard
    public let columns: Int
    public var onShare: ((RecapCard) -> Void)?

    public init(card: RecapCard, columns: Int, onShare: ((RecapCard) -> Void)? = nil) {
        self.card = card
        self.columns = columns
        self.onShare = onShare
    }

    public var body: some View {
        RecapCardChrome(card: card, onShare: onShare) {
            switch card.size {
            case .hero, .fullBleed:
                RecapHeroCard(card: card)
            case .small:
                RecapTileCard(card: card)
            case .medium, .wide:
                RecapStandardCard(card: card, columns: columns)
            }
        }
    }
}
