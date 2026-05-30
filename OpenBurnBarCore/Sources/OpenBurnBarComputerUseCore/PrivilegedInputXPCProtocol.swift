import Foundation

@objc(PrivilegedInputExecutionXPCProtocol)
public protocol PrivilegedInputExecutionXPCProtocol {
    func perform(_ envelopeData: Data, reply: @escaping (Data?, NSError?) -> Void)
}
