import SwiftUI
import VideoContextCore

struct BriefPane: View {
    @Bindable var model: AppModel
    let videoID: String
    let brief: BriefDocument?
    @State private var editor: BriefEditorState
    @State private var isSaving = false

    init(model: AppModel, videoID: String, brief: BriefDocument?) {
        self.model = model
        self.videoID = videoID
        self.brief = brief
        _editor = State(initialValue: BriefEditorState(source: brief?.markdown ?? ""))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Coding brief", systemImage: "doc.text").font(.headline)
                Spacer()
                if editor.isEditing {
                    Button("Cancel") { editor.cancel() }.disabled(isSaving)
                    Button("Save", systemImage: "checkmark") {
                        let value = editor.draft
                        isSaving = true
                        Task {
                            if await model.saveBrief(value, videoID: videoID) { editor.saved(value) }
                            isSaving = false
                        }
                    }
                    .disabled(isSaving || editor.draft == editor.source)
                } else {
                    if brief?.isUserEdited == true {
                        Label("Edited", systemImage: "pencil").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Edit", systemImage: "pencil") { editor.begin() }.disabled(brief == nil)
                }
            }
            .padding(WorkspaceStyle.padding)
            Divider()
            if editor.isEditing {
                TextEditor(text: $editor.draft)
                    .font(.body.monospaced()).padding(12)
                    .accessibilityLabel("Edit coding brief")
            } else if editor.source.isEmpty {
                ContentUnavailableView("Brief not available", systemImage: "doc.text", description: Text("Your coding brief appears here after analysis."))
            } else {
                ScrollView {
                    MarkdownBrief(markdown: editor.source)
                        .padding(WorkspaceStyle.padding).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(.background)
        .onChange(of: brief?.markdown) { _, value in editor.refresh(value ?? "") }
    }
}

private struct MarkdownBrief: View {
    let markdown: String
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(Array(markdown.components(separatedBy: .newlines).enumerated()), id: \.offset) { _, line in
                if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    if line.hasPrefix("#") {
                        Text(line.drop(while: { $0 == "#" || $0 == " " }))
                            .font(line.hasPrefix("# ") ? .title2.bold() : .headline)
                            .padding(.top, 8)
                    } else {
                        HStack(alignment: .top, spacing: 8) {
                            if line.hasPrefix("- ") { Text("•").foregroundStyle(.indigo) }
                            Text(inline(line.hasPrefix("- ") ? String(line.dropFirst(2)) : line))
                                .font(.body).lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        .textSelection(.enabled)
    }
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
