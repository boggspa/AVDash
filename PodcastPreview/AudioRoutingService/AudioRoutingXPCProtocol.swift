import Foundation

@objc protocol AudioRoutingXPCProtocol {
    func fetchStatus(_ reply: @escaping (Data?) -> Void)
    func setConfiguration(_ configurationData: Data, reply: @escaping (Data?) -> Void)
    func fetchTapSnapshot(_ maxFrames: NSNumber, reply: @escaping (Data?) -> Void)
}
