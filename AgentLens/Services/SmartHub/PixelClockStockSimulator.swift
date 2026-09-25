import Foundation
import Network
import OpenBurnBarCore
import OSLog

enum PixelClockStockMQTT {
    static let matrixTopic = "awtrixmatrix/a"

    enum PacketType {
        case connect
        case publish
        case subscribe
        case pingreq
        case disconnect
        case unknown
    }

    struct Packet: Equatable {
        var type: PacketType
        var body: Data
        var packetIdentifier: UInt16?
    }

    static func nextPacket(from buffer: inout Data) -> Packet? {
        guard buffer.count >= 2 else { return nil }
        let firstByte = buffer[buffer.startIndex]
        var multiplier = 1
        var value = 0
        var cursor = buffer.index(after: buffer.startIndex)
        var encodedLengthBytes = 0

        while true {
            guard cursor < buffer.endIndex, encodedLengthBytes < 4 else { return nil }
            let byte = Int(buffer[cursor])
            value += (byte & 127) * multiplier
            encodedLengthBytes += 1
            cursor = buffer.index(after: cursor)
            if (byte & 128) == 0 { break }
            multiplier *= 128
        }

        let headerLength = 1 + encodedLengthBytes
        let totalLength = headerLength + value
        guard buffer.count >= totalLength else { return nil }

        let bodyStart = buffer.index(buffer.startIndex, offsetBy: headerLength)
        let bodyEnd = buffer.index(bodyStart, offsetBy: value)
        let body = Data(buffer[bodyStart..<bodyEnd])
        buffer.removeSubrange(buffer.startIndex..<bodyEnd)

        let typeNibble = firstByte >> 4
        let type: PacketType
        switch typeNibble {
        case 1: type = .connect
        case 3: type = .publish
        case 8: type = .subscribe
        case 12: type = .pingreq
        case 14: type = .disconnect
        default: type = .unknown
        }

        return Packet(
            type: type,
            body: body,
            packetIdentifier: packetIdentifier(for: type, body: body)
        )
    }

    static func connack() -> Data {
        Data([0x20, 0x02, 0x00, 0x00])
    }

    static func suback(packetIdentifier: UInt16) -> Data {
        Data([0x90, 0x03, UInt8(packetIdentifier >> 8), UInt8(packetIdentifier & 0xFF), 0x00])
    }

    static func pingresp() -> Data {
        Data([0xD0, 0x00])
    }

    static func publish(topic: String, payload: Data) -> Data {
        let topicBytes = Data(topic.utf8)
        var body = Data()
        body.append(UInt8((topicBytes.count >> 8) & 0xFF))
        body.append(UInt8(topicBytes.count & 0xFF))
        body.append(topicBytes)
        body.append(payload)

        var packet = Data([0x30])
        packet.append(remainingLength(body.count))
        packet.append(body)
        return packet
    }

    static func remainingLength(_ value: Int) -> Data {
        var x = max(value, 0)
        var output = Data()
        repeat {
            var encodedByte = UInt8(x % 128)
            x /= 128
            if x > 0 {
                encodedByte |= 128
            }
            output.append(encodedByte)
        } while x > 0
        return output
    }

    private static func packetIdentifier(for type: PacketType, body: Data) -> UInt16? {
        guard type == .subscribe, body.count >= 2 else { return nil }
        return UInt16(body[body.startIndex]) << 8 | UInt16(body[body.index(after: body.startIndex)])
    }
}

enum PixelClockStockSimulatorFrameEncoder {
    private static let columns = 32
    private static let rows = 8

    static func commands(for pages: [PixelClockRenderedPage], config: PixelClockConfig) -> [Data] {
        let page = pages.first ?? PixelClockRenderedPage(
            text: "OPENBURNBAR",
            color: config.palette.primaryHex,
            durationSeconds: config.clampedPageDuration,
            scrollSpeed: config.clampedScrollSpeed
        )

        var commands: [Data] = []
        if let brightness = config.clampedBrightness {
            commands.append(Data([0x0D, UInt8(brightness)]))
        }
        commands.append(Data([0x09]))

        if page.draw.isEmpty {
            commands.append(drawTextCommand(text: page.text, color: page.color))
        } else {
            commands.append(drawBMPCommand(page: page))
        }
        commands.append(Data([0x08]))
        return commands
    }

