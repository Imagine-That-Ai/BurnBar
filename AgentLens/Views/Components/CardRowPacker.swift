import OpenBurnBarUI

// The packer moved to `OpenBurnBarUI` when the monthly recap deck needed the
// same rule on iOS. This alias keeps every existing macOS call site — the
// Charts grid, the Control Deck grid, and `CardRowPackerTests` — compiling
// against the same name, with one implementation behind it.
typealias CardRowPacker = OpenBurnBarUI.CardRowPacker
