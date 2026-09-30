import Foundation
import Observation
import VideoContextCore

@MainActor @Observable
final class ProviderCredential {
    var value = ""
    var state: CredentialState = .missing
    private(set) var edited = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let store: any APIKeyStoring
    @ObservationIgnored private var timeout: Task<Void, Never>?
    init(store: any APIKeyStoring) { self.store = store }
    var ready: Bool { state == .ready && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func edit(_ value: String) {
        generation += 1; timeout?.cancel(); self.value = value; edited = true
        state = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .missing : .ready
    }
    func load(mode: APIKeyAccessMode, retryAccessRequired: Bool = false) async {
        guard !edited, mode == .interactive || (state != .ready && state != .loading && (state != .accessRequired || retryAccessRequired)) else { return }
        generation += 1; let request = generation
        state = .loading; timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: mode == .interactive ? .seconds(30) : .seconds(3)) } catch { return }
            guard let self, generation == request else { return }
            generation += 1; state = .accessRequired
        }
        do {
            let loaded = try await SavedCredentialLookup.load(from: store, mode: mode)
            guard generation == request else { return }
            timeout?.cancel(); value = loaded ?? ""; state = value.isEmpty ? .missing : .ready
        } catch {
            guard generation == request else { return }
            timeout?.cancel()
            if case KeychainError.interactionNotAllowed = error { state = .accessRequired }
            else { state = .failed(error.localizedDescription) }
        }
    }
    func saveIfEdited() async throws {
        guard edited else { return }
        let request = generation
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if key.isEmpty { try await store.remove() } else { try await store.save(key) }
            guard request == generation else { return }
            value = key; edited = false; state = key.isEmpty ? .missing : .ready
        } catch {
            if request == generation { state = .failed(error.localizedDescription) }
            throw error
        }
    }
}
