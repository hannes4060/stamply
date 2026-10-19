import Foundation
import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var files: [PhotoItem] = []
    @Published var settings: WatermarkSettings { didSet { saveSettings() } }
    @Published var outputFolder: URL? { didSet { saveOutputFolder() } }

    @Published private(set) var isProcessing = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var statusMessage: String?
    @Published private(set) var lastRunSucceeded = 0

    private var cancelRequested = false

    private static let settingsKey = "watermarkSettings"
    private static let outputKey = "outputFolderPath"

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.settingsKey),
           let saved = try? JSONDecoder().decode(WatermarkSettings.self, from: data) {
            settings = saved
        } else {
            settings = WatermarkSettings()
        }
        if let path = defaults.string(forKey: Self.outputKey) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                outputFolder = URL(fileURLWithPath: path, isDirectory: true)
            }
        }
    }

    // MARK: Status

    var canStart: Bool {
        !files.isEmpty && outputFolder != nil && !isProcessing && settings.validationError == nil
    }

    var startHint: String? {
        if files.isEmpty { return "Fotos hinzufügen" }
        if outputFolder == nil { return "Ausgabeordner wählen" }
        return settings.validationError
    }

    // MARK: Dateien

    func add(_ urls: [URL]) {
        guard !isProcessing else { return }
        var existing = Set(files.map { $0.url.standardizedFileURL.path })
        var new: [PhotoItem] = []

        for url in urls {
            for file in expand(url) {
                let key = file.standardizedFileURL.path
                if !existing.contains(key) {
                    existing.insert(key)
                    new.append(PhotoItem(url: file))
                }
            }
        }
        new.sort { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
        files.append(contentsOf: new)
        resetStatusIfFinished()
    }

    /// Ordner werden rekursiv nach unterstützten Bildern durchsucht.
    private func expand(_ url: URL) -> [URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        if !isDir.boolValue {
            return SupportedFormats.isSupported(url) ? [url] : []
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var result: [URL] = []
        for case let file as URL in enumerator where SupportedFormats.isSupported(file) {
            result.append(file)
        }
        return result
    }

    func remove(_ item: PhotoItem) {
        guard !isProcessing else { return }
        files.removeAll { $0.id == item.id }
    }

    func clear() {
        guard !isProcessing else { return }
        files.removeAll()
        statusMessage = nil
    }

    private func resetStatusIfFinished() {
        if !isProcessing { statusMessage = nil }
    }

    // MARK: Dialoge

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = "Fotos oder Ordner hinzufügen"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.jpeg, .heic, .heif, .png, .folder]
        if panel.runModal() == .OK {
            add(panel.urls)
        }
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.title = "Ausgabeordner wählen"
        panel.prompt = "Wählen"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            outputFolder = url
        }
    }

    func chooseLogo() {
        let panel = NSOpenPanel()
        panel.title = "Logo wählen (PNG mit Transparenz empfohlen)"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        if panel.runModal() == .OK, let url = panel.url {
            settings.logoPath = url.path
        }
    }

    func showOutputInFinder() {
        guard let folder = outputFolder else { return }
        NSWorkspace.shared.open(folder)
    }

    // MARK: Verarbeitung

    func start() {
        guard canStart, let outputFolder else { return }

        let renderer: WatermarkRenderer
        do {
            renderer = try WatermarkRenderer(settings: settings)
        } catch {
            statusMessage = error.localizedDescription
            return
        }

        // Zielnamen vorab festlegen, damit gleichnamige Dateien aus
        // verschiedenen Ordnern sich nicht gegenseitig überschreiben.
        var reserved = Set<String>()
        var jobs: [(id: UUID, input: URL, output: URL)] = []
        for item in files {
            let out = uniqueOutputURL(for: item.url, in: outputFolder, reserved: &reserved)
            jobs.append((item.id, item.url, out))
        }

        for i in files.indices { files[i].status = .pending }
        isProcessing = true
        cancelRequested = false
        progress = 0
        statusMessage = nil
        lastRunSucceeded = 0

        let total = jobs.count
        let parallel = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))

        Task.detached(priority: .userInitiated) { [weak self] in
            var succeeded = 0
            var failed = 0
            var finished = 0
            var cancelled = false

            await withTaskGroup(of: (UUID, PhotoItem.Status).self) { group in
                var queue = jobs.makeIterator()

                for _ in 0..<parallel {
                    guard let job = queue.next() else { break }
                    await self?.setStatus(job.id, .working)
                    group.addTask { AppModel.run(job.id, job.input, job.output, renderer) }
                }

                while let result = await group.next() {
                    let (id, status) = result
                    finished += 1
                    if case .done = status { succeeded += 1 } else { failed += 1 }
                    await self?.setStatus(id, status, progress: Double(finished) / Double(total))

                    if await self?.cancelRequested ?? true {
                        cancelled = true
                        continue // laufende Bilder noch sauber fertig schreiben
                    }
                    if let job = queue.next() {
                        await self?.setStatus(job.id, .working)
                        group.addTask { AppModel.run(job.id, job.input, job.output, renderer) }
                    }
                }
            }

            await self?.finish(succeeded: succeeded, failed: failed, cancelled: cancelled)
        }
    }

    func cancel() {
        cancelRequested = true
    }

    /// Läuft im Hintergrund, eine Datei pro Aufruf.
    nonisolated static func run(_ id: UUID, _ input: URL, _ output: URL,
                                _ renderer: WatermarkRenderer) -> (UUID, PhotoItem.Status) {
        do {
            try autoreleasepool {
                try renderer.process(input: input, output: output)
            }
            return (id, .done(output))
        } catch {
            return (id, .failed(error.localizedDescription))
        }
    }

    private func setStatus(_ id: UUID, _ status: PhotoItem.Status, progress: Double? = nil) {
        if let i = files.firstIndex(where: { $0.id == id }) {
            files[i].status = status
        }
        if let progress { self.progress = progress }
    }

    private func finish(succeeded: Int, failed: Int, cancelled: Bool) {
        isProcessing = false
        lastRunSucceeded = succeeded
        var parts = ["\(succeeded) \(succeeded == 1 ? "Foto" : "Fotos") fertig"]
        if failed > 0 { parts.append("\(failed) fehlgeschlagen") }
        if cancelled { parts.append("abgebrochen") }
        statusMessage = parts.joined(separator: ", ")
        if succeeded > 0 && !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    private func uniqueOutputURL(for input: URL, in folder: URL, reserved: inout Set<String>) -> URL {
        let base = input.deletingPathExtension().lastPathComponent + settings.fileSuffix
        let ext = input.pathExtension
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 1
        while reserved.contains(candidate.path.lowercased())
                || FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext)
            n += 1
        }
        reserved.insert(candidate.path.lowercased())
        return candidate
    }

    // MARK: Speichern

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
    }

    private func saveOutputFolder() {
        UserDefaults.standard.set(outputFolder?.path, forKey: Self.outputKey)
    }
}
