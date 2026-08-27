//
//  AppModel.swift
//  Backgroundifier
//
//  App state and the processing engine.
//  2026 upgrade by Mayk Thewessen.
//

import AppKit
import Observation
import UniformTypeIdentifiers

enum ProcessorError: Error {
    case invalidInput
    case invalidOutput
    case processingFailed
    case noWritePermission

    var description: String {
        switch self {
        case .invalidInput: return "Invalid input"
        case .invalidOutput: return "Invalid output"
        case .processingFailed: return "Processing failed"
        case .noWritePermission: return "No write permission"
        }
    }
}

struct QueueItem: Identifiable, Equatable {
    enum Status: Equatable {
        case ready
        case processing
        case done
        case cancelled
        case error(ProcessorError)

        static func == (lhs: Status, rhs: Status) -> Bool {
            switch (lhs, rhs) {
            case (.ready, .ready), (.processing, .processing), (.done, .done), (.cancelled, .cancelled):
                return true
            case (.error(let a), .error(let b)):
                return a.description == b.description
            default:
                return false
            }
        }
    }

    let id = UUID()
    let url: URL
    var status: Status = .ready
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    // MARK: - Settings (persisted)

    private enum Keys {
        static let blurred = "blurred"
        static let auto = "auto"
        static let colorHex = "colorHex"
        static let recursive = "recursive"
        static let overwrite = "overwrite"
        static let lastUsedDirectory = "lastUsedDirectory"
    }

    enum BackgroundStyle: Int, CaseIterable, Identifiable {
        case blur
        case autoColor
        case customColor

        var id: Int { rawValue }
        var label: String {
            switch self {
            case .blur: return "Blur"
            case .autoColor: return "Auto Color"
            case .customColor: return "Custom"
            }
        }
    }

    var backgroundStyle: BackgroundStyle {
        didSet {
            UserDefaults.standard.set(backgroundStyle == .blur, forKey: Keys.blurred)
            UserDefaults.standard.set(backgroundStyle != .customColor, forKey: Keys.auto)
        }
    }

    var customColor: NSColor {
        didSet {
            UserDefaults.standard.set(customColor.hexString, forKey: Keys.colorHex)
        }
    }

    var recursive: Bool {
        didSet { UserDefaults.standard.set(recursive, forKey: Keys.recursive) }
    }

    var overwrite: Bool {
        didSet { UserDefaults.standard.set(overwrite, forKey: Keys.overwrite) }
    }

    var resolutionWidth: Int = 2880
    var resolutionHeight: Int = 1800

    // MARK: - Output directory (security scoped)

    private(set) var outputDirectory: URL?

    // MARK: - Queue

    var items: [QueueItem] = []
    var isProcessing = false
    var completedCount = 0
    var totalCount = 0

