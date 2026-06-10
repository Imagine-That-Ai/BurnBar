import IOKit.ps
import XCTest
@testable import OpenBurnBar

/// Pin tests for the pure AC <-> battery decision behind the event-driven
/// IOPS limited-power notification that replaced the 5 s battery polling
/// timer. The notification callback re-queries IOKit and feeds the resulting
/// power-source descriptions through `AppDelegate.isOnBattery`; these tests
/// lock that mapping so the wallpaper throttle flag keeps its polling-era
/// semantics.
final class PowerSourceMonitoringTests: XCTestCase {

    func test_noPowerSources_isNotOnBattery() {
        XCTAssertFalse(AppDelegate.isOnBattery(powerSourceDescriptions: []))
    }

    func test_acPower_isNotOnBattery() {
        XCTAssertFalse(AppDelegate.isOnBattery(powerSourceDescriptions: [
            [kIOPSPowerSourceStateKey: kIOPSACPowerValue]
        ]))
    }

    func test_batteryPower_isOnBattery() {
        XCTAssertTrue(AppDelegate.isOnBattery(powerSourceDescriptions: [
            [kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue]
        ]))
    }

    func test_batterySourceAmongACSources_isOnBattery() {
        XCTAssertTrue(AppDelegate.isOnBattery(powerSourceDescriptions: [
            [kIOPSPowerSourceStateKey: kIOPSACPowerValue],
            [kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue]
        ]))
    }

    func test_offlineSource_isNotOnBattery() {
        XCTAssertFalse(AppDelegate.isOnBattery(powerSourceDescriptions: [
            [kIOPSPowerSourceStateKey: kIOPSOffLineValue]
        ]))
    }

    func test_descriptionWithoutStateKey_isIgnored() {
        XCTAssertFalse(AppDelegate.isOnBattery(powerSourceDescriptions: [
            [kIOPSNameKey: "InternalBattery-0"]
        ]))
    }
}
