import Foundation
import OpenBurnBarCore

// MARK: - Chart Studio Persisted Canvas

public struct ChartStudioCanvas: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let prompt: String
    public let title: String
    public let summary: String
    public let createdAt: Date
    public let renderingJSON: Data

    public init(
        id: String = UUID().uuidString,
        prompt: String,
        title: String,
        summary: String,
        createdAt: Date = Date(),
        renderingJSON: Data
    ) {
        self.id = id
        self.prompt = prompt
        self.title = title
        self.summary = summary
        self.createdAt = createdAt
        self.renderingJSON = renderingJSON
    }
}

// MARK: - Chart Studio Store

@Observable
@MainActor
public final class ChartStudioStore {

    public private(set) var canvases: [ChartStudioCanvas] = []

    private let storageURL: URL
    private let maxCanvases: Int = 20

    public init(filename: String = "chart-studio-canvases.json") {
        let fm = FileManager.default
        let docs = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        self.storageURL = docs.appendingPathComponent(filename)
        load()
    }

    /// Append a new canvas and persist. Trims to `maxCanvases` (oldest dropped).
    public func add(_ canvas: ChartStudioCanvas) {
        canvases.insert(canvas, at: 0)
        if canvases.count > maxCanvases {
            canvases = Array(canvases.prefix(maxCanvases))
        }
        save()
    }

    public func remove(id: String) {
        canvases.removeAll { $0.id == id }
        save()
    }

    public func clear() {
        canvases.removeAll()
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        if let decoded = try? JSONDecoder().decode([ChartStudioCanvas].self, from: data) {
            canvases = decoded
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(canvases) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}
