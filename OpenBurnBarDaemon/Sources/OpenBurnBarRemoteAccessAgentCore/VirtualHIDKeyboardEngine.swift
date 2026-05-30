import CoreGraphics
import Dispatch
import Foundation
import IOKit.hid
import OpenBurnBarComputerUseCore

/// Virtual HID keyboard + pointing device — lives only in the input-execution leaf (WS1 TCB).
public final class VirtualHIDKeyboardEngine: @unchecked Sendable {
    public enum EngineError: String, Error, Sendable {
        case missingPassword = "missing_password"
        case missingInputKind = "missing_input_kind"
        case missingText = "missing_text"
        case emptyPassword = "empty_password"
        case passwordTooLarge = "password_too_large"
        case unsupportedKeyboardLayout = "unsupported_keyboard_layout"
        case unsupportedInputKind = "unsupported_input_kind"
        case unknownKey = "unknown_key"
        case virtualHIDDeviceUnavailable = "virtual_hid_device_unavailable"
        case virtualHIDReportFailed = "virtual_hid_report_failed"
        case inputPolicyRejected = "input_policy_rejected"
    }

    private let device: IOHIDUserDevice
    private let pointingDevice: IOHIDUserDevice
    private let queue = DispatchQueue(label: "com.openburnbar.virtual-hid.keyboard")
    private let lock = NSLock()

    public init() throws {
        let properties: [String: Any] = [
            kIOHIDTransportKey: "Virtual",
            kIOHIDVendorIDKey: 0x0bba,
            kIOHIDProductIDKey: 0x1001,
            kIOHIDVersionNumberKey: 1,
            kIOHIDManufacturerKey: "OpenBurnBar",
            kIOHIDProductKey: "OpenBurnBar Remote Unlock Keyboard",
            kIOHIDSerialNumberKey: "openburnbar-remote-unlock-keyboard",
            kIOHIDPrimaryUsagePageKey: 0x01,
            kIOHIDPrimaryUsageKey: 0x06,
            kIOHIDReportDescriptorKey: Data(Self.keyboardReportDescriptor)
        ]
        guard let created = IOHIDUserDeviceCreateWithProperties(kCFAllocatorDefault, properties as CFDictionary, 0) else {
            throw EngineError.virtualHIDDeviceUnavailable
        }
        self.device = created
        let pointingProperties: [String: Any] = [
            kIOHIDTransportKey: "Virtual",
            kIOHIDVendorIDKey: 0x0bba,
            kIOHIDProductIDKey: 0x1002,
            kIOHIDVersionNumberKey: 1,
            kIOHIDManufacturerKey: "OpenBurnBar",
            kIOHIDProductKey: "OpenBurnBar Remote Unlock Mouse",
            kIOHIDSerialNumberKey: "openburnbar-remote-unlock-mouse",
            kIOHIDPrimaryUsagePageKey: 0x01,
            kIOHIDPrimaryUsageKey: 0x02,
            kIOHIDReportDescriptorKey: Data(Self.pointingReportDescriptor)
        ]
        guard let pointing = IOHIDUserDeviceCreateWithProperties(kCFAllocatorDefault, pointingProperties as CFDictionary, 0) else {
            throw EngineError.virtualHIDDeviceUnavailable
        }
        self.pointingDevice = pointing
        IOHIDUserDeviceSetDispatchQueue(device, queue)
        IOHIDUserDeviceSetDispatchQueue(pointingDevice, queue)
        IOHIDUserDeviceActivate(device)
        IOHIDUserDeviceActivate(pointingDevice)
        usleep(250_000)
    }

    deinit {
        IOHIDUserDeviceCancel(device)
        IOHIDUserDeviceCancel(pointingDevice)
    }

    public func dispatch(_ request: PrivilegedInputDispatchRequest) throws {
        try PrivilegedInputKillSwitch.assertNotActive()
        guard let kind = request.kind else { throw EngineError.missingInputKind }
        lock.lock()
        defer { lock.unlock() }

        switch kind {
        case "type":
            guard let text = request.text, !text.isEmpty else { throw EngineError.missingText }
            try typeText(text)
        case "key", "shortcut":
            guard let key = request.key,
                  let virtualKey = MacInputCore.virtualKey(for: key),
                  let keyPress = keyPress(for: virtualKey, modifiers: request.modifiers ?? []) else {
                throw EngineError.unknownKey
            }
            try post(keyPress)
        case "click":
            if let x = request.displayX, let y = request.displayY {
                try movePointer(toX: x, y: y)
            }
            try click(button: request.mouseButton ?? 0)
        case "pointer_move":
            try movePointerBy(deltaX: request.deltaX ?? 0, deltaY: request.deltaY ?? 0)
        case "scroll":
            try postPointing(buttons: 0, deltaX: 0, deltaY: 0, wheel: clampInt8(request.deltaY ?? 0))
        default:
            throw EngineError.unsupportedInputKind
        }
    }

