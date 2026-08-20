import CoreGraphics
import Foundation

// MARK: - Home space budget
//
// Every bespoke Home shell used to be the same three lines:
//
//     ScrollView { VStack { sections }.padding().frame(maxWidth: 820) }
//
// which produces dead space three different ways at once, and the Ask shell
// showed all three simultaneously on a 1900×950 window:
//
//   1. **Vertical.** A `ScrollView` anchors its content to the top. Three short
//      sections on a tall window leave the bottom 40% blank — not scrollable,
//      not filled, just absent.
//   2. **Horizontal.** `maxWidth: 820` is a *reading* measure, correct for a
//      paragraph and wrong for a composition. On a wide window it parks a
//      single narrow column in the middle of the canvas with air either side.
//   3. **Frozen density.** `prefix(6)` truncates the list regardless of how much
//      room exists, so even after fixing (1) and (2) there would be nothing
//      real to put in the recovered space.
//
// The fix cannot be "add a `Spacer`" or "stretch the last card". Both fill the
// hole with *air wearing a card's clothes*, which is the same dead zone with a
// border around it. Space has to be filled with **more of the truth** — more
// rows, more history, more of the ranking that was being truncated — and only
// what is left over after that gets distributed as breathing room.
//
// So a shell no longer hard-codes a stack. It declares what it wants (`LivingSlot`)
// and the canvas answers how much it gets (`LivingSpacePlan`). The resolution is
// pure arithmetic on values, which is deliberate and matches
// `DashboardHomeRailMetrics`: layout rules that live in `static func`s can be
// pinned by a test without mounting a window, and every rule below has one.
//
// The three passes, in order, and the order is the design:
//
//   * **Fit** — can every slot have its floor? If not, the surface scrolls, and
//      nothing is silently thrown away.
//   * **Feed** — spend the slack on real rows, round-robin across slots so one
//      hungry ladder cannot eat the budget before its neighbour gets a line.
//   * **Breathe** — only what survives Feed becomes space, handed to the slots
//      that asked to stretch (or spread proportionally when none did).
//
// Feed before Breathe is the whole thesis. A dashboard with room should answer
// more questions, not the same questions in a larger font.

// MARK: - Slot

/// One region a shell asks the canvas for.
///
/// A slot describes *appetite*, never geometry: what it cannot go below, what it
/// would like, how many more rows it could honestly fill, and how willing it is
/// to absorb leftover height. The canvas decides the numbers.
public struct LivingSlot: Equatable, Sendable, Identifiable {

    /// How much more real content a slot could show if the canvas can afford it.
    ///
    /// This is what makes "no dead space" honest rather than cosmetic. A slot
    /// with an appetite grows by revealing rows that already exist in the data
    /// and were being truncated; a slot without one grows by stretching, which
    /// is the weaker answer and therefore the second pass.
    public struct RowAppetite: Equatable, Sendable {
        /// Rows the data actually has. The hard ceiling — a slot can never be
        /// fed a row that does not exist, which is what stops "fill the space"
        /// from turning into "invent filler".
        public let available: Int
        /// Rows shown before any slack is spent. Part of the slot's floor.
        public let baseline: Int
        /// Height one row costs, including its rule.
        public let unit: CGFloat
        /// The most rows worth showing here even on an enormous canvas.
        ///
        /// A ceiling exists because past a point a list stops being a glance and
        /// becomes a different surface — at which point the honest move is to
        /// send the user to the full inbox, not to print 400 rows on Home.
        public let ceiling: Int

        public init(available: Int, baseline: Int, unit: CGFloat, ceiling: Int) {
            self.available = max(0, available)
            self.baseline = max(0, min(baseline, max(0, available)))
            self.unit = max(1, unit)
            self.ceiling = max(0, ceiling)
        }

        /// The most rows this appetite can ever resolve to.
        public var cap: Int { min(available, ceiling) }
    }

