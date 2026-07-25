import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Exports the log as CSV — a save panel on macOS, a share sheet on iOS.
struct LogExportButton: View {
    let model: AppModel
    @State private var isSharing = false

    var body: some View {
        #if os(macOS)
        Button("Export", systemImage: "square.and.arrow.up") { save() }
            .help("Export the log as CSV")
        #else
        Button("Export", systemImage: "square.and.arrow.up") { isSharing = true }
            .sheet(isPresented: $isSharing) {
                ShareSheet(items: [exportURL()].compactMap { $0 })
            }
        #endif
    }

    private func csvData() -> Data {
        Data(model.exportCSV().utf8)
    }

    private func defaultFilename() -> String {
        "hourglass-log-\(Date().formatted(.iso8601.year().month().day())).csv"
    }

    #if os(macOS)
    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultFilename()
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? csvData().write(to: url, options: .atomic)
    }
    #else
    /// Writes to a temporary file so the share sheet can offer real destinations.
    private func exportURL() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(defaultFilename())
        guard (try? csvData().write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }
    #endif
}

#if os(iOS)
import UIKit

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
