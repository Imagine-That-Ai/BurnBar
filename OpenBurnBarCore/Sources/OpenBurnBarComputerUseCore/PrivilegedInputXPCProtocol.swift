import Foundation

@objc(PrivilegedInputExecutionXPCProtocol)
protocol PrivilegedInputExecutionXPCProtocol {
    func perform(_ envelopeData: Data, reply: @escaping (Data?, NSError?) -> Void)
}
