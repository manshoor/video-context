import Foundation
import Testing
@testable import VideoContextCore

struct AppActivityTests {
    @Test func progressIsStageScopedAndKeepsRecordingIdentity() {
        var activity = AppActivity(videoID: "vid_first", recordingTitle: "Same title", phase: .downloading)
        #expect(activity.fraction == nil)
        activity.update(.init(stage: .recognizingText, completed: 3, total: 12))
        #expect(activity.fraction == 0.25)
        activity.update(.init(stage: .analyzing, completed: 0, total: 4))
        #expect(activity.fraction == 0)
        #expect(activity.videoID == "vid_first")
        activity.update(.init(stage: .capturingFrames))
        #expect(activity.fraction == nil)
        activity.update(.init(stage: .recognizingText, completed: 0, total: 0))
        #expect(activity.fraction == nil)
    }

    @Test func sourceRefreshPreservesDraftAndCancelUsesLatestSource() {
        var editor = BriefEditorState(source: "Original")
        editor.begin()
        editor.draft = "My unsaved correction"
        editor.refresh("New generated source")
        #expect(editor.draft == "My unsaved correction")
        #expect(editor.isEditing)
        editor.cancel()
        #expect(editor.draft == "New generated source")
        #expect(!editor.isEditing)
    }

    @Test func editsWhileSaveIsPendingRemainOpen() {
        var editor = BriefEditorState(source: "Original")
        editor.begin()
        editor.draft = "Second edit"
        editor.saved("First edit")
        #expect(editor.isEditing)
        #expect(editor.draft == "Second edit")
    }
}
