import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                fileHeader
                Divider()
                fileArea
                Divider()
                bottomBar
            }
            .frame(minWidth: 440)

            Divider()

            SettingsPanel()
                .frame(width: 350)
        }
    }

    // MARK: Dateiliste

    private var fileHeader: some View {
        HStack {
            Text(model.files.isEmpty ? "Keine Fotos" : "\(model.files.count) \(model.files.count == 1 ? "Foto" : "Fotos")")
                .font(.headline)
            Spacer()
            Button {
                model.chooseFiles()
            } label: {
                Label("Hinzufügen …", systemImage: "plus")
            }
            Button("Liste leeren") { model.clear() }
                .disabled(model.files.isEmpty)
        }
        .disabled(model.isProcessing)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var fileArea: some View {
        Group {
            if model.files.isEmpty {
                emptyState
            } else {
                List(model.files) { item in
                    FileRow(item: item)
                        .contextMenu {
                            Button("Im Finder zeigen") {
                                NSWorkspace.shared.activateFileViewerSelecting([item.url])
                            }
                            if case .done(let out) = item.status {
                                Button("Ergebnis im Finder zeigen") {
                                    NSWorkspace.shared.activateFileViewerSelecting([out])
                                }
                            }
                            Divider()
                            Button("Aus Liste entfernen") { model.remove(item) }
                                .disabled(model.isProcessing)
                        }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
            Text("Fotos oder Ordner hierher ziehen")
                .font(.title3)
            Text("JPG, HEIC und PNG · Ordner werden mit Unterordnern durchsucht")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Fotos auswählen …") { model.chooseFiles() }
                .padding(.top, 4)
        }
        .padding()
    }

    // MARK: Untere Leiste

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Ausgabeordner")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.outputFolder?.path ?? "Nicht gewählt")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(model.outputFolder == nil ? Color.secondary : Color.primary)
                    .help(model.outputFolder?.path ?? "")
            }
            Button("Wählen …") { model.chooseOutputFolder() }
                .disabled(model.isProcessing)

            Spacer(minLength: 12)

            if model.isProcessing {
                ProgressView(value: model.progress)
                    .frame(width: 120)
                Button("Abbrechen") { model.cancel() }
            } else {
                if let message = model.statusMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if model.lastRunSucceeded > 0 {
                        Button("Im Finder zeigen") { model.showOutputInFinder() }
                    }
                } else if let hint = model.startHint {
                    Text(hint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button {
                    model.start()
                } label: {
                    Label("Wasserzeichen setzen", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canStart)
            }
        }
        .padding(12)
    }
}

// MARK: - Zeile

private struct FileRow: View {
    let item: PhotoItem

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.url.lastPathComponent)
                    .lineLimit(1)
                Text(item.url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            status
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var status: some View {
        switch item.status {
        case .pending:
            EmptyView()
        case .working:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(message)
        }
    }
}

// MARK: - Einstellungen

struct SettingsPanel: View {
    @EnvironmentObject private var model: AppModel

    private static let fontFamilies: [String] =
        NSFontManager.shared.availableFontFamilies.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }

    var body: some View {
        Form {
            Section("Wasserzeichen") {
                Picker("Art", selection: $model.settings.kind) {
                    ForEach(WatermarkKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if model.settings.usesText {
                Section("Text") {
                    TextField("Text", text: $model.settings.text, prompt: Text("© Ihr Name"))
                    Picker("Schrift", selection: $model.settings.fontFamily) {
                        ForEach(fontFamilyOptions, id: \.self) { family in
                            Text(family).tag(family)
                        }
                    }
                    Toggle("Fett", isOn: $model.settings.bold)
                    PercentSlider(title: "Größe", value: $model.settings.textSizePercent, range: 1...15, step: 0.5)
                    ColorPicker("Farbe", selection: textColor, supportsOpacity: false)
                    Toggle("Schatten", isOn: $model.settings.shadow)
                }
            }

            if model.settings.usesLogo {
                Section("Logo") {
                    HStack {
                        Text(logoName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(model.settings.logoPath == nil ? Color.secondary : Color.primary)
                        Spacer()
                        Button("Wählen …") { model.chooseLogo() }
                    }
                    PercentSlider(title: "Breite", value: $model.settings.logoSizePercent, range: 5...60, step: 1)
                    if !model.settings.usesText {
                        Toggle("Schatten", isOn: $model.settings.shadow)
                    }
                }
            }

            Section("Position") {
                Toggle("Über das ganze Bild kacheln", isOn: $model.settings.tiled)
                if model.settings.tiled {
                    PercentSlider(title: "Abstand", value: $model.settings.tileSpacingPercent, range: 2...40, step: 1)
                    LabeledSlider(title: "Winkel", value: $model.settings.tileAngle, range: -90...90, step: 5) {
                        "\(Int($0))°"
                    }
                } else {
                    LabeledContent("Ausrichtung") {
                        PositionPicker(position: $model.settings.position)
                    }
                    PercentSlider(title: "Randabstand", value: $model.settings.marginPercent, range: 0...15, step: 0.5)
                }
                LabeledSlider(title: "Deckkraft", value: $model.settings.opacity, range: 0.1...1, step: 0.05) {
                    "\(Int(($0 * 100).rounded())) %"
                }
            }

            Section {
                LabeledSlider(title: "Qualität", value: $model.settings.quality, range: 0.5...1, step: 0.05) {
                    "\(Int(($0 * 100).rounded())) %"
                }
                Toggle("Metadaten (EXIF) behalten", isOn: $model.settings.keepMetadata)
                Toggle("GPS-Standort entfernen", isOn: $model.settings.removeGPS)
                    .disabled(!model.settings.keepMetadata)
                Toggle("Datei-Datum übernehmen", isOn: $model.settings.keepFileDates)
                TextField("Namenszusatz", text: $model.settings.fileSuffix, prompt: Text("z. B. _wm"))
            } header: {
                Text("Export")
            } footer: {
                Text("Größen beziehen sich auf die kürzere Bildseite, damit Hoch- und Querformat gleich aussehen. Format (JPG/HEIC) bleibt erhalten, Originale werden nie verändert.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(model.isProcessing)
    }

    private var fontFamilyOptions: [String] {
        let current = model.settings.fontFamily
        return Self.fontFamilies.contains(current) ? Self.fontFamilies : [current] + Self.fontFamilies
    }

    private var logoName: String {
        guard let path = model.settings.logoPath else { return "Kein Logo gewählt" }
        return (path as NSString).lastPathComponent
    }

    private var textColor: Binding<Color> {
        Binding(
            get: { Color(nsColor: model.settings.textColor.nsColor) },
            set: { model.settings.textColor = RGBAColor(NSColor($0)) }
        )
    }
}

// MARK: - Bausteine

private struct PositionPicker: View {
    @Binding var position: WatermarkPosition

    private let rows: [[WatermarkPosition]] = [
        [.topLeft, .top, .topRight],
        [.left, .center, .right],
        [.bottomLeft, .bottom, .bottomRight],
    ]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(0..<rows.count, id: \.self) { r in
                HStack(spacing: 4) {
                    ForEach(rows[r]) { pos in
                        Button {
                            position = pos
                        } label: {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(position == pos ? Color.accentColor : Color.secondary.opacity(0.25))
                                .frame(width: 26, height: 18)
                        }
                        .buttonStyle(.plain)
                        .help(pos.label)
                        .accessibilityLabel(pos.label)
                    }
                }
            }
        }
        .padding(4)
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    init(title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
         format: @escaping (Double) -> String) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
        self.format = format
    }

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range, step: step)
                Text(format(value))
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PercentSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        LabeledSlider(title: title, value: $value, range: range, step: step) { v in
            v == v.rounded() ? "\(Int(v)) %" : String(format: "%.1f %%", v)
        }
    }
}
