import Foundation
import IOKit.pwr_mgt

final class AppNapManager {
    static let shared = AppNapManager()

    private var assertionID: IOPMAssertionID = 0
    private var assertionActive = false

    private init() {}

    func preventSleep(reason: String = "Playback active") {
        guard !assertionActive else { return }

        let reasonCF = reason as CFString
        let type = kIOPMAssertionTypePreventSystemSleep as CFString

        let status = IOPMAssertionCreateWithName(
            type,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reasonCF,
            &assertionID
        )

        assertionActive = status == kIOReturnSuccess
    }

    func allowSleep() {
        guard assertionActive else { return }
        IOPMAssertionRelease(assertionID)
        assertionActive = false
    }

    deinit {
        allowSleep()
    }
}
