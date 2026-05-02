import Foundation

// MARK: - Device Hardware Icon

enum DeviceHardwareIcon {
    /// All SF Symbols available for device icon customization.
    static let allIcons: [(symbol: String, label: String)] = [
        ("macbook", "MacBook"),
        ("macmini", "Mac mini"),
        ("macpro.gen3", "Mac Pro"),
        ("macstudio", "Mac Studio"),
        ("desktopcomputer", "iMac / Desktop"),
        ("display", "Display"),
        ("laptopcomputer", "Laptop"),
        ("server.rack", "Server"),
        ("cpu", "Workstation"),
        ("terminal", "Terminal"),
    ]

    // Apple Silicon Macs use generic "MacXX,YY" identifiers.
    // This table maps known model numbers to device types.
    private static let genericMacMap: [String: String] = [
        "mac16,1": "macmini", "mac16,2": "macmini", "mac16,3": "macmini",
        "mac16,4": "macmini", "mac16,5": "macmini", "mac16,10": "macmini",
        "mac16,11": "macmini", "mac16,12": "macmini",
        "mac16,6": "macbook", "mac16,7": "macbook", "mac16,8": "macbook",
        "mac16,9": "macbook",
        "mac16,13": "macbook", "mac16,14": "macbook", "mac16,15": "macbook",
        "mac16,16": "desktopcomputer", "mac16,17": "desktopcomputer",
        "mac16,20": "macstudio", "mac16,21": "macstudio",
        "mac14,8": "macpro.gen3",
        "mac14,13": "macstudio", "mac14,14": "macstudio",
        "mac14,3": "macmini", "mac14,12": "macmini",
        "mac13,1": "macstudio", "mac13,2": "macstudio",
        "mac14,1": "macmini",
        "mac15,3": "macbook", "mac15,6": "macbook", "mac15,7": "macbook",
        "mac15,8": "macbook", "mac15,9": "macbook", "mac15,10": "macbook",
        "mac15,11": "macbook",
        "mac15,12": "macbook", "mac15,13": "macbook",
        "mac15,4": "desktopcomputer", "mac15,5": "desktopcomputer",
    ]

    static func sfSymbol(for hardwareModel: String?) -> String {
        guard let hw = hardwareModel?.lowercased() else { return "desktopcomputer" }

        if hw.hasPrefix("macbookpro") || hw.hasPrefix("macbookair") || hw.hasPrefix("macbook") {
            return "macbook"
        }
        if hw.hasPrefix("macmini") {
            return "macmini"
        }
        if hw.hasPrefix("macpro") {
            return "macpro.gen3"
        }
        if hw.hasPrefix("imac") {
            return "desktopcomputer"
        }

        if let mapped = genericMacMap[hw] {
            return mapped
        }

        let hostName = (Host.current().localizedName ?? "").lowercased()
        if hostName.contains("macbook") || hostName.contains("laptop") { return "macbook" }
        if hostName.contains("mini") { return "macmini" }
        if hostName.contains("studio") { return "macstudio" }
        if hostName.contains("imac") { return "desktopcomputer" }
        if hostName.contains("pro") && !hostName.contains("book") { return "macpro.gen3" }

        return "desktopcomputer"
    }

    /// Reads the hardware model identifier from sysctl.
    static var localHardwareModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }
}
