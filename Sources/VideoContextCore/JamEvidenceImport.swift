import Foundation

public struct JamLink: Equatable, Sendable {
    public static let allowedHosts: Set<String> = ["jam.dev", "www.jam.dev", "app.jam.dev"]
    public let url: URL
    public let recordingID: String

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), Self.allowedHosts.contains(host),
              url.user == nil, url.password == nil else { return nil }
        let components = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard let recordingID = components.last, !recordingID.isEmpty else { return nil }
        self.url = url
        self.recordingID = recordingID
    }
}

public struct JamToolDescriptor: Equatable, Sendable {
    public let name: String
    public let inputProperties: Set<String>
    public let inputSchema: JamJSONValue?
    public init(name: String, inputProperties: Set<String> = []) {
        self.name = name
        self.inputProperties = inputProperties
        self.inputSchema = nil
    }
    public init(name: String, inputSchema: JamJSONValue) {
        self.name = name
        self.inputSchema = inputSchema
        self.inputProperties = Set(inputSchema.objectValue?["properties"]?.objectValue?.keys ?? Dictionary<String, JamJSONValue>().keys)
    }
    public func validates(_ arguments: [String: JamJSONValue]) -> Bool {
        inputSchema.map { JamJSONValue.object(arguments).conforms(to: $0) } ?? true
    }
}

public enum JamToolContent: Equatable, Sendable {
    case text(String)
    case image(data: Data, mimeType: String)
}

public struct JamToolResponse: Equatable, Sendable {
    public let content: [JamToolContent]
    public let isError: Bool
    public init(content: [JamToolContent], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }
    public static func text(_ text: String) -> Self { .init(content: [.text(text)]) }
}

public protocol JamToolCalling: Sendable {
    func listTools() async throws -> [JamToolDescriptor]
    func callTool(name: String, arguments: [String: JamJSONValue]) async throws -> JamToolResponse
}

public enum JamReadToolPolicy {
    public static let allowedTools: Set<String> = [
        "getDetails", "getVideoTranscript", "getFrames", "getScreenshots",
        "getUserEvents", "getConsoleLogs", "getNetworkRequests"
    ]
}

public enum JamEvidenceComponent: String, Codable, CaseIterable, Sendable {
    case details
    case transcript
    case frame
    case userActions
    case consoleErrors
    case failedRequests
}

public enum JamEvidenceAvailabilityStatus: String, Codable, Sendable {
    case available
    case unavailable
    case unsupported
    case failed
}

public struct JamEvidenceAvailability: Codable, Equatable, Sendable {
    public let component: JamEvidenceComponent
    public let status: JamEvidenceAvailabilityStatus
    public let message: String
    public init(component: JamEvidenceComponent, status: JamEvidenceAvailabilityStatus, message: String) {
        self.component = component; self.status = status; self.message = message
    }
}

public enum JamEvidenceReadState: String, Codable, Sendable { case unread, ready }

public struct JamImportedEvidenceItem: Equatable, Sendable, Identifiable {
    public let id: String
    public let component: JamEvidenceComponent
    public let timestampMilliseconds: Int?
    public let text: String?
    public let imageData: Data?
    public let mimeType: String?
    public let toolName: String
    public init(id: String = "jamitem_\(UUID().uuidString.lowercased())", component: JamEvidenceComponent,
                timestampMilliseconds: Int? = nil, text: String? = nil, imageData: Data? = nil, mimeType: String? = nil,
                toolName: String) {
        self.id = id; self.component = component; self.timestampMilliseconds = timestampMilliseconds
        self.text = text; self.imageData = imageData; self.mimeType = mimeType; self.toolName = toolName
    }
}

public struct JamImportedEvidence: Equatable, Sendable {
    public let sourceURL: String
    public let recordingID: String
    public let state: JamEvidenceReadState
    public let importedAt: Date
    public let items: [JamImportedEvidenceItem]
    public let availability: [JamEvidenceAvailability]
    public init(sourceURL: String, recordingID: String, state: JamEvidenceReadState, importedAt: Date = .now,
                items: [JamImportedEvidenceItem], availability: [JamEvidenceAvailability]) {
        self.sourceURL = sourceURL; self.recordingID = recordingID; self.state = state; self.importedAt = importedAt
        self.items = items; self.availability = availability
    }
}

public struct JamEvidenceImporter: Sendable {
    public let client: any JamToolCalling
    public init(client: any JamToolCalling) { self.client = client }

