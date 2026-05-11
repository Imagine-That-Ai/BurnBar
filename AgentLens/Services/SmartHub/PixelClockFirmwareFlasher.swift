import Darwin
import CoreWLAN
import Foundation
import OpenBurnBarCore

struct PixelClockFirmwareFlasher {
    struct FlashResult: Equatable, Sendable {
        let serialDevice: String
        let firmwareVersion: String
        let setupSSID: String?
    }

    struct SerialDiagnostics: Equatable, Sendable {
        let clockCandidateDevices: [String]
        let ignoredSerialDevices: [String]

        var hasClockCandidate: Bool {
            !clockCandidateDevices.isEmpty
        }

        var setupGuidance: String {
            if hasClockCandidate {
                return "OpenBurnBar found a Pixel Clock USB setup port."
            }
            if ignoredSerialDevices.isEmpty {
                return "No Pixel Clock USB data connection is visible. The TC001 battery or blue indicator can light even when the Mac only has power, not data. Use a data-capable USB cable connected directly to the Mac, put the clock on Wi-Fi, or reboot it until the AWTRIX setup Wi-Fi appears."
            }
            let names = ignoredSerialDevices
                .map { URL(fileURLWithPath: $0).lastPathComponent }
                .joined(separator: ", ")
            return "USB is connected, but only non-clock serial devices were visible (\(names)). Connect the ULANZI clock with a data-capable USB cable directly to the Mac, or use the AWTRIX setup Wi-Fi path."
        }
    }