    public let id: String
    /// Feeding order. Lower is fed first, so the slot carrying the shell's
    /// thesis gets its rows before a supporting ladder gets its own.
    public let rank: Int
    /// Height at `RowAppetite.baseline` rows. Never goes below this.
    public let floor: CGFloat
    /// Height this slot would choose if nothing were competing. Used as the
    /// weight when residual space has to be spread with no stretch declared,
    /// and as the balance metric when dealing slots into columns.
    public let ideal: CGFloat
    /// Share of post-Feed slack, relative to its siblings. `0` is rigid.
    public let stretch: Double
    /// More rows this slot could honestly show. `nil` for a slot whose content
    /// is not a list — a headline, a field, a gauge cluster.
    public let rows: RowAppetite?
    /// Whether the slot may be withheld entirely on a canvas too short for it.
    ///
    /// True only for genuinely ambient furniture (an activity ribbon). Content
    /// is never optional: a short window makes the surface scroll, it does not
    /// make an item disappear.
    public let isAmbient: Bool
    /// Whether the slot keeps the full canvas width, above any column region.
    ///
    /// Ask's question field is the case that forces this to exist: its enforced
    /// rule is that the field is the first *and largest* element, and a
    /// two-column deal would drop it into a half-width box beside a list. A
    /// spanning slot is rigid at its `ideal` — slack belongs to the columns
    /// below, because stretching a header band is the "air wearing a card's
    /// clothes" move this whole file rejects.
    public let spans: Bool

    public init(
        id: String,
        rank: Int,
        floor: CGFloat,
        ideal: CGFloat? = nil,
        stretch: Double = 0,
        rows: RowAppetite? = nil,
        isAmbient: Bool = false,
        spans: Bool = false
    ) {
        self.id = id
        self.rank = rank
        self.floor = max(0, floor)
        self.ideal = max(max(0, floor), ideal ?? floor)
        self.stretch = max(0, stretch)
        self.rows = rows
        self.isAmbient = isAmbient
        self.spans = spans
    }
}

// MARK: - Plan

/// What the canvas granted, ready to be rendered without further arithmetic.
public struct LivingSpacePlan: Equatable, Sendable {

    /// One slot's resolved geometry.
    public struct Placement: Equatable, Sendable, Identifiable {
        public let id: String
        /// Resolved height. `nil` when the surface overflows and the slot should
        /// simply hug its content inside the scroll view — pinning a height in
        /// that state would clip text that has nowhere else to go.
        public let height: CGFloat?
        /// How many rows to render. `0` for slots with no `RowAppetite`.
        public let rowCount: Int
        /// Which column the slot was dealt into, `0`-based.
        public let column: Int
        /// Whether the slot survived the Fit pass. Only ambient furniture is ever
        /// withheld; content always survives, and a short canvas scrolls instead.
        public let isVisible: Bool
    }

    public let placements: [Placement]
    /// How many columns the composition reflowed into.
    public let columns: Int
    /// True when even the floors do not fit, so the shell must scroll.
    ///
    /// The shell reads this rather than always scrolling: a `ScrollView` that
    /// never scrolls is exactly the top-anchored container that leaves the hole.
    public let overflows: Bool
    /// Slot ids that keep the full width, in declared order, above the columns.
    public let spanningIDs: [String]

    public func placement(_ id: String) -> Placement? {
        placements.first { $0.id == id }
    }

    /// Rows granted to a slot, or its baseline when the plan has nothing to say
    /// about it — so a caller can read this unconditionally.
    public func rowCount(_ id: String, fallback: Int = 0) -> Int {
        placement(id)?.rowCount ?? fallback
    }

    /// Resolved height, or `nil` when the slot is absent or hugging its content.
    ///
    /// Written out rather than as `placement(id)?.height` because that chains to
    /// a doubly-wrapped `CGFloat??`, and flattening it at every call site is how
    /// "no height" and "no slot" end up meaning the same thing by accident.
    public func height(_ id: String) -> CGFloat? {
        guard let placement = placement(id) else { return nil }
        return placement.height
    }

