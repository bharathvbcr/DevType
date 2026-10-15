import Foundation
import ExpanderEngine

enum LanguageDefaultsFixture {
    static func current() -> Any? {
        UserDefaults.standard.object(forKey: LocalizationManager.deviceKey)
    }

    static func restore(_ previous: Any?) {
        if let previous {
            UserDefaults.standard.set(previous, forKey: LocalizationManager.deviceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: LocalizationManager.deviceKey)
        }
    }
}
