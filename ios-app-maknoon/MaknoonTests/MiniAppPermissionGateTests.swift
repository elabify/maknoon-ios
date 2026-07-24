import XCTest
@testable import Maknoon

// Locks the mini-app web3 permission gate (ADR-0057): the method -> permission
// mapping and the grant decision that MiniAppBridge enforces before dispatching
// a method. A mini-app that declared only read must be denied sends and
// signing. Mirrors Android MiniAppPermissionGateTest.
final class MiniAppPermissionGateTests: XCTestCase {

    private func permits(_ method: String, granted: Set<String>) -> Bool {
        let needed = Web3BridgeHandler.requiredPermission(forMethod: method)
        return MiniAppBridge.isAuthorized(requiredPermission: needed, granted: granted)
    }

    func testMethodPermissionMapping() {
        XCTAssertEqual(Web3BridgeHandler.requiredPermission(forMethod: "eth_sendTransaction"), "wallet.ethereum.write")
        XCTAssertEqual(Web3BridgeHandler.requiredPermission(forMethod: "personal_sign"), "wallet.ethereum.sign")
        XCTAssertEqual(Web3BridgeHandler.requiredPermission(forMethod: "eth_signTypedData_v4"), "wallet.ethereum.sign")
        XCTAssertEqual(Web3BridgeHandler.requiredPermission(forMethod: "eth_chainId"), "wallet.ethereum.read")
        XCTAssertEqual(Web3BridgeHandler.requiredPermission(forMethod: "eth_accounts"), "wallet.ethereum.read")
    }

    func testReadOnlyAppIsDeniedWritesAndSigning() {
        let readOnly: Set<String> = ["wallet.ethereum.read"]
        XCTAssertTrue(permits("eth_chainId", granted: readOnly))
        XCTAssertFalse(permits("eth_sendTransaction", granted: readOnly))
        XCTAssertFalse(permits("personal_sign", granted: readOnly))
        XCTAssertFalse(permits("eth_signTypedData_v4", granted: readOnly))
    }

    func testGrantedTokensPermitTheirMethods() {
        XCTAssertTrue(permits("eth_sendTransaction", granted: ["wallet.ethereum.write"]))
        XCTAssertTrue(permits("personal_sign", granted: ["wallet.ethereum.sign"]))
        // write does not imply sign
        XCTAssertFalse(permits("personal_sign", granted: ["wallet.ethereum.write"]))
    }

    func testNoGrantsDeniesEverything() {
        XCTAssertFalse(permits("eth_chainId", granted: []))
        XCTAssertFalse(permits("eth_sendTransaction", granted: []))
    }

    func testNilRequirementIsAlwaysAuthorized() {
        XCTAssertTrue(MiniAppBridge.isAuthorized(requiredPermission: nil, granted: []))
    }
}
