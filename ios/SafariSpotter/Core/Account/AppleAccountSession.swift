import AuthenticationServices
import Combine
import Foundation
import Security

struct AppleAccountProfile: Codable, Equatable {
    let userID: String
    var displayName: String?
    var isSignedIn: Bool
}

protocol AppleAccountStorage {
    func read() throws -> AppleAccountProfile?
    func save(_ profile: AppleAccountProfile) throws
    func remove() throws
}

struct KeychainAppleAccountStore: AppleAccountStorage {
    let service: String

    init(service: String = "ch.solution21.safarispotter.apple-account") {
        self.service = service
    }

    private var item: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "profile"
        ]
    }

    func read() throws -> AppleAccountProfile? {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = value as? Data else { throw StoreError.invalidData }
        let profile = try JSONDecoder().decode(AppleAccountProfile.self, from: data)
        guard !profile.userID.isEmpty else { throw StoreError.invalidData }
        return profile
    }

    func save(_ profile: AppleAccountProfile) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(profile),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(item as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            try check(SecItemAdd(item.merging(attributes) { _, value in value } as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    func remove() throws {
        let status = SecItemDelete(item as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private enum StoreError: Error { case invalidData, keychain(OSStatus) }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
    }
}

/// Die Anmeldung hält nur das lokale Profil. Die Aufnahmen gehören zum Gerätespeicher der App.
@MainActor
final class AppleAccountSession: ObservableObject {
    @Published private var savedProfile: AppleAccountProfile?
    @Published private(set) var canReadProfile = false
    @Published private(set) var message: String?

    var profile: AppleAccountProfile? { savedProfile?.isSignedIn == true ? savedProfile : nil }
    var hasSavedProfile: Bool { savedProfile != nil }

    private let storage: AppleAccountStorage
    private let checkCredential: (String) async throws -> ASAuthorizationAppleIDProvider.CredentialState
    private var revision = 0

    init(storage: AppleAccountStorage = KeychainAppleAccountStore(),
         checkCredential: @escaping (String) async throws -> ASAuthorizationAppleIDProvider.CredentialState = {
             try await ASAuthorizationAppleIDProvider().credentialState(forUserID: $0)
         }) {
        self.storage = storage
        self.checkCredential = checkCredential
        loadProfile()
    }

    func completeSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                message = "Apple hat keine gültige Anmeldung zurückgegeben."
                return
            }
            let name = credential.fullName.map { PersonNameComponentsFormatter().string(from: $0) }
            signIn(userID: credential.user, displayName: name)
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code != .canceled {
                message = "Mit Apple anmelden ist momentan nicht möglich. Versuche es erneut."
            }
        }
    }

    func signIn(userID: String, displayName: String?) {
        guard canReadProfile, !userID.isEmpty else {
            message = "Das Profil kann momentan nicht gespeichert werden."
            return
        }
        let existingName = savedProfile?.userID == userID ? savedProfile?.displayName : nil
        save(.init(userID: userID, displayName: existingName ?? Self.cleanedName(displayName), isSignedIn: true))
    }

    func changeName(_ name: String) {
        guard var profile else { return }
        profile.displayName = Self.cleanedName(name)
        save(profile)
    }

    func signOut() {
        guard var profile else { return }
        profile.isSignedIn = false
        save(profile)
    }

    @discardableResult
    func removeProfile() -> Bool {
        do {
            try storage.remove()
            revision += 1
            savedProfile = nil
            canReadProfile = true
            message = nil
            return true
        } catch {
            message = "Das lokale Profil konnte nicht entfernt werden. Versuche es erneut."
            return false
        }
    }

    func refresh() async {
        if !canReadProfile { loadProfile() }
        guard let savedProfile else { return }
        let current = revision
        do {
            let state = try await checkCredential(savedProfile.userID)
            guard !Task.isCancelled, revision == current else { return }
            switch state {
            case .authorized:
                break
            case .revoked:
                if removeProfile() { message = "Der Apple-Zugriff wurde entzogen. Du kannst dich erneut anmelden." }
            case .notFound, .transferred:
                if savedProfile.isSignedIn { signOut() }
            @unknown default:
                break
            }
        } catch {
            // Eine vorübergehend fehlende Verbindung lässt das lokal gespeicherte Profil nutzbar.
        }
    }

    private func loadProfile() {
        do {
            savedProfile = try storage.read()
            canReadProfile = true
            message = nil
        } catch {
            message = "Das lokale Profil kann momentan nicht gelesen werden."
        }
    }

    private func save(_ value: AppleAccountProfile) {
        do {
            try storage.save(value)
            revision += 1
            savedProfile = value
            message = nil
        } catch {
            message = "Das lokale Profil konnte nicht gespeichert werden. Versuche es erneut."
        }
    }

    private static func cleanedName(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
    }
}
