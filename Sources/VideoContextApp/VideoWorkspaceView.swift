import AVFoundation
import SwiftUI
import VideoContextCore

struct VideoWorkspaceView: View {
    @Bindable var model: AppModel
    let snapshot: VideoSnapshot
    @State private var player: AVPlayer?
    @State private var playbackPosition = 0.0
    @State private var isPlaying = false
    @State private var isScrubbing = false

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader(model: model, snapshot: snapshot)
            Divider()
            HSplitView {
                VSplitView {
                  VStack(spacing: 0) {
                    VideoPlayerSurface(player: player)
                        .frame(minHeight: 170, idealHeight: 290)
                    HStack(spacing: 10) {
                        Button(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill") {
                            togglePlayback()
                        }
                        .disabled(player == nil)

                        Text(formatTime(playbackPosition))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)

                        Slider(
                            value: $playbackPosition,
                            in: 0...max(snapshot.video.duration, 0.1),
                            onEditingChanged: handleScrubbing
                        )
                        .disabled(player == nil || snapshot.video.duration <= 0)
                        .accessibilityLabel("Playback position")

                        Text(formatTime(snapshot.video.duration))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)

                        Button(model.savingFrameVideoID == snapshot.video.id ? "Saving frame…" : "Save current frame", systemImage: "camera") {
                            let time = player?.currentTime().seconds ?? 0
                            Task { await model.addManualFrame(at: max(0, time)) }
                        }
                        .labelStyle(.iconOnly)
                        .help(model.savingFrameVideoID == snapshot.video.id ? "Saving frame…" : "Save current frame")
                        .disabled(player == nil || model.savingFrameVideoID != nil || model.isProcessing)
                        if model.savingFrameVideoID == snapshot.video.id { ActivityIndicator(fraction: nil) }
                    }
                    .font(.callout)
                    .padding(10)
                  }
                  .frame(minHeight: 210, idealHeight: 330)
                  TranscriptView(model: model, segments: snapshot.transcript)
                      .frame(minHeight: 150, idealHeight: 260)
                }
                .frame(minWidth: 320, idealWidth: 360, maxWidth: .infinity)

                VSplitView {
                    BriefTasksPane(model: model, snapshot: snapshot)
                        .id(snapshot.video.id)
                        .frame(minHeight: 320, idealHeight: 340)
                    EvidenceGallery(model: model, evidence: snapshot.evidence)
                        .frame(minHeight: 150, idealHeight: 250)
                }
                .frame(minWidth: 320, idealWidth: 360, maxWidth: .infinity)
            }
        }
        .onAppear { configureForSnapshot() }
        .onChange(of: snapshot.video.id) { _, _ in configureForSnapshot() }
        .onChange(of: model.seekRequest) { _, request in
            guard let request else { return }
            playbackPosition = request.timestamp
            player?.seek(to: CMTime(seconds: request.timestamp, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        .task(id: snapshot.video.id) {
            while !Task.isCancelled {
                updatePlaybackPosition()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        .onDisappear {
            player?.pause()
            isPlaying = false
        }
    }

    private func configureForSnapshot() {
        player?.pause()
        isPlaying = false
        playbackPosition = 0
        if let url = model.mediaURL(for: snapshot.video) {
            player = AVPlayer(url: url)
        } else {
            player = nil
        }
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            if playbackPosition >= snapshot.video.duration {
                playbackPosition = 0
                player.seek(to: .zero)
            }
            player.play()
        }
        isPlaying.toggle()
    }

    private func handleScrubbing(_ editing: Bool) {
        isScrubbing = editing
        if !editing {
            player?.seek(to: CMTime(seconds: playbackPosition, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private func updatePlaybackPosition() {
        guard !isScrubbing, let player else { return }
        let seconds = player.currentTime().seconds
        if seconds.isFinite {
            playbackPosition = min(max(0, seconds), max(snapshot.video.duration, seconds))
        }
        if snapshot.video.duration > 0, seconds >= snapshot.video.duration, isPlaying {
            isPlaying = false
        }
    }
}

private struct TranscriptView: View {
    @Bindable var model: AppModel
    let segments: [TranscriptSegment]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Transcript", systemImage: "text.alignleft").font(.headline)
                Spacer()
                Text("\(segments.count) passages").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 16).padding(.top, 12)
            if segments.isEmpty {
                ContentUnavailableView("Transcript not available", systemImage: "text.quote")
            } else {
                List(segments) { segment in
                    TranscriptRow(model: model, segment: segment)
                }
                .listStyle(.inset)
            }
        }
    }
}

private struct TranscriptRow: View {
    @Bindable var model: AppModel
    let segment: TranscriptSegment
    @State private var text: String

    init(model: AppModel, segment: TranscriptSegment) {
        self.model = model
        self.segment = segment
        _text = State(initialValue: segment.text)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(formatTime(segment.start)) { model.requestSeek(to: segment.start) }
                .buttonStyle(.link)
                .monospacedDigit()
            VStack(alignment: .leading, spacing: 4) {
                TextField("Transcript", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .onSubmit { saveIfChanged() }
                HStack {
                    if segment.isCorrected {
                        Label("Corrected", systemImage: "pencil").foregroundStyle(.blue)
                        Text("Original: \(segment.originalText)").lineLimit(1)
                    }
                    Spacer()
                    if text != segment.text {
                        Button("Save correction") { saveIfChanged() }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 7)
    }

    private func saveIfChanged() {
        guard text != segment.text else { return }
        Task { await model.correctTranscript(segmentID: segment.id, text: text) }
    }
}

private struct EvidenceGallery: View {
    @Bindable var model: AppModel
    let evidence: [EvidenceItem]
    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Screenshots", systemImage: "photo.on.rectangle").font(.headline)
                Spacer()
                Text("\(evidence.count) frames · OCR").font(.caption).foregroundStyle(.secondary)
            }
            if evidence.isEmpty {
                ContentUnavailableView("No screenshots yet", systemImage: "photo.on.rectangle")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(evidence) { item in
                            Button {
                                model.requestSeek(to: item.timestamp)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    EvidenceThumbnail(url: model.imageURL(for: item))
                                    HStack {
                                        Text(formatTime(item.timestamp)).monospacedDigit()
                                        Spacer()
                                        Text(item.origin == .manual ? "Manual" : "Automatic")
                                    }
                                    .font(.caption)
                                    Text(item.ocrText.isEmpty ? "No text detected" : item.ocrText)
                                        .font(.caption)
                                        .lineLimit(3)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(8)
                            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
                            .help("Seek to \(formatTime(item.timestamp))")
                            .accessibilityLabel("Seek to screenshot at \(formatTime(item.timestamp))")
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(.background)
    }
}
