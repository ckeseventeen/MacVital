import Foundation
import MacVitalKit

/// Entry point for the privileged helper.
///
/// Registered by the app through `SMAppService.daemon(plistName:)`, launched on
/// demand by launchd, and idle-exits when nothing is talking to it. It holds no
/// state between connections.
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = HelperService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: MacVitalHelperProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
let delegate = ListenerDelegate()
listener.delegate = delegate

// The gate. Public API since macOS 13, and strictly better than the audit-token
// dance it replaces: launchd hands us the peer's code signature and refuses the
// connection before our delegate ever sees it.
//
// The requirement is derived from *this binary's* team identifier, so a helper
// installed by one signed build will not accept a differently-signed client —
// including an unsigned debug build of the same app.
if let requirement = CodeRequirement.forClient() {
    listener.setConnectionCodeSigningRequirement(requirement)
    NSLog("[MacVitalHelper] listening, client requirement pinned")
} else {
    // No team identifier means the helper is unsigned or ad-hoc signed. There
    // is no way to authenticate a caller, so refuse to serve at all rather
    // than expose root-level file operations to anything on the machine.
    NSLog("[MacVitalHelper] refusing to start: cannot derive code signing requirement")
    exit(EXIT_FAILURE)
}

listener.resume()
RunLoop.main.run()
