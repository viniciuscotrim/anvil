import SwiftUI

/// A real check, not a placeholder label: this Mac's iOS port has to
/// eventually plan around whatever RAM a real iPhone actually reports,
/// the same way the macOS app already plans around this Mac's own
/// physical memory (`ModelSizeClass`) — worth seeing on the very first
/// screen that ever runs here.
struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "hammer.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text("Anvil")
                .font(.largeTitle.bold())
            Text("iOS scaffold — Phase 1 gate")
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 8)

            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Device", value: UIDevice.current.name)
                LabeledContent("Model", value: UIDevice.current.model)
                LabeledContent("iOS Version", value: UIDevice.current.systemVersion)
                LabeledContent(
                    "Physical Memory",
                    value: ByteCountFormatter.string(
                        fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory),
                        countStyle: .memory
                    )
                )
            }
            .frame(maxWidth: 320)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
