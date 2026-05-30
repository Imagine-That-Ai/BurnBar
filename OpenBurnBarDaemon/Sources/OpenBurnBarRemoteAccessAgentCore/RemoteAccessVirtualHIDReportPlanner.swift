import Foundation

public struct RemoteAccessVirtualHIDKeyboardReport: Equatable, Sendable {
    public static let byteCount = 8

    public var modifier: UInt8
    public var keyUsage: UInt8

    public init(modifier: UInt8 = 0, keyUsage: UInt8 = 0) {
        self.modifier = modifier
        self.keyUsage = keyUsage
    }

    public var bytes: [UInt8] {
        [modifier, 0, keyUsage, 0, 0, 0, 0, 0]
    }
}

public struct RemoteAccessVirtualHIDKeyPress: Equatable, Sendable {
    public var down: RemoteAccessVirtualHIDKeyboardReport
    public var up: RemoteAccessVirtualHIDKeyboardReport

    public init(down: RemoteAccessVirtualHIDKeyboardReport) {
        self.down = down
        self.up = RemoteAccessVirtualHIDKeyboardReport()
    }
}

public enum RemoteAccessVirtualHIDReportPlanner {
    public static let leftShiftModifier: UInt8 = 0x02

    public static func planForANSIUSKeyboard(_ text: String) -> [RemoteAccessVirtualHIDKeyPress]? {
        guard let keystrokes = RemoteAccessKeystrokePlanner.planForANSIUSKeyboard(text) else {
            return nil
        }
        return keystrokes.compactMap { keyPress(forVirtualKey: $0.virtualKey, requiresShift: $0.requiresShift) }
    }

    public static func keyPress(forVirtualKey virtualKey: UInt16, requiresShift: Bool = false) -> RemoteAccessVirtualHIDKeyPress? {
        guard let usage = usbKeyboardUsageByMacVirtualKey[virtualKey] else { return nil }
        return RemoteAccessVirtualHIDKeyPress(
            down: RemoteAccessVirtualHIDKeyboardReport(
                modifier: requiresShift ? leftShiftModifier : 0,
                keyUsage: usage
            )
        )
    }

    public static func returnKeyPress() -> RemoteAccessVirtualHIDKeyPress {
        RemoteAccessVirtualHIDKeyPress(down: RemoteAccessVirtualHIDKeyboardReport(keyUsage: 0x28))
    }

    public static func escapeKeyPress() -> RemoteAccessVirtualHIDKeyPress {
        RemoteAccessVirtualHIDKeyPress(down: RemoteAccessVirtualHIDKeyboardReport(keyUsage: 0x29))
    }

    public static func deleteKeyPress() -> RemoteAccessVirtualHIDKeyPress {
        RemoteAccessVirtualHIDKeyPress(down: RemoteAccessVirtualHIDKeyboardReport(keyUsage: 0x2a))
    }

    // Carbon/Quartz virtual key code -> USB HID Keyboard/Keypad usage ID.
    // The Remote Unlock credential path only accepts ANSI-US characters that the
    // existing keystroke planner can express, so this intentionally covers that
    // same bounded surface plus Return/Escape/Delete for focus and submission.
    private static let usbKeyboardUsageByMacVirtualKey: [UInt16: UInt8] = [
        0: 0x04,   // A
        1: 0x16,   // S
        2: 0x07,   // D
        3: 0x09,   // F
        4: 0x0b,   // H
        5: 0x0a,   // G
        6: 0x1d,   // Z
        7: 0x1b,   // X
        8: 0x06,   // C
        9: 0x19,   // V
        11: 0x05,  // B
        12: 0x14,  // Q
        13: 0x1a,  // W
        14: 0x08,  // E
        15: 0x15,  // R
        16: 0x1c,  // Y
        17: 0x17,  // T
        18: 0x1e,  // 1
        19: 0x1f,  // 2
        20: 0x20,  // 3
        21: 0x21,  // 4
        22: 0x23,  // 6
        23: 0x22,  // 5
        24: 0x2e,  // =
        25: 0x26,  // 9
        26: 0x24,  // 7
        27: 0x2d,  // -
        28: 0x25,  // 8
        29: 0x27,  // 0
        30: 0x30,  // ]
        31: 0x12,  // O
        32: 0x18,  // U
        33: 0x2f,  // [
        34: 0x0c,  // I
        35: 0x13,  // P
        36: 0x28,  // Return
        37: 0x0f,  // L
        38: 0x0d,  // J
        39: 0x34,  // '
        40: 0x0e,  // K
        41: 0x33,  // ;
        42: 0x31,  // \
        43: 0x36,  // ,
        44: 0x38,  // /
        45: 0x11,  // N
        46: 0x10,  // M
        47: 0x37,  // .
        49: 0x2c,  // Space
        50: 0x35,  // `
        51: 0x2a,  // Delete/Backspace
        53: 0x29   // Escape
    ]
}