    /// Whether a slot should be rendered at all.
    public func isVisible(_ id: String) -> Bool {
        placement(id)?.isVisible ?? true
    }

    /// Slot ids in each column, in visual order, withheld ones excluded. The
    /// shape a shell renders from.
    public var columnGroups: [[String]] {
        guard columns > 0 else { return [] }
        let spanning = Set(spanningIDs)
        return (0..<columns).map { column in
            placements
                .filter { $0.column == column && $0.isVisible && spanning.contains($0.id) == false }
                .map(\.id)
        }
    }

    /// Visible spanning slots, in declared order.
    public var visibleSpanningIDs: [String] {
        spanningIDs.filter { isVisible($0) }
    }

    public static let empty = LivingSpacePlan(placements: [], columns: 1, overflows: false, spanningIDs: [])
}

// MARK: - Budget

/// Resolves slot appetite against a canvas.
///
/// Every rule is a `static func` on purpose — the same reason
/// `DashboardHomeRailMetrics` is one. Layout arithmetic that can only be
/// exercised by mounting a window is layout arithmetic that never gets tested.
public enum LivingSpaceBudget {

    // MARK: Columns

    /// Width at which a composition earns a second column.
    ///
    /// Set from the reading measure, not from a device: two columns are worth it
    /// once each can still hold a comfortable line of text plus the gutter. Below
    /// that, a second column makes two cramped columns out of one good one.
    public static let twoColumnWidth: CGFloat = 1_080
    /// Width at which a third column earns its place.
    public static let threeColumnWidth: CGFloat = 1_580
    /// Hysteresis either side of a threshold.
    ///
    /// A `GeometryReader` reports sub-pixel changes while a divider is dragged,
    /// and a hard cutoff makes the composition snap back and forth between one
    /// and two columns. Identical in shape and intent to the rail's dead bands.
    public static let columnDeadBand: CGFloat = 60

    /// How many columns this width supports, holding the current count inside the
    /// dead band so a drag across a threshold cannot flicker.
    ///
    /// `slots` caps the answer: three columns for two slots is one empty column,
    /// which is the dead space this whole file exists to remove.
    public static func columns(forWidth width: CGFloat, current: Int, slots: Int) -> Int {
        // The first layout pass can report zero before the window has a frame.
        guard width > 0 else { return max(1, min(current, max(1, slots))) }

        let ceiling = max(1, min(3, slots))
        let target: Int
        if width >= threeColumnWidth + columnDeadBand {
            target = 3
        } else if width <= threeColumnWidth - columnDeadBand {
            if width >= twoColumnWidth + columnDeadBand {
                target = 2
            } else if width <= twoColumnWidth - columnDeadBand {
                target = 1
            } else {
                // Inside the 1↔2 dead band: hold whatever we already were.
                target = min(max(current, 1), 2)
            }
        } else {
            // Inside the 2↔3 dead band: hold, but never below two — we are past
            // the two-column threshold by definition here.
            target = min(max(current, 2), 3)
        }
        return min(target, ceiling)
    }

    // MARK: Resolution

