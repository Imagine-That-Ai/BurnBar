import Foundation

extension BurnBarProjectCodeMemoryStore.SQLiteRow {
    func optionalString(_ index: Int) -> String? {
        guard values.indices.contains(index) else { return nil }
        return values[index]
    }

    func string(_ index: Int) -> String {
        optionalString(index) ?? ""
    }

    func int64(_ index: Int) -> Int64 {
        Int64(string(index)) ?? 0
    }

    func double(_ index: Int) -> Double {
        Double(string(index)) ?? 0
    }

    func optionalDouble(_ index: Int) -> Double? {
        optionalString(index).flatMap(Double.init)
    }
}