    static func commandSets(for pages: [PixelClockRenderedPage], config: PixelClockConfig) -> [[Data]] {
        let selectedPages = pages.isEmpty
            ? [
                PixelClockRenderedPage(
                    text: "OPENBURNBAR",
                    color: config.palette.primaryHex,
                    durationSeconds: config.clampedPageDuration,
                    scrollSpeed: config.clampedScrollSpeed
                )
            ]
            : pages
        return selectedPages.map { commands(for: [$0], config: config) }
    }

    static func blankFrameCommands() -> [Data] {
        [Data([0x09]), Data([0x08])]
    }

    private static func drawTextCommand(text: String, color: String) -> Data {
        let rgb = rgbComponents(hex: color) ?? RGB(r: 255, g: 255, b: 255)
        var command = Data([0x00, 0x00, 0x00, 0x00, 0x01, rgb.r, rgb.g, rgb.b])
        command.append(Data(text.prefix(48).utf8))
        return command
    }

    private static func drawBMPCommand(page: PixelClockRenderedPage) -> Data {
        var canvas = Array(
            repeating: Array(repeating: RGB(r: 0, g: 0, b: 0), count: columns),
            count: rows
        )
        for instruction in page.draw {
            apply(instruction, to: &canvas)
        }

        var command = Data([0x01, 0x00, 0x00, 0x00, 0x00, UInt8(columns), UInt8(rows)])
        for row in 0..<rows {
            for column in 0..<columns {
                let color = canvas[row][column].rgb565
                command.append(UInt8(color >> 8))
                command.append(UInt8(color & 0xFF))
            }
        }
        return command
    }

    private static func apply(_ instruction: PixelClockDrawInstruction, to canvas: inout [[RGB]]) {
        switch instruction.command {
        case .drawPixel:
            guard instruction.values.count >= 3,
                  let x = instruction.values[0].intValue,
                  let y = instruction.values[1].intValue,
                  let color = instruction.values[2].stringValue.flatMap(rgbComponents(hex:)) else {
                return
            }
            setPixel(x: x, y: y, color: color, canvas: &canvas)
        case .fillRect:
            guard instruction.values.count >= 5,
                  let x = instruction.values[0].intValue,
                  let y = instruction.values[1].intValue,
                  let width = instruction.values[2].intValue,
                  let height = instruction.values[3].intValue,
                  let color = instruction.values[4].stringValue.flatMap(rgbComponents(hex:)) else {
                return
            }
            for row in y..<(y + max(height, 0)) {
                for column in x..<(x + max(width, 0)) {
                    setPixel(x: column, y: row, color: color, canvas: &canvas)
                }
            }
        case .drawText:
            break
        case .drawBitmap:
            guard instruction.values.count >= 5,
                  let x = instruction.values[0].intValue,
                  let y = instruction.values[1].intValue,
                  let width = instruction.values[2].intValue,
                  let height = instruction.values[3].intValue,
                  let pixels = instruction.values[4].intsValue else {
                return
            }
            for row in 0..<max(height, 0) {
                for column in 0..<max(width, 0) {
                    let index = row * width + column
                    guard pixels.indices.contains(index) else { continue }
                    setPixel(
                        x: x + column,
                        y: y + row,
                        color: rgbComponents(int: pixels[index]),
                        canvas: &canvas
                    )
                }
            }
        }
    }

    private static func setPixel(x: Int, y: Int, color: RGB, canvas: inout [[RGB]]) {
        guard (0..<columns).contains(x), (0..<rows).contains(y) else { return }
        canvas[y][x] = color
    }

    private static func rgbComponents(hex: String) -> RGB? {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") {
            value.removeFirst()
        }
        guard value.count == 6, let intValue = Int(value, radix: 16) else { return nil }
        return RGB(
            r: UInt8((intValue >> 16) & 0xFF),
            g: UInt8((intValue >> 8) & 0xFF),
            b: UInt8(intValue & 0xFF)
        )
    }

    private static func rgbComponents(int: Int) -> RGB {
        RGB(
            r: UInt8((int >> 16) & 0xFF),
            g: UInt8((int >> 8) & 0xFF),
            b: UInt8(int & 0xFF)
        )
    }

    struct RGB: Equatable {
        var r: UInt8
        var g: UInt8
        var b: UInt8

        var rgb565: UInt16 {
            let red = UInt16(r >> 3) << 11
            let green = UInt16(g >> 2) << 5
            let blue = UInt16(b >> 3)
            return red | green | blue
        }
    }
}

private extension PixelClockDrawValue {
    var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intsValue: [Int]? {
        if case .ints(let value) = self { return value }
        return nil
    }
}