    @ObservationIgnored private var processingTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Keys.blurred: true,
            Keys.auto: true,
            Keys.recursive: true,
            Keys.overwrite: false,
        ])

        if defaults.bool(forKey: Keys.blurred) {
            self.backgroundStyle = .blur
        }
        else {
            self.backgroundStyle = defaults.bool(forKey: Keys.auto) ? .autoColor : .customColor
        }

        self.customColor = NSColor(hexString: defaults.string(forKey: Keys.colorHex) ?? "") ?? .systemBlue
        self.recursive = defaults.bool(forKey: Keys.recursive)
        self.overwrite = defaults.bool(forKey: Keys.overwrite)

        restoreOutputDirectory()
        syncResolutionToScreen()
    }

    // MARK: - Resolution

    func syncResolutionToScreen() {
        if let screen = NSScreen.main {
            let scale = screen.backingScaleFactor
            resolutionWidth = clampResolution(Int(screen.frame.size.width * scale))
            resolutionHeight = clampResolution(Int(screen.frame.size.height * scale))
        }
    }

    func clampResolution(_ value: Int) -> Int {
        min(max(value, 10), 9000)
    }

    // MARK: - Output directory

    private func restoreOutputDirectory() {
        if let bookmark = UserDefaults.standard.data(forKey: Keys.lastUsedDirectory) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale), !stale {
                _ = url.startAccessingSecurityScopedResource()
                outputDirectory = url
                return
            }
        }

        // default: ~/Pictures/Backgroundifier
        if let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first {
            outputDirectory = pictures.appendingPathComponent("Backgroundifier", isDirectory: true)
        }
    }

    func updateOutputDirectory(_ url: URL) {
        guard url != outputDirectory else { return }

        outputDirectory?.stopAccessingSecurityScopedResource()

        if let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: Keys.lastUsedDirectory)
        }

        outputDirectory = url
    }

    @discardableResult
    func createOutputDirectory() -> Bool {
        guard let outputDirectory else { return false }
        return (try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)) != nil
    }

    func revealOutputDirectoryInFinder() {
        guard let outputDirectory else { return }
        createOutputDirectory()
        NSWorkspace.shared.open(outputDirectory)
    }

    // MARK: - File intake

    /// Adds dropped or opened URLs to the queue: files directly, folders expanded
    /// (recursively when enabled), filtered to images, deduped by path.
    func add(urls: [URL]) {
        guard !isProcessing else { return }

        var collected: [URL] = items.filter { $0.status == .ready }.map(\.url)
        var seen = Set(collected.map(\.path))

        for url in urls {
            for file in imageFiles(under: url) {
                if seen.insert(file.path).inserted {
                    collected.append(file)
                }
            }
        }

        items = collected.map { QueueItem(url: $0) }
    }

    private func imageFiles(under url: URL) -> [URL] {
        func isImage(_ url: URL) -> Bool {
            guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else { return false }
            return type.conforms(to: .image)
        }

        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])

        if values?.isRegularFile == true {
            return isImage(url) ? [url] : []
        }
        guard values?.isDirectory == true else { return [] }

        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants, .skipsHiddenFiles]
        if !recursive {
            options.insert(.skipsSubdirectoryDescendants)
        }

        var output: [URL] = []
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .contentTypeKey], options: options) {
            for case let file as URL in enumerator {
                if (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true, isImage(file) {
                    output.append(file)
                }
            }
        }
        return output
    }

    func clear() {
        guard !isProcessing else { return }
        items = []
        completedCount = 0
        totalCount = 0
    }

    // MARK: - Processing

    struct JobConfiguration {
        var resolution: CGSize
        var blur: Bool
        var color: NSColor?    // nil with blur=false means auto color
        var overwrite: Bool
        var outputDirectory: URL
    }

    func start() {
        guard !isProcessing, !items.isEmpty else { return }
        guard let outputDirectory, createOutputDirectory() else { return }

        let config = JobConfiguration(
            resolution: CGSize(width: clampResolution(resolutionWidth), height: clampResolution(resolutionHeight)),
            blur: backgroundStyle == .blur,
            color: backgroundStyle == .customColor ? customColor : nil,
            overwrite: overwrite,
            outputDirectory: outputDirectory
        )

        isProcessing = true
        completedCount = 0
        totalCount = items.filter { $0.status == .ready }.count

        processingTask = Task {
            await runQueue(config: config)

            isProcessing = false
            processingTask = nil
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    func cancel() {
        processingTask?.cancel()
    }

    private func runQueue(config: JobConfiguration) async {
        let pending = items.indices.filter { items[$0].status == .ready }
        let limit = Self.concurrencyLimit(for: config.resolution)

        await withTaskGroup(of: (index: Int, error: ProcessorError?).self) { group in
            var next = 0

            @MainActor func submit() {
                guard next < pending.count else { return }
                let index = pending[next]
                next += 1

                if Task.isCancelled {
                    items[index].status = .cancelled
                    completedCount += 1
                    return
                }

                items[index].status = .processing
                let url = items[index].url
                group.addTask {
                    (index, Self.processFile(at: url, config: config))
                }
            }

            for _ in 0..<min(limit, pending.count) {
                submit()
            }

            for await result in group {
                items[result.index].status = result.error.map { .error($0) } ?? .done
                completedCount += 1
                submit()
            }

            // anything not yet submitted was cancelled
            while next < pending.count {
                items[pending[next]].status = .cancelled
                completedCount += 1
                next += 1
            }
        }
    }

    /// Memory- and core-aware parallelism, so huge target resolutions don't
    /// exhaust RAM and the machine stays responsive while converting.
    static func concurrencyLimit(for resolution: CGSize) -> Int {
        let cores = min(ProcessInfo.processInfo.activeProcessorCount, 16)
        let maxByCores = max(1, cores / 2)

        // estimate of the memory required per in-flight image:
        // 4 bytes per pixel, ~4 image-sized allocations, 1.5x safety factor
        let bytesPerImage = Double(resolution.width * resolution.height) * 4 * 4 * 1.5
        let memoryBudget = Double(min(ProcessInfo.processInfo.physicalMemory, 32 << 30)) / 4
        let maxByMemory = max(1, Int(memoryBudget / bytesPerImage))

        return min(maxByCores, maxByMemory)
    }

    /// Runs off the main actor: load, render, encode, write.
    nonisolated private static func processFile(at url: URL, config: JobConfiguration) -> ProcessorError? {
        autoreleasepool {
            guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else {
                return .invalidInput
            }

            guard let imageRep = processImage(image, resolution: config.resolution, blur: config.blur, color: config.color) else {
                return .processingFailed
            }

            guard let jpeg = imageRep.representation(using: .jpeg, properties: [.compressionFactor: 0.75]) else {
                return .processingFailed
            }

            let baseName = url.deletingPathExtension().lastPathComponent
            var outputURL = config.outputDirectory.appendingPathComponent(baseName).appendingPathExtension("jpg")

            if !config.overwrite {
                var i = 1
                while FileManager.default.fileExists(atPath: outputURL.path) && i < 10000 {
                    outputURL = config.outputDirectory.appendingPathComponent("\(baseName) (\(i))").appendingPathExtension("jpg")
                    i += 1
                }
            }

            do {
                try jpeg.write(to: outputURL, options: .atomic)
                return nil
            }
            catch CocoaError.fileWriteNoPermission {
                return .noWritePermission
            }
            catch {
                return .processingFailed
            }
        }
    }
}
