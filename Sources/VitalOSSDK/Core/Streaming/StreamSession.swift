import Foundation

/// Common base for all stateful streaming sessions (incoming and outgoing).
public protocol StreamSession: AnyObject {
    var streamId: Int { get }
    func onStreamCancel(reason: CancelReason)
}