    public func importEvidence(from url: URL) async throws -> JamImportedEvidence {
        guard let link = JamLink(url: url) else {
            throw TaskContextError.invalid("Use a Jam recording link from jam.dev.")
        }
        try Task.checkCancellation()
        let advertised = try await client.listTools()
        let tools = Dictionary(uniqueKeysWithValues: advertised.map { ($0.name, $0) })
        guard let details = tools["getDetails"], JamReadToolPolicy.allowedTools.contains(details.name) else {
            return unread(link, message: "Jam did not advertise the required getDetails read tool.")
        }

        var items: [JamImportedEvidenceItem] = []
        var availability: [JamEvidenceAvailability] = []
        do {
            let response = try await call(details, link: link)
            guard response.isError == false else {
                return unread(link, message: responseReason(response, fallback: "The Jam recording could not be read or is unavailable."))
            }
            guard let text = joinedSafeText(response), !text.isEmpty else {
                return unread(link, message: "The Jam recording could not be read or is unavailable.")
            }
            items.append(.init(component: .details, text: text, toolName: "getDetails"))
            availability.append(.init(component: .details, status: .available, message: "Recording details imported."))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TaskContextError {
            return unread(link, message: boundedReason(error.localizedDescription))
        } catch {
            return unread(link, message: "Jam transport failed while reading recording details.")
        }

        try await importText(
            toolName: "getVideoTranscript", component: .transcript, tools: tools, link: link,
            unsupported: "Transcript unavailable. Jam transcripts require microphone audio.",
            empty: "Jam did not return a transcript.", items: &items, availability: &availability
        )
        try await importFrames(tools: tools, link: link, items: &items, availability: &availability)
        try await importText(
            toolName: "getUserEvents", component: .userActions, tools: tools, link: link,
            unsupported: "User actions are not available for this recording.",
            empty: "Jam did not return user actions.", items: &items, availability: &availability
        )
        try await importText(
            toolName: "getConsoleLogs", component: .consoleErrors, tools: tools, link: link,
            extra: ["logLevel": .string("error")], unsupported: "Console errors are not available for this recording.",
            empty: "Jam did not return console errors.", items: &items, availability: &availability
        )
        try await importFailedRequests(tools: tools, link: link, items: &items, availability: &availability)

        return .init(sourceURL: link.url.absoluteString, recordingID: link.recordingID, state: .ready,
                     items: items, availability: availability)
    }

    private func unread(_ link: JamLink, message: String) -> JamImportedEvidence {
        .init(sourceURL: link.url.absoluteString, recordingID: link.recordingID, state: .unread, items: [],
              availability: [.init(component: .details, status: .failed, message: message)])
    }

    private func importText(
        toolName: String,
        component: JamEvidenceComponent,
        tools: [String: JamToolDescriptor],
        link: JamLink,
        extra: [String: JamJSONValue] = [:],
        unsupported: String,
        empty: String,
        items: inout [JamImportedEvidenceItem],
        availability: inout [JamEvidenceAvailability]
    ) async throws {
        guard let tool = tools[toolName], JamReadToolPolicy.allowedTools.contains(toolName) else {
            availability.append(.init(component: component, status: .unsupported, message: unsupported))
            return
        }
        try Task.checkCancellation()
        do {
            let response = try await call(tool, link: link, extra: extra)
            guard response.isError == false else {
                let reason = responseReason(response, fallback: empty)
                availability.append(.init(component: component, status: classifiedFailure(reason), message: reason))
                return
            }
            if component == .consoleErrors && isEmptyResult(response) {
                availability.append(.init(component: component, status: .available, message: "No matching errors recorded."))
                return
            }
            if isEmptyResult(response) {
                availability.append(.init(component: component, status: .unavailable, message: empty))
                return
            }
            guard let text = joinedSafeText(response), !text.isEmpty else {
                availability.append(.init(component: component, status: .unavailable, message: empty))
                return
            }
            items.append(.init(component: component, text: text, toolName: toolName))
            availability.append(.init(component: component, status: .available, message: "Imported from \(toolName)."))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TaskContextError {
            availability.append(.init(component: component, status: .failed,
                                      message: boundedReason(error.localizedDescription)))
        } catch {
            availability.append(.init(component: component, status: .failed, message: "Jam transport failed while reading \(component.rawValue)."))
        }
    }

    private func importFrames(
        tools: [String: JamToolDescriptor],
        link: JamLink,
        items: inout [JamImportedEvidenceItem],
        availability: inout [JamEvidenceAvailability]
    ) async throws {
        guard let tool = tools["getFrames"], JamReadToolPolicy.allowedTools.contains(tool.name) else {
            availability.append(.init(component: .frame, status: .unsupported,
                                      message: "Video frames are not supported for this recording. Instant Replay and some hosted recordings exclude frame access."))
            return
        }
        try Task.checkCancellation()
        do {
            let response = try await call(tool, link: link, extra: ["overview": .bool(true)])
            guard response.isError == false else {
                let reason = responseReason(response, fallback: "Jam could not return video frames.")
                availability.append(.init(component: .frame, status: classifiedFailure(reason), message: reason))
                return
            }
            var timestamp: Int?
            let initialCount = items.count
            for content in response.content {
                switch content {
                case .text(let text): timestamp = timestampMilliseconds(in: text) ?? timestamp
                case .image(let data, let mimeType):
                    items.append(.init(component: .frame, timestampMilliseconds: timestamp, imageData: data,
                                       mimeType: mimeType, toolName: "getFrames"))
                    timestamp = nil
                }
            }
            if items.count == initialCount {
                let reason = joinedSafeText(response).map(boundedReason) ?? "Jam did not return video frames."
                availability.append(.init(component: .frame, status: classifiedFailure(reason), message: reason))
            } else {
                availability.append(.init(component: .frame, status: .available, message: "Video frames imported."))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TaskContextError {
            availability.append(.init(component: .frame, status: .failed,
                                      message: boundedReason(error.localizedDescription)))
        } catch {
            availability.append(.init(component: .frame, status: .failed, message: "Jam transport failed while reading frames."))
        }
    }

    private func importFailedRequests(
        tools: [String: JamToolDescriptor],
        link: JamLink,
        items: inout [JamImportedEvidenceItem],
        availability: inout [JamEvidenceAvailability]
    ) async throws {
        guard let tool = tools["getNetworkRequests"], JamReadToolPolicy.allowedTools.contains(tool.name) else {
            availability.append(.init(component: .failedRequests, status: .unsupported,
                                      message: "Failed network requests are not available for this recording."))
            return
        }
        var imported = 0
        var failures: [String] = []
        var successfulCalls = 0
        let statusFilters: [String?] = tool.inputProperties.contains("statusCode") ? ["4xx", "5xx"] : [nil]
        for status in statusFilters {
            try Task.checkCancellation()
            do {
                let extra: [String: JamJSONValue] = status.map { ["statusCode": .string($0)] } ?? [:]
                let response = try await call(tool, link: link, extra: extra)
                guard response.isError == false else {
                    failures.append(responseReason(response, fallback: "Jam could not read failed requests."))
                    continue
                }
                successfulCalls += 1
                for content in response.content {
                    guard case .text(let text) = content, let summary = sanitizeNetworkText(text) else { continue }
                    items.append(.init(component: .failedRequests, text: summary, toolName: "getNetworkRequests"))
                    imported += 1
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as TaskContextError {
                failures.append(boundedReason(error.localizedDescription))
            } catch {
                failures.append("Jam transport failed while reading failed requests.")
            }
        }
        availability.append(.init(
            component: .failedRequests,
            status: imported > 0 || (successfulCalls > 0 && failures.isEmpty) ? .available : failures.isEmpty ? .unavailable : .failed,
            message: imported > 0 ? "Failed request summaries imported without headers or bodies." :
                failures.first ?? (successfulCalls > 0 ? "No matching errors recorded." : "Jam did not return safe failed-request summaries.")
        ))
    }

    private func call(_ tool: JamToolDescriptor, link: JamLink, extra: [String: JamJSONValue] = [:]) async throws -> JamToolResponse {
        guard JamReadToolPolicy.allowedTools.contains(tool.name) else {
            throw TaskContextError.invalid("Jam tool is not in the read-only allowlist.")
        }
        var arguments: [String: JamJSONValue]
        if tool.inputProperties.contains("jamUrl") { arguments = ["jamUrl": .string(link.url.absoluteString)] }
        else if tool.inputProperties.contains("jamId") { arguments = ["jamId": .string(link.recordingID)] }
        else if tool.inputProperties.contains("id") { arguments = ["id": .string(link.recordingID)] }
        else { throw TaskContextError.invalid("Jam tool does not accept a recording reference.") }
        for (key, value) in extra where tool.inputProperties.contains(key) { arguments[key] = value }
        guard tool.validates(arguments) else { throw TaskContextError.invalid("Jam tool arguments did not match the advertised schema.") }
        return try await client.callTool(name: tool.name, arguments: arguments)
    }

    private func responseReason(_ response: JamToolResponse, fallback: String) -> String {
        joinedSafeText(response).map(boundedReason) ?? fallback
    }

    private func boundedReason(_ input: String) -> String {
        String(sanitizePlainSecrets(input).prefix(512))
    }

    private func classifiedFailure(_ reason: String) -> JamEvidenceAvailabilityStatus {
        let text = reason.lowercased()
        if text.contains("invalid argument") || text.contains("schema") || text.contains("must be") || text.contains("expected") { return .failed }
        if text.contains("unsupported") || text.contains("not supported") || text.contains("unavailable") ||
           text.contains("not available") || text.contains("instant replay") || text.contains("hosted recording") ||
           text.contains("cloudflare stream") { return .unsupported }
        return .unavailable
    }

    private func isEmptyResult(_ response: JamToolResponse) -> Bool {
        if response.content.isEmpty { return true }
        return response.content.allSatisfy { content in
            guard case .text(let text) = content else { return false }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "[]" || trimmed == "null" || trimmed == "{}" { return true }
            guard let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] else { return false }
            for key in ["logs", "errors", "requests", "networkRequests", "results", "data"] {
                if let values = object[key] as? [Any] { return values.isEmpty }
            }
            return false
        }
    }

    private func joinedSafeText(_ response: JamToolResponse) -> String? {
        let values = response.content.compactMap { content -> String? in
            guard case .text(let text) = content else { return nil }
            return sanitizeText(text)
        }.filter { !$0.isEmpty }
        return values.isEmpty ? nil : values.joined(separator: "\n")
    }

    private func sanitizeText(_ text: String) -> String {
        if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
           let sanitized = sanitizeJSON(object), JSONSerialization.isValidJSONObject(sanitized),
           let data = try? JSONSerialization.data(withJSONObject: sanitized, options: [.sortedKeys]),
           let value = String(data: data, encoding: .utf8) {
            return value
        }
        return sanitizePlainSecrets(text)
    }

    private func sanitizePlainSecrets(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?i)bearer\s+[a-z0-9._~+/=-]+"#,
                                  with: "Bearer [REDACTED]", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\b(?:authorization|cookie|set-cookie|access[_-]?token|refresh[_-]?token|api[_-]?key|password|secret)\b\s*[:=]\s*(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)"#,
                                  with: "[REDACTED]", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)([?&](?:token|access_token|refresh_token|api_key|key|code|secret|password)=)[^&\s]+"#,
                                  with: "$1[REDACTED]", options: .regularExpression)
    }

    private func sanitizeNetworkText(_ text: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return nil }
        let failed = failedNetworkValues(object)
        guard !failed.isEmpty else { return nil }
        let sanitized = failed.compactMap { sanitizeJSON($0) }
        guard JSONSerialization.isValidJSONObject(sanitized),
              let data = try? JSONSerialization.data(withJSONObject: sanitized, options: [.sortedKeys]),
              let result = String(data: data, encoding: .utf8) else { return nil }
        return result
    }

    private func failedNetworkValues(_ value: Any) -> [Any] {
        if let values = value as? [Any] { return values.filter(isFailedNetworkValue) }
        if let object = value as? [String: Any] {
            for key in ["requests", "networkRequests", "data", "results"] {
                if let values = object[key] as? [Any] { return values.filter(isFailedNetworkValue) }
            }
            return isFailedNetworkValue(object) ? [object] : []
        }
        return []
    }

    private func isFailedNetworkValue(_ value: Any) -> Bool {
        guard let object = value as? [String: Any] else { return false }
        let raw = object["statusCode"] ?? object["status"] ?? (object["response"] as? [String: Any])?["status"]
        let status = (raw as? NSNumber)?.intValue ?? Int(raw as? String ?? "")
        return status.map { $0 >= 400 } ?? false
    }

    private func sanitizeJSON(_ value: Any) -> Any? {
        if let object = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, child) in object where !isSensitiveKey(key) {
                if let sanitized = sanitizeJSON(child) { result[key] = sanitized }
            }
            return result
        }
        if let array = value as? [Any] { return array.compactMap(sanitizeJSON) }
        if let text = value as? String { return sanitizePlainSecrets(text) }
        if value is NSNull || value is NSNumber { return value }
        return nil
    }

    private func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased().filter(\.isLetter)
        return normalized == "body" || normalized.contains("requestbody") || normalized.contains("responsebody") ||
            normalized.contains("header") || normalized.contains("authorization") || normalized.contains("cookie") ||
            normalized.contains("token") || normalized.contains("secret") || normalized.contains("password") ||
            normalized.contains("apikey")
    }

    private func timestampMilliseconds(in text: String) -> Int? {
        let expression = try? NSRegularExpression(pattern: #"(?i)(?:^|\s)(?:t|timestamp)\s*[=:]\s*(\d+)"#)
        let ns = text as NSString
        guard let match = expression?.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        return Int(ns.substring(with: match.range(at: 1)))
    }
}
