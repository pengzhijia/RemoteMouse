import Foundation

enum PairingSettings {
    private static let key = "PairingPIN"

    static func isValid(_ value: String) -> Bool {
        value.utf8.count == 4 && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    static func pin(in defaults: UserDefaults = .standard) -> String {
        guard let value = defaults.string(forKey: key), isValid(value) else { return "1111" }
        return value
    }

    @discardableResult
    static func save(_ value: String, in defaults: UserDefaults = .standard) -> Bool {
        guard isValid(value) else { return false }
        defaults.set(value, forKey: key)
        return true
    }
}
