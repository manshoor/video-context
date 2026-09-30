import Foundation
import Testing
import VideoContextCore
@testable import VideoContextApp

@MainActor
struct UsageClearingAppTests {
    @Test func confirmationCancelClearAndRepeatedClicks() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(libraryRoot: root, showsDockActivity: false)
        let store = try #require(model.store)
        let video = VideoRecord(title: "Fixture title", source: .localFile, sourceValue: "fixture", mediaRelativePath: "a.mp4")
        try await store.createVideo(video)
        let run = try await store.startUsageRun(.init(videoID: video.id, operation: .processing, provider: .lmStudio, model: "fixture"))
        try await store.finishUsageRun(id: run.id, outcome: .completed)
        _ = try await store.startUsageRun(.init(videoID: video.id, operation: .processing, provider: .lmStudio, model: "active"))
        let clearing = UsageClearingModel()
        await clearing.prepare(.recording(video.id), model: model)
        #expect(clearing.showsConfirmation)
        #expect(clearing.confirmationText.contains(video.id))
        #expect(clearing.confirmationText.contains("Retain 1 active run"))
        #expect(clearing.confirmationText.contains("hidden by filters"))
        clearing.cancel()
        #expect(clearing.preview == nil && clearing.showsConfirmation == false)
        #expect(try await store.usageSnapshot().runs.count == 2)
        await clearing.prepare(.recording(video.id), model: model)
        let revision = model.usageRevision
        async let first: Void = clearing.confirm(model: model)
        async let second: Void = clearing.confirm(model: model)
        _ = await (first, second)
        #expect(model.usageRevision == revision + 1)
        #expect(clearing.success?.contains("Cleared 1 run") == true)
        #expect(clearing.isBusy == false && clearing.error == nil)
        #expect(try await store.usageSnapshot().runs.count == 1)
        await clearing.prepare(.library, model: model)
        #expect(clearing.error?.contains("no finished usage") == true)
    }

    @Test func staleConfirmationShowsErrorWithoutFalseSuccess() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(libraryRoot: root, showsDockActivity: false)
        let store = try #require(model.store)
        let run = try await store.startUsageRun(.init(videoID: nil, operation: .modelTest, provider: .lmStudio, model: "fixture"))
        try await store.finishUsageRun(id: run.id, outcome: .completed)
        let clearing = UsageClearingModel()
        await clearing.prepare(.run(run.id), model: model)
        try await store.saveUsageAttempt(.init(runID: run.id, stage: .modelTest, provider: .lmStudio, requestedModel: "fixture"))
        await clearing.confirm(model: model)
        #expect(clearing.error?.contains("Nothing was cleared") == true)
        #expect(clearing.success == nil && clearing.isBusy == false)
        #expect(try await store.usageSnapshot().runs.count == 1)
    }
}