    /// Resolves slots against a canvas.
    ///
    /// - Parameters:
    ///   - canvas: The space the shell was handed.
    ///   - slots: Every region the shell wants, in visual order.
    ///   - gutter: Spacing between stacked slots.
    ///   - columns: Column count, normally from `columns(forWidth:current:slots:)`.
    ///     Passed in rather than derived so the caller owns the hysteresis state.
    public static func resolve(
        canvas: CGSize,
        slots: [LivingSlot],
        gutter: CGFloat,
        columns requestedColumns: Int = 1
    ) -> LivingSpacePlan {
        guard slots.isEmpty == false else { return .empty }

        // A spanning band only means something once there are columns to span.
        // In one column every slot is already full width, so treating them as
        // spanning would only make them rigid for no reason.
        let requested = max(1, requestedColumns)
        let spanning = requested > 1 ? slots.filter(\.spans) : []
        let columnar = requested > 1 ? slots.filter { $0.spans == false } : slots
        let spanningIDs = spanning.map(\.id)

        let columnCount = max(1, min(requested, max(1, columnar.count)))
        let assignment = deal(slots: columnar, into: columnCount)

        // A canvas with no height yet (first layout pass) resolves to the
        // scrolling arm: hug content, grant baselines, decide nothing.
        guard canvas.height > 0 else {
            return LivingSpacePlan(
                placements: slots.map { slot in
                    LivingSpacePlan.Placement(
                        id: slot.id,
                        height: nil,
                        rowCount: slot.rows?.baseline ?? 0,
                        column: assignment[slot.id] ?? 0,
                        isVisible: true
                    )
                },
                columns: columnCount,
                overflows: true,
                spanningIDs: spanningIDs
            )
        }

        var placements: [LivingSpacePlan.Placement] = []
        var anyColumnOverflows = false

        // The spanning band is rigid at `ideal`, and what it leaves is the
        // column region's whole budget.
        let bandHeight = spanning.reduce(0) { $0 + $1.ideal }
            + gutter * CGFloat(spanning.count)
        let columnHeight = canvas.height - bandHeight

        for slot in spanning {
            placements.append(
                LivingSpacePlan.Placement(
                    id: slot.id,
                    height: slot.ideal,
                    rowCount: slot.rows?.baseline ?? 0,
                    column: 0,
                    isVisible: true
                )
            )
        }

        for column in 0..<columnCount {
            let members = columnar.filter { assignment[$0.id] == column }
            guard members.isEmpty == false else { continue }
            let resolved = resolveColumn(members, height: columnHeight, gutter: gutter)
            anyColumnOverflows = anyColumnOverflows || resolved.overflows
            placements.append(contentsOf: resolved.placements.map {
                LivingSpacePlan.Placement(
                    id: $0.id,
                    height: $0.height,
                    rowCount: $0.rowCount,
                    column: column,
                    isVisible: $0.isVisible
                )
            })
        }

        // One column overflowing puts the whole surface in the scrolling arm.
        // Mixing a pinned column beside a scrolling one means two scroll origins
        // on one page, and the user cannot tell which one their wheel is driving.
        if anyColumnOverflows {
            placements = placements.map {
                LivingSpacePlan.Placement(
                    id: $0.id,
                    height: nil,
                    rowCount: $0.rowCount,
                    column: $0.column,
                    isVisible: $0.isVisible
                )
            }
        }

        // Restore the shell's declared order; `filter` per column scrambled it.
        let order = Dictionary(uniqueKeysWithValues: slots.enumerated().map { ($0.element.id, $0.offset) })
        placements.sort { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }

        return LivingSpacePlan(
            placements: placements,
            columns: columnCount,
            overflows: anyColumnOverflows,
            spanningIDs: spanningIDs
        )
    }

    // MARK: Column resolution

    private struct ColumnResult {
        let placements: [(id: String, height: CGFloat?, rowCount: Int, isVisible: Bool)]
        let overflows: Bool
    }

