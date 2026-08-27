//
//  ContentView.swift
//  Backgroundifier
//
//  The single-window UI: drop zone, settings, queue.
//  2026 upgrade by Mayk Thewessen.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            DropZoneView()

            SettingsPanel()

            if !model.items.isEmpty {
                QueueView()
            }

            ActionBar()
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 560)
        .background(.background)
    }
}

// MARK: - Drop zone

struct DropZoneView: View {
    @Environment(AppModel.self) private var model
    @State private var isTargeted = false

    private var accent: Color {
        isTargeted ? .accentColor : .secondary.opacity(0.5)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03))
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))

            VStack(spacing: 10) {
                if model.isProcessing {
                    ProgressView(value: Double(model.completedCount), total: Double(max(model.totalCount, 1)))
                        .progressViewStyle(.circular)
                    Text("Converting \(model.completedCount) of \(model.totalCount)")
                        .font(.headline)
                        .monospacedDigit()
                }
                else {
                    Image(systemName: "drop.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(
                            LinearGradient(colors: [.cyan, .blue], startPoint: .top, endPoint: .bottom)
                        )
                        .symbolEffect(.bounce, value: isTargeted)
                    Text("Drop images or folders here")
                        .font(.headline)
                    Text("or click to browse")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .frame(height: 170)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { browse() }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
        .animation(.snappy(duration: 0.2), value: isTargeted)
        .accessibilityLabel("Drop zone for images and folders")
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !model.isProcessing else { return false }

        Task {
            var urls: [URL] = []
            for provider in providers {
                if let url = await provider.fileURL() {
                    urls.append(url)
                }
            }
            model.add(urls: urls)
        }
        return true
    }

    private func browse() {
        guard !model.isProcessing else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.message = "Choose images or folders of images to convert."

        if panel.runModal() == .OK {
            model.add(urls: panel.urls)
        }
    }
}

extension NSItemProvider {
    func fileURL() async -> URL? {
        await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }
}

// MARK: - Settings

struct SettingsPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Resolution") {
                    HStack(spacing: 6) {
                        TextField("Width", value: $model.resolutionWidth, format: .number.grouping(.never))
                            .frame(width: 64)
                            .multilineTextAlignment(.trailing)
                        Text("×").foregroundStyle(.secondary)
                        TextField("Height", value: $model.resolutionHeight, format: .number.grouping(.never))
                            .frame(width: 64)
                            .multilineTextAlignment(.trailing)
                        Button("Use Screen") {
                            model.syncResolutionToScreen()
                        }
                        .help("Match the pixel resolution of the current screen")
                    }
                    .textFieldStyle(.roundedBorder)
                }

                LabeledContent("Background") {
                    HStack(spacing: 8) {
                        Picker("", selection: $model.backgroundStyle) {
                            ForEach(AppModel.BackgroundStyle.allCases) { style in
                                Text(style.label).tag(style)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 260)

                        ColorPicker("", selection: customColorBinding, supportsOpacity: false)
                            .labelsHidden()
                            .disabled(model.backgroundStyle != .customColor)
                            .opacity(model.backgroundStyle == .customColor ? 1 : 0.4)
                    }
                }

                Toggle("Search folders recursively", isOn: $model.recursive)
                Toggle("Overwrite existing files", isOn: $model.overwrite)

                Divider()

                LabeledContent("Save to") {
                    HStack(spacing: 6) {
                        Text(outputPathDisplay)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Button("Choose…") { chooseOutputDirectory() }
                        Button {
                            model.revealOutputDirectoryInFinder()
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .help("Reveal in Finder")
                    }
                }
            }
            .padding(6)
        }
        .disabled(model.isProcessing)
    }

    private var customColorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: model.customColor) },
            set: { model.customColor = NSColor($0) }
        )
    }

    private var outputPathDisplay: String {
        guard let url = model.outputDirectory else { return "Please select an output directory" }
        return url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canCreateDirectories = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Please select the output directory for your converted images."

        if panel.runModal() == .OK, let url = panel.urls.first {
            model.updateOutputDirectory(url)
        }
    }
}

// MARK: - Queue

struct QueueView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
            List(model.items) { item in
                HStack(spacing: 8) {
                    statusIcon(for: item.status)
                        .frame(width: 16)
                    Text(item.url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    statusText(for: item.status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .id(item.id)
                .help(item.url.path)
            }
            .listStyle(.inset)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1))
            )
            .frame(minHeight: 120, maxHeight: .infinity)
            .onChange(of: model.completedCount) {
                if let current = model.items.first(where: { $0.status == .processing }) {
                    withAnimation { proxy.scrollTo(current.id) }
                }
            }
        }
    }

    @ViewBuilder
    private func statusIcon(for status: QueueItem.Status) -> some View {
        switch status {
        case .ready:
            Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        case .processing:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .cancelled:
            Image(systemName: "slash.circle").foregroundStyle(.secondary)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private func statusText(for status: QueueItem.Status) -> Text {
        switch status {
        case .ready: return Text("")
        case .processing: return Text("Converting…")
        case .done: return Text("Done")
        case .cancelled: return Text("Cancelled")
        case .error(let error): return Text(error.description)
        }
    }
}

// MARK: - Bottom action bar

struct ActionBar: View {
    @Environment(AppModel.self) private var model

    private var readyCount: Int {
        model.items.filter { $0.status == .ready }.count
    }

    var body: some View {
        HStack {
            Button("Clear") {
                model.clear()
            }
            .disabled(model.isProcessing || model.items.isEmpty)

            Spacer()

            if model.isProcessing {
                ProgressView(value: Double(model.completedCount), total: Double(max(model.totalCount, 1)))
                    .frame(maxWidth: 180)
                Button("Cancel", role: .cancel) {
                    model.cancel()
                }
                .keyboardShortcut(".", modifiers: .command)
            }
            else {
                Button("Backgroundify") {
                    model.start()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(readyCount == 0 || model.outputDirectory == nil)
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(AppModel.shared)
}
