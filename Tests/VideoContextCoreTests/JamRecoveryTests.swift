import Foundation
import Testing
@testable import VideoContextCore

struct JamRecoveryTests {
    @Test func oldReadySourceWithMissingFramesDisplaysPartialImmediately() throws {
        let old = JamEvidenceReference(sourceURL: "https://jam.dev/c/one", recordingID: "one", state: .ready,
            importedAt: Date(timeIntervalSince1970: 100),
            items: [.init(id: "transcript-old", component: .transcript, text: "Checkout is blank", toolName: "getVideoTranscript")],
            availability: [.init(component: .details, status: .available, message: "Details imported."),
                           .init(component: .transcript, status: .available, message: "Transcript imported."),
                           .init(component: .frame, status: .unavailable, message: "Frames missing.")])
        var source = FeedbackSource(id: "fsrc_existing", url: old.sourceURL, kind: .jam, status: .ready)
        source.jam = old
        #expect(source.presentationStatus == "Partially imported")
        let decoded = try JSONDecoder().decode(JamEvidenceReference.self, from: JSONEncoder().encode(old))
        #expect(decoded.lastAttemptAt == nil)
    }

    @Test func retryMergesByComponentAndPreservesPriorEvidenceOnFailure() throws {
        let original = JamEvidenceReference(sourceURL: "https://jam.dev/c/one", recordingID: "one", state: .ready,
            importedAt: Date(timeIntervalSince1970: 100),
            items: [.init(id: "transcript-old", component: .transcript, text: "Checkout is blank", toolName: "getVideoTranscript"),
                    .init(id: "actions-old", component: .userActions, text: "Click", toolName: "getUserEvents")],
            availability: [.init(component: .transcript, status: .available, message: "Imported."),
                           .init(component: .userActions, status: .available, message: "Imported."),
                           .init(component: .frame, status: .unavailable, message: "No frames.")])
        let refreshed = JamEvidenceReference(sourceURL: original.sourceURL, recordingID: "one", state: .ready,
            importedAt: Date(timeIntervalSince1970: 200),
            items: [.init(id: "frame-new", component: .frame, localPath: "feedback/frame.jpg", mimeType: "image/jpeg", toolName: "getFrames")],
            availability: [.init(component: .transcript, status: .failed, message: "Transport failed."),
                           .init(component: .userActions, status: .failed, message: "Transport failed."),
                           .init(component: .frame, status: .available, message: "Frames imported.")])
        let merged = try original.merging(refreshed)
        #expect(merged.importedAt == original.importedAt)
        #expect(merged.lastAttemptAt == refreshed.importedAt)
        #expect(Set(merged.items.map(\.id)) == ["transcript-old", "actions-old", "frame-new"])
        #expect(merged.availability.first { $0.component == .transcript }?.status == .available)
        #expect(merged.lastAttemptAvailability?.first { $0.component == .transcript }?.status == .failed)
        let failed = JamEvidenceReference(sourceURL: original.sourceURL, recordingID: "one", state: .unread,
            importedAt: Date(timeIntervalSince1970: 300), items: [],
            availability: [.init(component: .details, status: .failed, message: "Jam transport failed.")])
        let retained = try merged.merging(failed)
        #expect(retained.state == .ready)
        #expect(retained.items == merged.items)
    }
}
