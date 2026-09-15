import SwiftUI
import VideoContextCore

struct TaskAnnotationEditor: View {
    let evidence: EvidenceItem
    let imageURL: URL?
    let onSave: ([TaskAnnotation]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var annotations: [TaskAnnotation]
    @State private var image: NSImage?
    @State private var selectedID: String?
    @State private var history: [[TaskAnnotation]] = []
    @State private var gestureStart: [TaskAnnotation]?
    @State private var showOriginal = false
    @State private var error: String?
    init(evidence: EvidenceItem, imageURL: URL?, initial: [TaskAnnotation], onSave: @escaping ([TaskAnnotation]) -> Void) {
        self.evidence = evidence; self.imageURL = imageURL; self.onSave = onSave
        _annotations = State(initialValue: initial)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Annotate screenshot · \(formatTime(evidence.timestamp))").font(.title2.bold())
                Spacer()
                Toggle("Original", isOn: $showOriginal).toggleStyle(.switch).fixedSize()
            }
            HStack {
                ForEach(TaskAnnotationKind.allCases, id: \.self) { kind in
                    Button(kind.rawValue.capitalized, systemImage: kind == .rectangle ? "rectangle" : kind == .arrow ? "arrow.up.right" : "text.bubble") {
                        history.append(annotations)
                        let item = TaskAnnotation(evidenceID: evidence.id, kind: kind)
                        annotations.append(item); selectedID = item.id; showOriginal = false
                    }
                }
                Button("Undo", systemImage: "arrow.uturn.backward") { if let old = history.popLast() { annotations = old } }.disabled(history.isEmpty).keyboardShortcut("z", modifiers: .command)
                Button("Delete", systemImage: "trash") { history.append(annotations); annotations.removeAll { $0.id == selectedID }; selectedID = nil }.disabled(selectedID == nil)
            }
            GeometryReader { proxy in
                if let image {
                    let scale = min(proxy.size.width / image.size.width, proxy.size.height / image.size.height)
                    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    ZStack(alignment: .topLeading) {
                        Image(nsImage: image).resizable().frame(width: size.width, height: size.height)
                        if !showOriginal {
                            ForEach(annotations) { annotation in annotationOverlay(annotation, size: size) }
                        }
                    }.frame(width: size.width, height: size.height)
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                } else { ProgressView("Loading screenshot") }
            }.frame(minHeight: 250)
            if let index = annotations.firstIndex(where: { $0.id == selectedID }) {
                TextField("Describe what the agent should notice", text: $annotations[index].text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: annotations[index].text) { old, _ in
                        var previous = annotations; previous[index].text = old; history.append(previous)
                    }
                if annotations[index].kind == .arrow {
                    HStack {
                        Button("Flip horizontally") { history.append(annotations); annotations[index].flipHorizontal = annotations[index].flipHorizontal != true }
                        Button("Flip vertically") { history.append(annotations); annotations[index].flipVertical = annotations[index].flipVertical != true }
                    }
                }
                HStack {
                    coordinate("X", index: index, key: \.x)
                    coordinate("Y", index: index, key: \.y)
                    coordinate("Width", index: index, key: \.width)
                    coordinate("Height", index: index, key: \.height)
                }
            } else { Text("Select an annotation to edit its description. Drag it to move; drag its corner to resize.").font(.caption).foregroundStyle(.secondary) }
            ScrollView(.horizontal) {
                HStack {
                    ForEach(Array(annotations.enumerated()), id: \.element.id) { index, annotation in
                        Button("\(index + 1). \(annotation.text.isEmpty ? annotation.kind.rawValue : annotation.text)") { selectedID = annotation.id }
                            .help("Select annotation \(index + 1)")
                    }
                }
            }.frame(height: 30)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Text("Annotations are saved with the task. Original media and OCR are preserved.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save annotations") { onSave(annotations); dismiss() }.buttonStyle(.borderedProminent)
                    .disabled(image == nil || !annotations.allSatisfy(\.isValid))
            }
        }.padding(20).frame(minWidth: 760, idealWidth: 1000, minHeight: 600, idealHeight: 780)
        .task {
            guard let imageURL else { error = "Screenshot unavailable."; return }
            do { let data = try await TaskFrameRenderer.render(url: imageURL, annotations: []); image = NSImage(data: data) }
            catch { self.error = error.localizedDescription }
        }
    }
    private func coordinate(_ title: String, index: Int, key: WritableKeyPath<TaskAnnotation, Double>) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption)
            Slider(value: Binding(get: { annotations[index][keyPath: key] }, set: { value in
                history.append(annotations)
                annotations[index][keyPath: key] = value
                annotations[index].x = min(annotations[index].x, 1 - annotations[index].width)
                annotations[index].y = min(annotations[index].y, 1 - annotations[index].height)
            }), in: 0.01...0.99).accessibilityLabel("Annotation \(title)")
        }
    }
    private func annotationOverlay(_ item: TaskAnnotation, size: CGSize) -> some View {
        let width = item.width * size.width, height = item.height * size.height
        return ZStack(alignment: .topLeading) {
            if item.kind == .rectangle { Rectangle().stroke(.red, lineWidth: 3) }
            if item.kind == .arrow {
                Path { path in
                    let start = CGPoint(x: item.flipHorizontal == true ? width : 0, y: item.flipVertical == true ? height : 0)
                    let end = CGPoint(x: item.flipHorizontal == true ? 0 : width, y: item.flipVertical == true ? 0 : height)
                    path.move(to: start); path.addLine(to: end)
                    let angle = atan2(end.y - start.y, end.x - start.x)
                    path.move(to: CGPoint(x: end.x - 15 * cos(angle - 0.5), y: end.y - 15 * sin(angle - 0.5)))
                    path.addLine(to: end)
                    path.addLine(to: CGPoint(x: end.x - 15 * cos(angle + 0.5), y: end.y - 15 * sin(angle + 0.5)))
                }.stroke(.red, lineWidth: 3)
            }
            Text(item.text.isEmpty ? "Add a description" : item.text).font(.caption.bold()).foregroundStyle(.white)
                .padding(4).background(.black.opacity(0.8)).lineLimit(3)
            if selectedID == item.id {
                Rectangle().stroke(.white, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                Rectangle().fill(.white).frame(width: 14, height: 14).position(x: width, y: height)
                    .gesture(drag(item, size: size, resize: true))
                    .accessibilityLabel("Resize annotation; use width and height controls below")
            }
        }.frame(width: width, height: height).contentShape(Rectangle())
            .offset(x: item.x * size.width, y: item.y * size.height)
            .onTapGesture { selectedID = item.id }.accessibilityAddTraits(.isButton)
            .accessibilityLabel("\(item.kind.rawValue): \(item.text)")
            .gesture(drag(item, size: size, resize: false))
    }
    private func drag(_ item: TaskAnnotation, size: CGSize, resize: Bool) -> some Gesture {
        DragGesture().onChanged { value in
            if gestureStart == nil { gestureStart = annotations; history.append(annotations); selectedID = item.id }
            guard let initial = gestureStart?.first(where: { $0.id == item.id }), let index = annotations.firstIndex(where: { $0.id == item.id }) else { return }
            if resize {
                annotations[index].width = max(0.02, min(1 - initial.x, initial.width + value.translation.width / size.width))
                annotations[index].height = max(0.02, min(1 - initial.y, initial.height + value.translation.height / size.height))
            } else {
                annotations[index].x = max(0, min(1 - initial.width, initial.x + value.translation.width / size.width))
                annotations[index].y = max(0, min(1 - initial.height, initial.y + value.translation.height / size.height))
            }
        }.onEnded { _ in gestureStart = nil }
    }
}
