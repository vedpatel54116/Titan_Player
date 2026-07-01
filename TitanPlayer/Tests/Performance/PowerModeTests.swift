import XCTest
@testable import TitanPlayer

final class PowerModeTests: XCTestCase {

    // MARK: - Auto derivation

    func test_derive_auto_returns_performance_for_nominal_plugged_in() {
        let s = SystemStateFixture.nominal()
        XCTAssertEqual(
            PowerMode.derived(from: s, isExternalPower: true),
            .performance
        )
    }

    func test_derive_auto_returns_battery_when_low_power_mode_enabled() {
        let s = SystemStateFixture.nominal().with(isLowPowerMode: true)
        XCTAssertEqual(
            PowerMode.derived(from: s, isExternalPower: true),
            .battery
        )
    }

    func test_derive_auto_returns_battery_when_battery_low_unplugged() {
        var s = SystemStateFixture.nominal()
        s.batteryState = .discharging
        s.batteryLevel = 0.19
        XCTAssertEqual(
            PowerMode.derived(from: s, isExternalPower: false),
            .battery
        )
    }

    func test_derive_auto_returns_battery_when_thermal_critical() {
        var s = SystemStateFixture.nominal()
        s.thermalState = .critical
        XCTAssertEqual(
            PowerMode.derived(from: s, isExternalPower: true),
            .battery
        )
    }

    func test_derive_auto_returns_balanced_for_fair_thermal_unplugged() {
        var s = SystemStateFixture.nominal()
        s.thermalState = .fair
        s.batteryState = .discharging
        XCTAssertEqual(
            PowerMode.derived(from: s, isExternalPower: false),
            .balanced
        )
    }

    func test_derive_auto_returns_performance_for_fair_thermal_plugged_in() {
        var s = SystemStateFixture.nominal()
        s.thermalState = .fair
        s.batteryState = .discharging
        XCTAssertEqual(
            PowerMode.derived(from: s, isExternalPower: true),
            .performance
        )
    }

    func test_derive_auto_returns_balanced_for_serious_thermal() {
        var s = SystemStateFixture.nominal()
        s.thermalState = .serious
        s.batteryState = .discharging
        XCTAssertEqual(
            PowerMode.derived(from: s, isExternalPower: true),
            .balanced
        )
    }

    // MARK: - User choice overrides

    func test_user_choice_performance_overrides_thermal_fair() {
        let s = SystemStateFixture.nominal().with(thermal: .fair)
        XCTAssertEqual(
            PowerMode(userChoice: .performance, systemState: s, isExternalPower: false),
            .performance
        )
    }

    func test_user_choice_battery_overrides_plugged_in() {
        let s = SystemStateFixture.nominal()
        XCTAssertEqual(
            PowerMode(userChoice: .battery, systemState: s, isExternalPower: true),
            .battery
        )
    }

    func test_user_choice_auto_falls_back_to_derivation() {
        let s = SystemStateFixture.nominal()
        XCTAssertEqual(
            PowerMode(userChoice: .auto, systemState: s, isExternalPower: true),
            .performance
        )
    }

    func test_user_choice_unknown_falls_back_to_derivation() {
        let s = SystemStateFixture.nominal()
        XCTAssertEqual(
            PowerMode(userChoice: .unknown, systemState: s, isExternalPower: true),
            .performance
        )
    }
}
