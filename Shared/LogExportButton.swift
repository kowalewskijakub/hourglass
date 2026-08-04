import SwiftUI
import HourglassCore
#if os(macOS)
import AppKit
#endif

/// Exports the whole log as CSV. Lives in Stats' toolbar in both segments.
struct LogExportButton: View {
    let model: AppModel

    var body: some View {
        CSVExportButton(title: "Export", help: "Export the log as CSV") {
            model.log.exportCSV()
        }
    }
}

/// A CSV export button — a save panel on macOS, a share sheet on iOS.
///
/// The CSV is produced on demand rather than passed in, because History's
/// selection changes under this button between renders and a snapshot taken at
/// construction would export whatever was selected a moment ago.
struct CSVExportButton: View {
    /// How the button is drawn. The toolbar wants a stock button; History's
    /// selection bar wants the same chip everything else in that bar is.
    enum Style { case standard, chip }

    let title: LocalizedStringKey
    var systemImage: String = "square.and.arrow.up"
    var help: LocalizedStringKey?
    /// Distinguishes a partial export's filename from a full one's.
    var filenameSuffix: String?
    var style: Style = .standard
    let csv: () -> String

    @State private var isSharing = false

    var body: some View {
        #if os(macOS)
        button { save() }
        #else
        button { isSharing = true }
            .sheet(isPresented: $isSharing) {
                ShareSheet(items: [exportURL()].compactMap { $0 })
            }
        #endif
    }

    @ViewBuilder
    private func button(action: @escaping () -> Void) -> some View {
        let button = Group {
            switch style {
            case .standard:
                Button(title, systemImage: systemImage, action: action)
            case .chip:
                Button(action: action) {
                    OrbitChip(symbol: systemImage, title: title, tint: .orbitEmber, isOn: true)
                }
                .buttonStyle(.plain)
            }
        }
        if let help {
            button.help(help)
        } else {
            button
        }
    }

    private func csvData() -> Data {
        Data(csv().utf8)
    }

    private func defaultFilename() -> String {
        let day = Date().formatted(.iso8601.year().month().day())
        guard let filenameSuffix else { return "hourglass-log-\(day).csv" }
        return "hourglass-log-\(filenameSuffix)-\(day).csv"
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
