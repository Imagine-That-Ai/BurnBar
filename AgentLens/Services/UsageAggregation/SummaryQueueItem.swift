import Foundation

struct SummaryQueueItem: Identifiable {
    let id: String // conversation ID
    let title: String
    enum Status { case pending, processing, done, failed }
    var status: Status
    var provider: String? // set when done

    init(id: String, title: String, status: Status, provider: String?) {
        self.id = id
        self.title = title
        self.status = status
        self.provider = provider
    }
}
