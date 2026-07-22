// ActivityKit's `ActivityAttributes` protocol is unavailable on macOS, so this
// type is only compiled for platforms that support Live Activities.
#if os(iOS)
import ActivityKit
import Foundation

@available(iOS 16.1, *)
public struct BurnBarLiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var heroCost: Double
        public var heroTokens: Int
        public var topProvider: String
        public var sessionActive: Bool

        public init(heroCost: Double, heroTokens: Int, topProvider: String, sessionActive: Bool) {
            self.heroCost = heroCost
            self.heroTokens = heroTokens
            self.topProvider = topProvider
            self.sessionActive = sessionActive
        }
    }

    public var heroTitle: String

    public init(heroTitle: String) {
        self.heroTitle = heroTitle
    }
}
#endif
