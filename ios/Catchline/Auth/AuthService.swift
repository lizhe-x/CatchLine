import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import UIKit

enum AuthError: LocalizedError {
    case notSignedIn
    case cancelled
    case badCallback
    case tokenEndpoint(Int, String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "请先登录"
        case .cancelled: "已取消登录"
        case .badCallback: "登录回调无效"
        case let .tokenEndpoint(status, body): "登录服务返回错误（\(status)）：\(body)"
        }
    }
}

/// Cognito Managed Login via OAuth 2.0 Authorization Code + PKCE.
///
/// The hosted page runs in `ASWebAuthenticationSession` (system browser
/// sheet, shares Safari's cookies — the app never sees the password). The
/// refresh token lives in the Keychain; access tokens only in memory.
@Observable
final class AuthService {
    private(set) var isSignedIn: Bool
    private(set) var email: String?

    private var accessToken: String?
    private var accessTokenExpiry = Date.distantPast
    private var refreshTask: Task<String, Error>?
    private let keychain = KeychainItem(account: "cognito-refresh-token")
    private let presenter = PresentationAnchor()

    init() {
        isSignedIn = AppConfig.useLocalMock || keychain.read() != nil
        email = UserDefaults.standard.string(forKey: "catchline.email")
    }

    func signIn() async throws {
        let verifier = Self.randomURLSafe(bytes: 32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
        let state = Self.randomURLSafe(bytes: 16)

        var components = URLComponents(url: AppConfig.cognitoDomain.appending(path: "oauth2/authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: AppConfig.cognitoClientID),
            .init(name: "redirect_uri", value: AppConfig.redirectURI),
            .init(name: "scope", value: "openid email profile"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]

        let callback = try await presenter.authenticate(url: components.url!, scheme: AppConfig.callbackScheme)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value
        else { throw AuthError.badCallback }

        let tokens = try await tokenRequest([
            "grant_type": "authorization_code",
            "client_id": AppConfig.cognitoClientID,
            "code": code,
            "redirect_uri": AppConfig.redirectURI,
            "code_verifier": verifier,
        ])
        guard let refresh = tokens.refreshToken else { throw AuthError.badCallback }
        keychain.write(refresh)
        store(tokens)
        isSignedIn = true
    }

    /// A non-expired access token, refreshing it if needed. Throws
    /// `AuthError.notSignedIn` when the session is gone (user must sign in).
    func validAccessToken() async throws -> String {
        if let accessToken, accessTokenExpiry.timeIntervalSinceNow > 60 { return accessToken }
        if let refreshTask { return try await refreshTask.value }
        guard let refresh = keychain.read() else { throw AuthError.notSignedIn }

        let task = Task { () throws -> String in
            do {
                let tokens = try await tokenRequest([
                    "grant_type": "refresh_token",
                    "client_id": AppConfig.cognitoClientID,
                    "refresh_token": refresh,
                ])
                store(tokens)
                return tokens.accessToken
            } catch AuthError.tokenEndpoint(let status, _) where status == 400 {
                // invalid_grant: refresh token expired or revoked.
                signOutLocally()
                throw AuthError.notSignedIn
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    func signOut() async {
        if let refresh = keychain.read() {
            // Best effort: revoke so the refresh token can't be reused.
            var request = URLRequest(url: AppConfig.cognitoDomain.appending(path: "oauth2/revoke"))
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formEncode(["token": refresh, "client_id": AppConfig.cognitoClientID])
            _ = try? await URLSession.shared.data(for: request)
        }
        signOutLocally()
    }

    private func signOutLocally() {
        keychain.delete()
        accessToken = nil
        accessTokenExpiry = .distantPast
        email = nil
        UserDefaults.standard.removeObject(forKey: "catchline.email")
        isSignedIn = AppConfig.useLocalMock
    }

    private func store(_ tokens: TokenResponse) {
        accessToken = tokens.accessToken
        accessTokenExpiry = Date.now.addingTimeInterval(TimeInterval(tokens.expiresIn))
        if let idToken = tokens.idToken, let claim = Self.jwtClaim("email", in: idToken) {
            email = claim
            UserDefaults.standard.set(claim, forKey: "catchline.email")
        }
    }

    private func tokenRequest(_ form: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: AppConfig.cognitoDomain.appending(path: "oauth2/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(form)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw AuthError.tokenEndpoint(status, String(decoding: data.prefix(200), as: UTF8.self))
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let idToken: String?
        let refreshToken: String?
        let expiresIn: Int

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case idToken = "id_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    private static func randomURLSafe(bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return data.base64URLEncoded()
    }

    private static func formEncode(_ form: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)!
    }

    /// Reads a claim from a JWT payload without verifying it — only used for
    /// display (the email); the API verifies tokens server-side.
    private static func jwtClaim(_ name: String, in jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object[name] as? String
    }
}

/// Bridges ASWebAuthenticationSession to async/await and supplies the window.
private final class PresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func authenticate(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(scheme)) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: AuthError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? AuthError.badCallback)
                }
            }
            session.presentationContextProvider = self
            self.session = session
            session.start()
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

/// Minimal Keychain wrapper for one string, device-only, after first unlock
/// (so token refresh works while the phone is locked during a session).
struct KeychainItem {
    let account: String
    private let service = "com.deskfox.catchline.auth"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String) {
        delete()
        var q = query
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
