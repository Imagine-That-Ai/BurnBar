#if canImport(AppKit) && !DISTRIBUTION_MAS
import ApplicationServices
import CoreGraphics
import Foundation

func axElement(_ ref: CFTypeRef?) -> AXUIElement? {
    guard let ref else { return nil }
    guard CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
    return unsafeBitCast(ref, to: AXUIElement.self)
}

func axValue(_ ref: CFTypeRef?) -> AXValue? {
    guard let ref else { return nil }
    guard CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
    return unsafeBitCast(ref, to: AXValue.self)
}

func axPoint(_ ref: CFTypeRef?) -> CGPoint? {
    guard let value = axValue(ref), AXValueGetType(value) == .cgPoint else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
    return point
}

func axSize(_ ref: CFTypeRef?) -> CGSize? {
    guard let value = axValue(ref), AXValueGetType(value) == .cgSize else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue(value, .cgSize, &size) else { return nil }
    return size
}
#endif