    enum FlashError: LocalizedError, Equatable {
        case noSerialDevice
        case missingFirmware
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .noSerialDevice:
                return "No USB serial Pixel Clock was found. The TC001 can show power from its battery or charge line without exposing USB data. Use a data-capable USB cable connected directly to the Mac and reconnect the clock."
            case .missingFirmware:
                return "Could not find the ULANZI TC001 AWTRIX firmware in the latest release."
            case .commandFailed(let message):
                return message
            }
        }
    }

    func flash() async throws -> FlashResult {
        try await Self.ensureEsptool()
        guard let serialDevice = try await Self.validatedSerialDevices().first else {
            throw FlashError.noSerialDevice
        }
        let firmware = try await Self.downloadOfficialFirmware()
        var writeArguments = [
            "-m", "esptool",
            "--chip", "esp32",
            "--port", serialDevice,
            // TC001 USB serial drops mid-write on some Macs at 460800.
            // 230400 is still fast enough for one-click setup and was stable
            // on the physical recovery path that originally exposed this bug.
            "--baud", "230400",
            "--before", "default_reset",
            "--after", "hard_reset",
            "write_flash"
        ]
        for part in firmware.parts {
            writeArguments.append(String(format: "0x%x", part.offset))
            writeArguments.append(part.localURL.path)
        }
        let writeOutput = try await Self.run(
            "/usr/bin/python3",
            writeArguments,
            timeout: 180
        )
        return FlashResult(
            serialDevice: serialDevice,
            firmwareVersion: firmware.version,
            setupSSID: Self.awtrixSetupSSID(fromEsptoolOutput: writeOutput)
        )
    }

    func hasSetupCandidateSerialDevice() async -> Bool {
        await Self.hasSetupCandidateSerialDevice()
    }

    func serialDiagnostics() async -> SerialDiagnostics {
        await Self.serialDiagnostics()
    }

    static func hasSetupCandidateSerialDevice() async -> Bool {
        let registry = (try? await run("/usr/sbin/ioreg", ["-p", "IOUSB", "-l", "-w", "0"], timeout: 5)) ?? ""
        return !setupCandidateSerialDevices(usbRegistry: registry).isEmpty
    }

    static func serialDiagnostics() async -> SerialDiagnostics {
        let registry = (try? await run("/usr/sbin/ioreg", ["-p", "IOUSB", "-l", "-w", "0"], timeout: 5)) ?? ""
        return serialDiagnostics(
            serialDevices: serialDeviceCandidates(),
            usbRegistry: registry
        )
    }

    static func serialDiagnostics(
        serialDevices: [String],
        usbRegistry: String
    ) -> SerialDiagnostics {
        let visibleDevices = serialDevices
            .filter { $0.lowercased().hasPrefix("/dev/cu.") }
            .filter {
                let lower = $0.lowercased()
                return !lower.contains("bluetooth") && !lower.contains("debug-console")
            }
            .sorted()
        let clockDevices = visibleDevices
            .filter { shouldTrySerialDevice($0, usbRegistry: usbRegistry) }
        let ignored = visibleDevices
            .filter { !clockDevices.contains($0) }
        return SerialDiagnostics(
            clockCandidateDevices: clockDevices,
            ignoredSerialDevices: ignored
        )
    }

    static func setupCandidateSerialDevices(usbRegistry: String) -> [String] {
        serialDeviceCandidates()
            .filter { shouldTrySerialDevice($0, usbRegistry: usbRegistry) }
    }

    private static func validatedSerialDevices() async throws -> [String] {
        let registry = (try? await run("/usr/sbin/ioreg", ["-p", "IOUSB", "-l", "-w", "0"], timeout: 5)) ?? ""
        var devices: [String] = []
        for serialDevice in setupCandidateSerialDevices(usbRegistry: registry) {
            if await isESP32SerialDevice(serialDevice) {
                devices.append(serialDevice)
            }
        }
        return devices
    }

    private static func serialDeviceCandidates() -> [String] {
        ["/dev/cu.usbserial*", "/dev/cu.wchusbserial*", "/dev/cu.SLAB_USBtoUART*", "/dev/cu.usbmodem*"]
            .flatMap(glob)
            .sorted()
    }

    static func shouldTrySerialDevice(_ path: String, usbRegistry: String) -> Bool {
        let lowerPath = path.lowercased()
        guard lowerPath.hasPrefix("/dev/cu.") else { return false }
        guard !lowerPath.contains("bluetooth"), !lowerPath.contains("debug-console") else { return false }

        if lowerPath.contains("usbserial")
            || lowerPath.contains("wchusbserial")
            || lowerPath.contains("slab_usbtouart") {
            return true
        }

        guard lowerPath.contains("usbmodem") else { return false }
        let context = usbRegistryContext(for: path, in: usbRegistry).lowercased()
        guard !context.isEmpty else { return false }

        let knownNonClockMarkers = [
            "android",
            "samsung",
            "iphone",
            "ipad",
            "adb",
            "mtp",
            "google"
        ]
        if knownNonClockMarkers.contains(where: context.contains) {
            return false
        }

        let espSerialMarkers = [
            "espressif",
            "esp32",
            "usb jtag",
            "serial",
            "uart",
            "cp210",
            "ch340",
            "wch"
        ]
        return espSerialMarkers.contains(where: context.contains)
    }

    private static func isESP32SerialDevice(_ path: String) async -> Bool {
        do {
            let output = try await run(
                "/usr/bin/python3",
                [
                    "-m", "esptool",
                    "--port", path,
                    "--baud", "115200",
                    "--before", "default_reset",
                    "--after", "no_reset",
                    "chip_id"
                ],
                timeout: 10
            )
            let lowerOutput = output.lowercased()
            return lowerOutput.contains("chip is esp32")
                || lowerOutput.contains("detecting chip type... esp32")
                || lowerOutput.contains("mac:")
        } catch {
            return false
        }
    }

    private static func usbRegistryContext(for path: String, in registry: String) -> String {
        let basename = URL(fileURLWithPath: path).lastPathComponent
        let modemSuffix = basename
            .replacingOccurrences(of: "cu.usbmodem", with: "")
            .replacingOccurrences(of: "tty.usbmodem", with: "")
            .replacingOccurrences(of: "usbmodem", with: "")
        var needles = Set([basename, modemSuffix])
        var trimmedSuffix = modemSuffix
        while trimmedSuffix.count > 1, trimmedSuffix.last?.isNumber == true {
            trimmedSuffix.removeLast()
            needles.insert(trimmedSuffix)
        }
        let normalizedNeedles = needles
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }

        for context in usbRegistryDeviceContexts(from: registry) {
            let lowerContext = context.lowercased()
            if normalizedNeedles.contains(where: lowerContext.contains) {
                return context
            }
        }
        return ""
    }

    private static func usbRegistryDeviceContexts(from registry: String) -> [String] {
        var contexts: [String] = []
        var currentLines: [Substring] = []

        for line in registry.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let startsDevice = trimmed.hasPrefix("+-o ") || trimmed.hasPrefix("| +-o ")
            if startsDevice, !currentLines.isEmpty {
                contexts.append(currentLines.joined(separator: "\n"))
                currentLines = [line]
            } else {
                currentLines.append(line)
            }
        }

        if !currentLines.isEmpty {
            contexts.append(currentLines.joined(separator: "\n"))
        }

        return contexts.isEmpty ? [registry] : contexts
    }

    private static func glob(_ pattern: String) -> [String] {
        var result = glob_t()
        defer { globfree(&result) }
        guard Darwin.glob(pattern, 0, nil, &result) == 0, let paths = result.gl_pathv else { return [] }
        return (0..<Int(result.gl_pathc)).compactMap { index in
            guard let path = paths[index] else { return nil }
            return String(cString: path)
        }
    }

    private static func downloadOfficialFirmware() async throws -> (version: String, parts: [FirmwarePart]) {
        let baseURL = URL(string: "https://raw.githubusercontent.com/Blueforcer/awtrix3/main/docs/ulanzi_flasher/firmware/")!
        let manifestURL = baseURL.appendingPathComponent("manifest.json")
        let (data, response) = try await URLSession.shared.data(from: manifestURL)
        try validateHTTP(response)
        let manifest = try JSONDecoder().decode(FirmwareManifest.self, from: data)
        guard let build = manifest.builds.first(where: { $0.chipFamily.uppercased() == "ESP32" }) else {
            throw FlashError.missingFirmware
        }
        let directory = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenBurnBar/PixelClockFirmware/official-ulanzi-\(manifest.version)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var parts: [FirmwarePart] = []
        for part in build.parts {
            let localURL = directory.appendingPathComponent(part.path)
            if !FileManager.default.fileExists(atPath: localURL.path) {
                let remoteURL = baseURL.appendingPathComponent(part.path)
                let (firmwareData, firmwareResponse) = try await URLSession.shared.data(from: remoteURL)
                try validateHTTP(firmwareResponse)
                try firmwareData.write(to: localURL, options: .atomic)
            }
            parts.append(FirmwarePart(offset: part.offset, localURL: localURL))
        }
        return (manifest.version, parts.sorted { $0.offset < $1.offset })
    }

    private static func ensureEsptool() async throws {
        if (try? await run("/usr/bin/python3", ["-m", "esptool", "version"], timeout: 15)) != nil { return }
        _ = try await run("/usr/bin/python3", ["-m", "pip", "install", "--user", "esptool"], timeout: 120)
        _ = try await run("/usr/bin/python3", ["-m", "esptool", "version"], timeout: 15)
    }

    private static func awtrixSetupSSID(fromEsptoolOutput output: String) -> String? {
        guard let match = output.range(of: #"MAC:\s*([0-9a-fA-F:]{17})"#, options: .regularExpression) else {
            return nil
        }
        let macLine = String(output[match])
        guard let mac = macLine.split(separator: " ").last else { return nil }
        let parts = mac.split(separator: ":")
        guard parts.count == 6 else { return nil }
        return "awtrix_" + parts.suffix(3).joined().lowercased()
    }

    private static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                usleep(100_000)
            }
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                let message = [output, error].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                throw FlashError.commandFailed(message.isEmpty ? "\(executable) failed." : message)
            }
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }

    private static func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FlashError.commandFailed("Firmware download failed.")
        }
    }

    private struct FirmwarePart {
        let offset: Int
        let localURL: URL
    }

    private struct FirmwareManifest: Decodable {
        let version: String
        let builds: [FirmwareBuild]
    }

    private struct FirmwareBuild: Decodable {
        let chipFamily: String
        let parts: [FirmwareManifestPart]
        enum CodingKeys: String, CodingKey {
            case chipFamily
            case parts
        }
    }

    private struct FirmwareManifestPart: Decodable {
        let path: String
        let offset: Int
    }
}

