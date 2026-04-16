import Foundation

actor CursorConnectorLogStreamManager {
    private var usageReadOffset: UInt64 = 0
    private var routeReadOffset: UInt64 = 0

    func resetOffsets() {
        usageReadOffset = 0
        routeReadOffset = 0
    }

    func readRouteDelta(from url: URL) throws -> String? {
        try readDelta(from: url, offset: &routeReadOffset)
    }

    func readUsageDelta(from url: URL) throws -> String? {
        try readDelta(from: url, offset: &usageReadOffset)
    }

    private func readDelta(from url: URL, offset: inout UInt64) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let fileSize = attrs[.size] as? NSNumber {
            let size = fileSize.uint64Value
            if offset > size {
                offset = 0
            }
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        try handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        offset += UInt64(data.count)
        guard !data.isEmpty else { return nil }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }
}
