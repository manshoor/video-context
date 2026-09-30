import Foundation

struct JamOAuthRevoker: JamTokenRevoking, Sendable {
    let clientID: @Sendable () -> String?
    let session: URLSession

    init(storage: JamOAuthCredentialStore, session: URLSession = .shared) {
        clientID = { storage.clientID }
        self.session = session
    }

    func revoke(_ token: String) async throws {
        var request = URLRequest(url: JamOAuthPolicy.revocationEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var values = ["token": token]
        if let id = clientID(), !id.isEmpty { values["client_id"] = id }
        request.httpBody = form(values)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw JamConnectionError.revocationFailed
        }
    }

    private func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let body: String = values.sorted { $0.key < $1.key }.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }
}
