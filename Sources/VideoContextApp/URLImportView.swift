import SwiftUI

struct URLImportView: View {
    let importAction: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Import video link", systemImage: "link").font(.title2.bold())
            Text("Paste an accessible Loom, YouTube, or direct video URL. If access is blocked, download the MP4 and import the file.")
                .foregroundStyle(.secondary)
            TextField("https://…", text: $value)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if value.isEmpty == false { importAction(value) } }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Import") { importAction(value) }
                    .buttonStyle(.borderedProminent)
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
