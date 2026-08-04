import Foundation
import LocalAuthentication

/// Biometric authentication service for Face ID / Touch ID
final class BiometricService {

    static let shared = BiometricService()

    private let context = LAContext()

    private init() {}

    enum BiometricType {
        case faceID
        case touchID
        case none
    }

    // MARK: - Availability

    var biometricType: BiometricType {
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .none
        }

        switch context.biometryType {
        case .faceID:
            return .faceID
        case .touchID:
            return .touchID
        default:
            return .none
        }
    }

    var isBiometricAvailable: Bool {
        biometricType != .none
    }

    // MARK: - Authentication

    func authenticate(reason: String = "Разблокировать O.R.I.O.N.") async -> Result<Void, Error> {
        let context = LAContext()
        context.localizedCancelTitle = "Ввести код"

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )

            if success {
                return .success(())
            } else {
                return .failure(BiometricError.authenticationFailed)
            }
        } catch let error {
            return .failure(error)
        }
    }

    // MARK: - Errors

    enum BiometricError: LocalizedError {
        case authenticationFailed
        case biometricNotAvailable
        case biometricNotEnrolled
        case biometricLockout

        var errorDescription: String? {
            switch self {
            case .authenticationFailed:
                return "Аутентификация не удалась"
            case .biometricNotAvailable:
                return "Биометрия недоступна на этом устройстве"
            case .biometricNotEnrolled:
                return "Биометрия не настроена"
            case .biometricLockout:
                return "Биометрия заблокирована. Используйте код."
            }
        }
    }
}
