import CryptoKit
import DeviceCheck
import Foundation

/// What the server says the user is entitled to right now.
struct PlanStatus: Decodable, Equatable {
    enum Kind: String, Decodable { case free, trial, paid }

    let kind: Kind
    let quotaSeconds: Int
    let usedSeconds: Int
    let remainingSeconds: Int
    let resetsAt: Date?
    let endsAt: Date?
    let productId: String?
}

struct SessionLease: Decodable {
    let apiKey: String
    let leaseSeconds: Int
    let plan: PlanStatus
}

enum APIError: LocalizedError {
    case quotaExhausted(PlanStatus?)
    case attestationUnsupported
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .quotaExhausted: String(localized: "You’ve used up your allowance")
        case .attestationUnsupported: String(localized: "This device doesn’t support App Attest")
        case let .http(status, code): String(localized: "Server error (\(String(status)) \(code))")
        }
    }
}

/// Talks to the CatchLine backend. Every metered call is signed with an App
/// Attest assertion over the exact request body, so the server knows it came
/// from our genuine app on a real device — no account needed.
final class APIClient {
    private let attest = DCAppAttestService.shared
    private let keyItem = KeychainItem(account: "app-attest-key-id")
    private var registration: Task<String, Error>?
    /// Signed requests go out one at a time: App Attest assertions carry an
    /// increasing counter, and the server rejects any that arrive out of order.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601WithFractionalSeconds
        return d
    }()

    /// Supplies the current StoreKit entitlement JWS, if any.
    var entitlementProvider: () async -> String? = { nil }

    func status() async throws -> PlanStatus {
        struct Body: Decodable { let plan: PlanStatus }
        return try await signedPost("api/session/status", as: Body.self).plan
    }

    func startSession() async throws -> SessionLease {
        try await signedPost("api/session", as: SessionLease.self)
    }

    func endSession() async throws -> PlanStatus {
        struct Body: Decodable { let plan: PlanStatus }
        return try await signedPost("api/session/end", as: Body.self).plan
    }

    // MARK: - Signed requests

    private struct ErrorBody: Decodable {
        let error: String
        let plan: PlanStatus?
    }

    private struct RequestBody: Encodable {
        let userId: String
        let ts: Int64
        let timeZone: String
        let entitlement: String?
    }

    private func signedPost<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        return try await sendSigned(path, as: type, retried: false)
    }

    private func sendSigned<T: Decodable>(_ path: String, as type: T.Type, retried: Bool) async throws -> T {
        let body = RequestBody(
            userId: UserIdentity.current.uuidString.lowercased(),
            ts: Int64(Date.now.timeIntervalSince1970 * 1000),
            timeZone: TimeZone.current.identifier,
            entitlement: await entitlementProvider()
        )
        let data = try JSONEncoder().encode(body)
        var request = URLRequest(url: AppConfig.apiBase.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        if !AppConfig.useLocalMock {
            let keyId = try await registeredKeyId()
            let assertion: Data
            do {
                assertion = try await attest.generateAssertion(keyId, clientDataHash: Data(SHA256.hash(data: data)))
            } catch let error as DCError where !retried && [.invalidKey, .invalidInput].contains(error.code) {
                // The Secure Enclave no longer accepts this key (restored device, or a
                // build with a different App Attest environment): re-attest once.
                keyItem.delete()
                return try await sendSigned(path, as: type, retried: true)
            }
            request.setValue(keyId, forHTTPHeaderField: "X-Attest-Key-Id")
            request.setValue(assertion.base64EncodedString(), forHTTPHeaderField: "X-Attest-Assertion")
        }

        let (responseData, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 200 { return try decoder.decode(T.self, from: responseData) }

        let error = try? decoder.decode(ErrorBody.self, from: responseData)
        if status == 402 { throw APIError.quotaExhausted(error?.plan) }
        // Server lost or rejected our key (e.g. app reinstalled from backup): re-attest once.
        if status == 401, !retried, ["unknown_key", "invalid_assertion"].contains(error?.error) {
            keyItem.delete()
            return try await sendSigned(path, as: type, retried: true)
        }
        throw APIError.http(status, error?.error ?? "")
    }

    /// The App Attest key for this install, generating and registering it with
    /// the server on first use. The private key never leaves the Secure Enclave.
    private func registeredKeyId() async throws -> String {
        if let keyId = keyItem.read() { return keyId }
        // Concurrent first calls (status + start) must share one registration.
        if let registration { return try await registration.value }
        let task = Task { try await register() }
        registration = task
        defer { registration = nil }
        return try await task.value
    }

    private func register() async throws -> String {
        guard attest.isSupported else { throw APIError.attestationUnsupported }

        let keyId = try await attest.generateKey()
        struct Challenge: Decodable { let challenge: String }
        let challenge = try await post("api/attest/challenge", json: [String: String](), as: Challenge.self).challenge
        let attestation = try await attest.attestKey(keyId, clientDataHash: Data(SHA256.hash(data: Data(challenge.utf8))))
        struct OK: Decodable { let ok: Bool }
        _ = try await post("api/attest/register", json: [
            "keyId": keyId,
            "attestation": attestation.base64EncodedString(),
            "challenge": challenge,
            "userId": UserIdentity.current.uuidString.lowercased(),
        ], as: OK.self)
        keyItem.write(keyId)
        return keyId
    }

    private func post<T: Decodable>(_ path: String, json: [String: String], as type: T.Type) async throws -> T {
        var request = URLRequest(url: AppConfig.apiBase.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(json)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw APIError.http(status, String(decoding: data.prefix(100), as: UTF8.self)) }
        return try decoder.decode(T.self, from: data)
    }
}

extension JSONDecoder.DateDecodingStrategy {
    /// The server sends `Date.toISOString()` (with milliseconds).
    static let iso8601WithFractionalSeconds = custom { decoder in
        let string = try decoder.singleValueContainer().decode(String.self)
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) { return date }
        if let date = try? Date.ISO8601FormatStyle().parse(string) { return date }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(string)"))
    }
}