struct PixelClockNetworkProvisioner {
    enum ProvisionError: LocalizedError {
        case missingSetupSSID
        case joinFailed(String)
        case connectFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingSetupSSID:
                return "AWTRIX flashed, but OpenBurnBar could not determine the clock setup Wi-Fi name."
            case .joinFailed(let ssid):
                return "AWTRIX flashed, but the setup network \(ssid) was not visible. Reboot the clock while it is plugged in, then run Finish Setup again."
            case .connectFailed(let message):
                return message
            }
        }
    }

    let setupSSID: String?
    let setupPassword = "12345678"

    func provision(credentials: PixelClockWiFiCredentials) async throws -> String {
        guard let setupSSID else { throw ProvisionError.missingSetupSSID }
        let originalSSID = Self.currentWiFiSSID()

        do {
            try await Self.join(ssid: setupSSID, password: setupPassword)
        } catch {
            throw ProvisionError.joinFailed(setupSSID)
        }

        try await Self.waitForSetupPortal()
        let ip = try await Self.postWiFi(credentials)

        if let originalSSID, originalSSID != setupSSID {
            try? await Self.join(ssid: originalSSID, password: nil)
        }
        return ip
    }

    static func currentWiFiSSID() -> String? {
        primaryWiFiInterface()?.ssid()
    }

    static func visibleSetupSSID() async -> String? {
        await visibleSetupSSIDs().first
    }

    static func visibleSetupSSIDs() async -> [String] {
        await Task.detached(priority: .userInitiated) {
            guard let interface = primaryWiFiInterface() else { return [] }
            let networks = (try? interface.scanForNetworks(withName: nil)) ?? []
            return setupSSIDs(fromNetworkNames: networks.compactMap { $0.ssid })
        }.value
    }

    static func setupSSIDs(fromNetworkNames names: [String]) -> [String] {
        let uniqueNames = Set(
            names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        return uniqueNames
            .filter { name in
                let lower = name.lowercased()
                return lower == "awtrix"
                    || lower.hasPrefix("awtrix_")
                    || lower.hasPrefix("awtrix-")
                    || lower.hasPrefix("ulanzi_")
                    || lower.hasPrefix("ulanzi-")
            }
            .sorted { lhs, rhs in
                let lhsLower = lhs.lowercased()
                let rhsLower = rhs.lowercased()
                if lhsLower.hasPrefix("awtrix_") != rhsLower.hasPrefix("awtrix_") {
                    return lhsLower.hasPrefix("awtrix_")
                }
                if lhsLower.hasPrefix("awtrix-") != rhsLower.hasPrefix("awtrix-") {
                    return lhsLower.hasPrefix("awtrix-")
                }
                return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
    }

    private static func primaryWiFiInterface() -> CWInterface? {
        CWWiFiClient.shared().interface(withName: "en0")
            ?? CWWiFiClient.shared().interfaces()?.first
    }

    private static func join(ssid: String, password: String?) async throws {
        try await Task.detached(priority: .userInitiated) {
            guard let interface = primaryWiFiInterface() else {
                throw ProvisionError.connectFailed("Wi-Fi is not available on this Mac.")
            }
            let networks = try interface.scanForNetworks(withName: ssid)
            guard let network = networks.sorted(by: { $0.rssiValue > $1.rssiValue }).first else {
                throw ProvisionError.joinFailed(ssid)
            }
            try interface.associate(to: network, password: password)
        }.value
    }

    private static func waitForSetupPortal() async throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if (try? await run("/usr/bin/curl", ["-sS", "--max-time", "2", "http://192.168.4.1/ipaddress"], timeout: 4)) != nil {
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw ProvisionError.connectFailed("OpenBurnBar joined AWTRIX setup Wi-Fi, but the setup server at 192.168.4.1 did not answer.")
    }

    private static func postWiFi(_ credentials: PixelClockWiFiCredentials) async throws -> String {
        let body = "ssid=\(urlEncode(credentials.ssid))&password=\(urlEncode(credentials.password))"
        let response = try await run(
            "/usr/bin/curl",
            ["-sS", "--max-time", "35", "-X", "POST", "-H", "Content-Type: application/x-www-form-urlencoded", "--data", body, "http://192.168.4.1/connect"],
            timeout: 40
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard response.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: String.CompareOptions.regularExpression) != nil else {
            throw ProvisionError.connectFailed(response.isEmpty ? "AWTRIX did not return an IP address after Wi-Fi setup." : response)
        }
        return response
    }

    private static func urlEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try runSync(executable, arguments, timeout: timeout)
        }.value
    }

    private static func runSync(_ executable: String, _ arguments: [String], timeout: TimeInterval = 8) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(100_000)
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw ProvisionError.connectFailed([output, error].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
