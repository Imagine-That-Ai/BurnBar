import Foundation

/// Static hardware identity for this Mac — the HermesBody `hardware` block.
/// sysctl-sourced; anything unreadable stays nil and renders as an em-dash.
/// The fountains never invent hardware (§6 fountain 7 of the War Room plan).
struct MacHardwareInventory: Sendable, Equatable {
    var hardwareModel: String?
    var chipBrand: String?
    var coresPerformance: Int?
    var coresEfficiency: Int?
    var memBytes: Int64?

    static func probe() -> MacHardwareInventory {
        MacHardwareInventory(
            hardwareModel: sysctlString("hw.model"),
            chipBrand: sysctlString("machdep.cpu.brand_string"),
            coresPerformance: sysctlInteger("hw.perflevel0.physicalcpu").map(Int.init),
            coresEfficiency: sysctlInteger("hw.perflevel1.physicalcpu").map(Int.init),
            memBytes: sysctlInteger("hw.memsize")
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func sysctlInteger(_ name: String) -> Int64? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
        if size == MemoryLayout<Int32>.size {
            var value: Int32 = 0
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return Int64(value)
        }
        if size == MemoryLayout<Int64>.size {
            var value: Int64 = 0
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return value
        }
        return nil
    }
}
