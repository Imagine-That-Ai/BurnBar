import Foundation
import WidgetKit
import OpenBurnBarCore

struct BurnBarEntry: TimelineEntry {
    let date: Date
    let snapshot: BurnBarWidgetSnapshot?

    init(date: Date, snapshot: BurnBarWidgetSnapshot? = nil) {
        self.date = date
        self.snapshot = snapshot
    }
}
