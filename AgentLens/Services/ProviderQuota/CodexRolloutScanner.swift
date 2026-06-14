import Foundation

enum CodexRolloutScanner {
    static func scanCodexRateLimitEvents(
        in candidateDirectories: [URL],
        freshnessCutoff: Date,
        existingCache: CodexRolloutScanCache
    ) throws -> CodexRateLimitScanResult {
        let fileManager = FileManager.default
        var updatedCache = existingCache
        var didChangeCache = false

        let files = candidateDirectories
            .flatMap { findRolloutFiles(in: $0, fileManager: fileManager) }
            .compactMap { file -> (URL, CodexRolloutFileSignature)? in
                guard let signature = fileSignature(for: file) else { return nil }
                return (file, signature)
            }
            .sorted { lhs, rhs in
                lhs.1.modifiedAt > rhs.1.modifiedAt
            }

        let activePaths = Set(files.map { $0.0.standardizedFileURL.path })

        for (file, signature) in files {
            let path = file.standardizedFileURL.path
            if let cachedEntry = updatedCache.fileEntries[path], cachedEntry.signature == signature {
                continue
            }

            let event = try? lastCodexRateLimitEvent(in: file) // try?-ok(cache scan skip)
            updatedCache.fileEntries[path] = CodexRolloutFileCacheEntry(
                signature: signature,
                latestRateLimitEvent: event
            )
            didChangeCache = true
        }

        let stalePaths = Set(updatedCache.fileEntries.keys).subtracting(activePaths)
        if !stalePaths.isEmpty {
            for stalePath in stalePaths {
                updatedCache.fileEntries.removeValue(forKey: stalePath)
            }
            didChangeCache = true
        }

        let latestEvent = updatedCache.fileEntries.values
            .compactMap(\.latestRateLimitEvent)
            .filter { $0.timestamp >= freshnessCutoff }
            .max { lhs, rhs in
                lhs.timestamp < rhs.timestamp
            }
        if updatedCache.latestRateLimitEvent != latestEvent {
            updatedCache.latestRateLimitEvent = latestEvent
            didChangeCache = true
        }

        return CodexRateLimitScanResult(
            latestEvent: latestEvent,
            cache: updatedCache,
            didChangeCache: didChangeCache
        )
    }

    static func lastCodexRateLimitEvent(in file: URL) throws -> CodexRateLimitEvent? {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() } // try?-ok(handle teardown)

        let size = try handle.seekToEnd()
        let bytesToRead = min(UInt64(CodexQuotaScanPolicy.tailReadBytes), size)
        let startOffset = size - bytesToRead

        try handle.seek(toOffset: startOffset)
        guard let data = try handle.readToEnd(), !data.isEmpty else { return nil }
        guard let contents = String(data: data, encoding: .utf8) else { return nil }

        var lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        if startOffset > 0, !lines.isEmpty {
            // Skip potentially truncated first line when reading from a file tail offset.
            lines.removeFirst()
        }
        if lines.count > CodexQuotaScanPolicy.maxTailLines {
            lines = Array(lines.suffix(CodexQuotaScanPolicy.maxTailLines))
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for line in lines.reversed() {
            let lineData = Data(line.utf8)
            guard let event = try? decoder.decode(CodexRolloutEnvelope.self, from: lineData) else { continue } // try?-ok(skip malformed line)
            guard event.type == "event_msg",
                  event.payload.type == "token_count",
                  event.payload.rateLimits.primary != nil || event.payload.rateLimits.secondary != nil else {
                continue
            }

            return CodexRateLimitEvent(
                timestamp: event.timestamp,
                planType: event.payload.rateLimits.planType,
                primary: event.payload.rateLimits.primary.map {
                    CodexRateLimitWindow(
                        usedPercent: $0.usedPercent,
                        windowMinutes: $0.windowMinutes,
                        resetsAt: $0.resetsAt
                    )
                },
                secondary: event.payload.rateLimits.secondary.map {
                    CodexRateLimitWindow(
                        usedPercent: $0.usedPercent,
                        windowMinutes: $0.windowMinutes,
                        resetsAt: $0.resetsAt
                    )
                }
            )
        }
        return nil
    }

    static func fileSignature(for url: URL) -> CodexRolloutFileSignature? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]) // try?-ok(metadata guard-nil)
        guard values?.isRegularFile == true else { return nil }
        guard let modifiedAt = values?.contentModificationDate else { return nil }
        return CodexRolloutFileSignature(
            modifiedAt: modifiedAt.timeIntervalSince1970,
            sizeBytes: Int64(values?.fileSize ?? 0)
        )
    }

    static func findRolloutFiles(in directory: URL, fileManager: FileManager = .default) -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl" else { continue }
            files.append(url)
        }
        return files
    }
}
