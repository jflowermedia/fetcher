import SwiftUI

struct FormatsView: View {
    let formats: [Format]
    @Binding var selection: String?

    @State private var filter: FormatKind?
    @State private var sortOrder = [KeyPathComparator(\Format.sortHeight, order: .reverse)]

    private var rows: [Format] {
        formats.filter { filter == nil || $0.kind == filter }.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Show", selection: $filter) {
                Text("All").tag(FormatKind?.none)
                ForEach(FormatKind.allCases) { Text($0.rawValue).tag(FormatKind?.some($0)) }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("ID", value: \.formatID) { Text($0.formatID).monospaced() }
                    .width(min: 50, ideal: 70)
                TableColumn("Ext", value: \.sortExt) { Text($0.ext ?? "?") }
                    .width(min: 40, ideal: 50)
                TableColumn("Resolution", value: \.sortHeight) { f in
                    Text(f.resolutionLabel).foregroundStyle(f.hasVideo ? .primary : .secondary)
                }
                .width(min: 80, ideal: 95)
                TableColumn("FPS", value: \.sortFPS) { f in
                    Text(f.fps.map { String(format: "%g", $0) } ?? "")
                }
                .width(min: 30, ideal: 40)
                TableColumn("Codec", value: \.codecLabel) { Text($0.codecLabel) }
                    .width(min: 70, ideal: 110)
                TableColumn("Size", value: \.sortSize) { f in
                    Text(Fmt.bytes(f.size)).monospacedDigit()
                }
                .width(min: 60, ideal: 75)
                TableColumn("Bitrate", value: \.sortTBR) { f in
                    Text(f.tbr.map { "\(Int($0.rounded())) k" } ?? "").monospacedDigit()
                }
                .width(min: 50, ideal: 65)
                TableColumn("Type", value: \.kind.rawValue) { f in
                    Text(f.kind.rawValue).foregroundStyle(.secondary)
                }
                .width(min: 70, ideal: 95)
                TableColumn("Note", value: \.sortNote) { Text($0.formatNote ?? "").foregroundStyle(.secondary) }
            }
        }
    }
}
