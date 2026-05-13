import SwiftUI

public struct InsightFocusMatrixView: View {
    public let data: InsightWidgetData.FocusMatrix
    public init(data: InsightWidgetData.FocusMatrix) { self.data = data }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            ForEach(Array(data.rowLabels.enumerated()), id: \.offset) { rIdx, label in
                HStack(spacing: 2) {
                    Text(label)
                        .font(UnifiedDesignSystem.Typography.tiny)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 96, alignment: .trailing)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    HStack(spacing: 2) {
                        ForEach(Array(data.columnLabels.enumerated()), id: \.offset) { cIdx, _ in
                            let v = rIdx < data.cells.count && cIdx < data.cells[rIdx].count
                                ? data.cells[rIdx][cIdx] : 0
                            cell(value: v)
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 2) {
            Color.clear.frame(width: 96)
            HStack(spacing: 2) {
                ForEach(data.columnLabels, id: \.self) { label in
                    Text(label)
                        .font(UnifiedDesignSystem.Typography.tiny)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func cell(value: Double) -> some View {
        let intensity = max(0, min(1, value))
        return ZStack {
            Rectangle()
                .fill(UnifiedDesignSystem.Colors.whimsy.opacity(0.10 + intensity * 0.7))
            if intensity > 0.05 {
                Text(String(format: "%.0f", intensity * 100))
                    .font(UnifiedDesignSystem.Typography.tiny)
                    .foregroundStyle(intensity > 0.5 ? .white : UnifiedDesignSystem.Colors.textSecondary)
            }
        }
        .frame(height: 24)
        .cornerRadius(2)
        .frame(maxWidth: .infinity)
    }
}