    public func typeCredential(_ password: String) throws {
        guard let plan = RemoteAccessVirtualHIDReportPlanner.planForANSIUSKeyboard(password) else {
            throw EngineError.unsupportedKeyboardLayout
        }

        lock.lock()
        defer { lock.unlock() }

        for keyPress in [RemoteAccessVirtualHIDReportPlanner.escapeKeyPress()] {
            try post(keyPress)
        }
        usleep(120_000)
        for _ in 0..<3 {
            try post(RemoteAccessVirtualHIDReportPlanner.deleteKeyPress())
            usleep(35_000)
        }
        usleep(120_000)
        for keyPress in plan {
            try post(keyPress)
            usleep(18_000)
        }
        usleep(150_000)
        try post(RemoteAccessVirtualHIDReportPlanner.returnKeyPress())
    }

    private func typeText(_ text: String) throws {
        guard let plan = RemoteAccessVirtualHIDReportPlanner.planForANSIUSKeyboard(text) else {
            throw EngineError.unsupportedKeyboardLayout
        }
        for keyPress in plan {
            try post(keyPress)
            usleep(18_000)
        }
    }

    private func keyPress(for virtualKey: UInt16, modifiers: [String]) -> RemoteAccessVirtualHIDKeyPress? {
        guard var press = RemoteAccessVirtualHIDReportPlanner.keyPress(forVirtualKey: virtualKey) else { return nil }
        press.down.modifier = hidModifierByte(for: modifiers)
        return press
    }

    private func hidModifierByte(for modifiers: [String]) -> UInt8 {
        let parsed = MacInputCore.modifiers(for: modifiers)
        var byte: UInt8 = 0
        if parsed.contains(.control) { byte |= 0x01 }
        if parsed.contains(.shift) { byte |= 0x02 }
        if parsed.contains(.alternate) { byte |= 0x04 }
        if parsed.contains(.command) { byte |= 0x08 }
        return byte
    }

    private func post(_ keyPress: RemoteAccessVirtualHIDKeyPress) throws {
        try post(keyPress.down)
        usleep(12_000)
        try post(keyPress.up)
        usleep(12_000)
    }

    private func post(_ report: RemoteAccessVirtualHIDKeyboardReport) throws {
        let bytes = report.bytes
        let result = bytes.withUnsafeBytes { pointer in
            IOHIDUserDeviceHandleReportWithTimeStamp(
                device,
                mach_absolute_time(),
                pointer.bindMemory(to: UInt8.self).baseAddress!,
                RemoteAccessVirtualHIDKeyboardReport.byteCount
            )
        }
        guard result == kIOReturnSuccess else {
            throw EngineError.virtualHIDReportFailed
        }
    }

    private func movePointer(toX x: Int, y: Int) throws {
        let current = CGEvent(source: nil)?.location ?? .zero
        try movePointerBy(deltaX: x - Int(current.x), deltaY: y - Int(current.y))
    }

    private func movePointerBy(deltaX: Int, deltaY: Int) throws {
        var remainingX = deltaX
        var remainingY = deltaY
        while remainingX != 0 || remainingY != 0 {
            let stepX = clampInt8(remainingX)
            let stepY = clampInt8(remainingY)
            try postPointing(buttons: 0, deltaX: stepX, deltaY: stepY, wheel: 0)
            remainingX -= Int(stepX)
            remainingY -= Int(stepY)
            usleep(4_000)
        }
    }

    private func click(button: Int) throws {
        let mask: UInt8
        switch button {
        case 1: mask = 0x02
        case 2: mask = 0x04
        default: mask = 0x01
        }
        try postPointing(buttons: mask, deltaX: 0, deltaY: 0, wheel: 0)
        usleep(18_000)
        try postPointing(buttons: 0, deltaX: 0, deltaY: 0, wheel: 0)
    }

    private func clampInt8(_ value: Int) -> Int8 {
        Int8(max(-127, min(127, value)))
    }

    private func postPointing(buttons: UInt8, deltaX: Int8, deltaY: Int8, wheel: Int8) throws {
        let bytes = [
            buttons,
            UInt8(bitPattern: deltaX),
            UInt8(bitPattern: deltaY),
            UInt8(bitPattern: wheel)
        ]
        let result = bytes.withUnsafeBytes { pointer in
            IOHIDUserDeviceHandleReportWithTimeStamp(
                pointingDevice,
                mach_absolute_time(),
                pointer.bindMemory(to: UInt8.self).baseAddress!,
                bytes.count
            )
        }
        guard result == kIOReturnSuccess else {
            throw EngineError.virtualHIDReportFailed
        }
    }

    private static let keyboardReportDescriptor: [UInt8] = [
        0x05, 0x01, 0x09, 0x06, 0xa1, 0x01, 0x05, 0x07, 0x19, 0xe0, 0x29, 0xe7,
        0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0x95, 0x01,
        0x75, 0x08, 0x81, 0x01, 0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65,
        0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00, 0xc0
    ]

    private static let pointingReportDescriptor: [UInt8] = [
        0x05, 0x01, 0x09, 0x02, 0xa1, 0x01, 0x09, 0x01, 0xa1, 0x00, 0x05, 0x09,
        0x19, 0x01, 0x29, 0x03, 0x15, 0x00, 0x25, 0x01, 0x95, 0x03, 0x75, 0x01,
        0x81, 0x02, 0x95, 0x01, 0x75, 0x05, 0x81, 0x01, 0x05, 0x01, 0x09, 0x30,
        0x09, 0x31, 0x09, 0x38, 0x15, 0x81, 0x25, 0x7f, 0x75, 0x08, 0x95, 0x03,
        0x81, 0x06, 0xc0, 0xc0
    ]
}
