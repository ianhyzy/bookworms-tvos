import Foundation

/// Enforced in worker builds, including UI-launched app processes and relaunches.
enum OfflineTestPolicy {
    static var isEnabled: Bool {
        #if BOOKWORMS_OFFLINE_TESTS
            return true
        #else
            return false
        #endif
    }

    static func data(for request: URLRequest, session: URLSession) async throws -> (
        Data, URLResponse
    ) {
        #if BOOKWORMS_OFFLINE_TESTS
            // Retain only our fixture protocols. Never retain Foundation's network protocols.
            let allowed = [
                "LocalResponseStub", "SocialResponseStub", "AuthenticationStub",
                "ScenarioURLProtocol",
            ]
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses =
                (session.configuration.protocolClasses ?? [])
                .filter { type in
                    let name = String(describing: type)
                    return allowed.contains(name)
                } + [OfflineDenyProtocol.self]
            let isolated = URLSession(configuration: configuration)
            defer { isolated.invalidateAndCancel() }
            return try await isolated.data(for: request)
        #else
            return try await session.data(for: request)
        #endif
    }
}

#if BOOKWORMS_OFFLINE_TESTS
    private final class OfflineDenyProtocol: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
        override func stopLoading() {}
    }
#endif