    /// The three passes — Fit, Feed, Breathe — against one column's height.
    private static func resolveColumn(
        _ slots: [LivingSlot],
        height: CGFloat,
        gutter: CGFloat
    ) -> ColumnResult {
        var kept = slots
        var chrome = gutter * CGFloat(max(0, kept.count - 1))
        var floors = kept.reduce(0) { $0 + $1.floor }

        // Fit — ambient furniture yields first, then we admit overflow rather
        // than dropping content. Withholding an item because the window is short
        // would make Home lie about what is in the inbox.
        while floors + chrome > height, kept.contains(where: \.isAmbient) {
            guard let victim = kept.lastIndex(where: \.isAmbient) else { break }
            floors -= kept[victim].floor
            kept.remove(at: victim)
            chrome = gutter * CGFloat(max(0, kept.count - 1))
        }

        let keptIDs = Set(kept.map(\.id))
        let withheld = slots.filter { keptIDs.contains($0.id) == false }

        guard floors + chrome <= height else {
            // Overflow: hug content, grant baselines, let the shell scroll. The
            // scroll bar is honest here — there genuinely is more than fits.
            // Ambient furniture stays withheld; it lost the Fit pass on a canvas
            // that has since proved even tighter.
            return ColumnResult(
                placements: kept.map { ($0.id, nil, $0.rows?.baseline ?? 0, true) }
                    + withheld.map { ($0.id, CGFloat(0), 0, false) },
                overflows: true
            )
        }

        var slack = height - floors - chrome
        var rowCounts = Dictionary(uniqueKeysWithValues: kept.map { ($0.id, $0.rows?.baseline ?? 0) })

        // Feed — round-robin in rank order. One row each per lap, so a six-row
        // ladder cannot swallow the budget before a two-row ladder sees a line.
        let feeding = kept.filter { $0.rows != nil }.sorted { $0.rank < $1.rank }
        var fed = true
        while slack > 0, fed {
            fed = false
            for slot in feeding {
                guard let appetite = slot.rows else { continue }
                guard let current = rowCounts[slot.id], current < appetite.cap else { continue }
                guard slack >= appetite.unit else { continue }
                rowCounts[slot.id] = current + 1
                slack -= appetite.unit
                fed = true
            }
        }

        // Breathe — whatever Feed could not use becomes space.
        let totalStretch = kept.reduce(0) { $0 + $1.stretch }
        let totalIdeal = kept.reduce(0) { $0 + $1.ideal }

        var placements: [(id: String, height: CGFloat?, rowCount: Int, isVisible: Bool)] = []
        for slot in kept {
            let bought = (rowCounts[slot.id] ?? 0) - (slot.rows?.baseline ?? 0)
            let earned = CGFloat(bought) * (slot.rows?.unit ?? 0)
            let share: CGFloat
            if totalStretch > 0 {
                share = slack * CGFloat(slot.stretch / totalStretch)
            } else if totalIdeal > 0 {
                // Nobody asked to stretch, but the space exists and has to go
                // somewhere or it is the hole again. Spreading it in proportion
                // to `ideal` scales the composition up while preserving the
                // relative weights the shell designed.
                share = slack * (slot.ideal / totalIdeal)
            } else {
                share = slack / CGFloat(kept.count)
            }
            placements.append((slot.id, slot.floor + earned + share, rowCounts[slot.id] ?? 0, true))
        }

        // Withheld ambient slots still report, so a caller can ask about any id
        // it declared without branching on whether it survived the Fit pass.
        for slot in withheld {
            placements.append((slot.id, 0, 0, false))
        }

        return ColumnResult(placements: placements, overflows: false)
    }

    // MARK: Column dealing

    /// Deals slots into columns, balancing by `ideal` height.
    ///
    /// Rank order into the currently shortest column: the shell's most important
    /// slot lands in column 0, and the rest fill the gaps rather than stacking
    /// one tall column beside one stubby one. Ties go left so the arrangement is
    /// deterministic — a layout that reshuffles on identical input reads as a bug.
    public static func deal(slots: [LivingSlot], into columns: Int) -> [String: Int] {
        guard columns > 1 else {
            return Dictionary(uniqueKeysWithValues: slots.map { ($0.id, 0) })
        }

        var loads = [CGFloat](repeating: 0, count: columns)
        var assignment: [String: Int] = [:]

        for slot in slots.sorted(by: { $0.rank < $1.rank }) {
            var target = 0
            for column in 1..<columns where loads[column] < loads[target] - 0.5 {
                target = column
            }
            assignment[slot.id] = target
            loads[target] += slot.ideal
        }
        return assignment
    }
}
