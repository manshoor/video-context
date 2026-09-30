import Foundation

public struct JamEvidenceRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let component: JamEvidenceComponent
    public let timestampMilliseconds: Int?
    public let text: String?
    public let localPath: String?
    public let mimeType: String?
    public let toolName: String
    public let importedAt: Date?

    public init(id: String, component: JamEvidenceComponent, timestampMilliseconds: Int? = nil,
                text: String? = nil, localPath: String? = nil, mimeType: String? = nil, toolName: String,
                importedAt: Date? = nil) {
        self.id = id; self.component = component; self.timestampMilliseconds = timestampMilliseconds
        self.text = text; self.localPath = localPath; self.mimeType = mimeType; self.toolName = toolName
        self.importedAt = importedAt
    }
}

public struct JamEvidenceReference: Codable, Equatable, Sendable {
    public let sourceURL: String
    public let recordingID: String
    public let state: JamEvidenceReadState
    public let importedAt: Date
    public let items: [JamEvidenceRecord]
    public let availability: [JamEvidenceAvailability]
    public let lastAttemptAt: Date?
    public let lastAttemptAvailability: [JamEvidenceAvailability]?

    public init(sourceURL: String, recordingID: String, state: JamEvidenceReadState, importedAt: Date,
                items: [JamEvidenceRecord], availability: [JamEvidenceAvailability],
                lastAttemptAt: Date? = nil, lastAttemptAvailability: [JamEvidenceAvailability]? = nil) {
        self.sourceURL = sourceURL; self.recordingID = recordingID; self.state = state; self.importedAt = importedAt
        self.items = items; self.availability = availability
        self.lastAttemptAt = lastAttemptAt; self.lastAttemptAvailability = lastAttemptAvailability
    }

    public func merging(_ refreshed: JamEvidenceReference) throws -> JamEvidenceReference {
        guard sourceURL == refreshed.sourceURL, recordingID == refreshed.recordingID else { throw TaskContextError.conflict }
        var mergedItems: [JamEvidenceRecord] = []
        var mergedAvailability: [JamEvidenceAvailability] = []
        for component in JamEvidenceComponent.allCases {
            let old = availability.first { $0.component == component }
            let new = refreshed.availability.first { $0.component == component }
            let refreshedSuccessfully = new?.status == .available
            if let chosen = refreshedSuccessfully ? new : ((old?.status == .available ? old : nil) ?? new ?? old) {
                mergedAvailability.append(chosen)
            }
            mergedItems += (refreshedSuccessfully ? refreshed.items : items).filter { $0.component == component }
        }
        return .init(sourceURL: sourceURL, recordingID: recordingID,
                     state: state == .ready || refreshed.state == .ready ? .ready : .unread,
                     importedAt: importedAt, items: mergedItems, availability: mergedAvailability,
                     lastAttemptAt: refreshed.importedAt, lastAttemptAvailability: refreshed.availability)
    }

    public static func save(_ imported: JamImportedEvidence, batchID: String, sourceID: String,
                            paths: LibraryPaths) throws -> JamEvidenceReference {
        let directory = try paths.feedbackDirectory(id: batchID)
        var records: [JamEvidenceRecord] = []
        for (index, item) in imported.items.enumerated() {
            var localPath: String?
            if let bytes = item.imageData {
                let extensionName = item.mimeType?.lowercased().contains("png") == true ? "png" : "jpg"
                let destination = directory.appending(path: "\(sourceID)-jam-\(index)-\(UUID().uuidString.lowercased()).\(extensionName)")
                try bytes.write(to: destination, options: .atomic)
                localPath = paths.relativePath(for: destination)
            }
            records.append(.init(
                id: item.id, component: item.component, timestampMilliseconds: item.timestampMilliseconds,
                text: item.text, localPath: localPath, mimeType: item.mimeType, toolName: item.toolName,
                importedAt: imported.importedAt
            ))
        }
        return .init(sourceURL: imported.sourceURL, recordingID: imported.recordingID, state: imported.state,
                     importedAt: imported.importedAt, items: records, availability: imported.availability)
    }
}
