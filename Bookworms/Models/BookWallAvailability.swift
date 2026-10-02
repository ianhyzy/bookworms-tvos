import Darwin
import Foundation

/// Keeps the physics view on Apple TV 4K (2nd generation) and newer hardware.
enum BookWallAvailability {
    static var isSupported: Bool {
        #if targetEnvironment(simulator)
            true
        #else
            var size = 0
            guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else {
                return false
            }
            var bytes = [CChar](repeating: 0, count: size)
            guard sysctlbyname("hw.machine", &bytes, &size, nil, 0) == 0 else {
                return false
            }
            return supports(machineIdentifier: String(cString: bytes))
        #endif
    }

    static func supports(machineIdentifier: String) -> Bool {
        guard machineIdentifier.hasPrefix("AppleTV"),
            let major = Int(
                machineIdentifier.dropFirst("AppleTV".count).split(separator: ",").first ?? "")
        else { return false }
        return major >= 11
    }
}
