import Foundation

struct SummaryQueueItem: Identifiable {
    let id: String // conversation ID
    let title: String
    enum Status { case pending, processing, done, failed }
    var status: Status = .pending
    var provider: String? // set when done
}
