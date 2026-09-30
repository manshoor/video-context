import Foundation
import Testing
import VideoContextCore
@testable import VideoContextApp

@MainActor
struct AccuracyProfileSettingsTests {
    @Test func independentStageSelectionsSurviveSaveAndReopen() async throws {
        let name = "AccuracyProfileSettingsTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appending(path: name)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let model = AppModel(libraryRoot: root, preferencesDefaults: defaults, showsDockActivity: false)
        model.transcriptionProvider = .localWhisper
        model.analysisProvider = .lmStudio
        model.lmStudioModelID = "existing-local-model"
        model.analysisReasoningEffort = .high
        model.documentationAnalysisOverride = .init(provider: .openAI, modelID: "gpt-6-astra", effort: .high)
        model.reviewAnalysisOverride = .init(provider: .claude, modelID: "claude-opus-5-5", effort: .high)
        #expect(await model.saveSettings())
        let reopened = AppModel(libraryRoot: root, preferencesDefaults: defaults, showsDockActivity: false)
        #expect(reopened.modelConfiguration.documentationConfiguration.selectedAnalysisModel == "gpt-6-astra")
        #expect(reopened.modelConfiguration.reviewConfiguration?.selectedAnalysisModel == "claude-opus-5-5")
        #expect(reopened.analysisReasoningEffort == .high)
        #expect(reopened.selectedAnalysisProviders.contains(.claude))
        #expect(reopened.selectedAnalysisProviders.contains(.openAI))
        #expect(reopened.analysisProvider == .lmStudio)
        #expect(reopened.lmStudioModelID == "existing-local-model")
        #expect(reopened.transcriptionProvider == .localWhisper)
    }

    @Test func accuracyProfileIsExplicitAndKeepsSpeechConfiguration() throws {
        let name = "AccuracyProfileOptIn-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appending(path: name)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let model = AppModel(libraryRoot: root, preferencesDefaults: defaults, showsDockActivity: false)
        #expect(model.reviewAnalysisOverride == nil)
        #expect(model.documentationAnalysisOverride == nil)
        model.transcriptionProvider = .localWhisper
        let speechModel = model.transcriptionModel
        model.applyAccuracyProfile()
        #expect(model.modelConfiguration.selectedAnalysisModel == "gpt-6-sol")
        #expect(model.modelConfiguration.taskConfiguration.selectedAnalysisModel == "gpt-6-astra")
        #expect(model.modelConfiguration.documentationConfiguration.reasoningEffort == .high)
        #expect(model.modelConfiguration.reviewConfiguration?.reasoningEffort == .high)
        #expect(model.transcriptionProvider == .localWhisper)
        #expect(model.transcriptionModel == speechModel)
        #expect(defaults.data(forKey: "VideoContext.preferences") == nil)
    }
}
