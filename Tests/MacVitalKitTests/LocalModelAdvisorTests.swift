import XCTest
@testable import MacVitalKit

final class LocalModelAdvisorTests: XCTestCase {
    func testOnlyNumericLoopbackEndpointsAreAccepted() throws {
        XCTAssertTrue(LocalModelAdvisor.isNumericLoopback(
            try XCTUnwrap(URL(string: "http://127.0.0.1:11434/api/chat"))
        ))
        XCTAssertTrue(LocalModelAdvisor.isNumericLoopback(
            try XCTUnwrap(URL(string: "http://[::1]:11434/api/chat"))
        ))
        XCTAssertFalse(LocalModelAdvisor.isNumericLoopback(
            try XCTUnwrap(URL(string: "http://localhost:11434/api/chat"))
        ))
        XCTAssertFalse(LocalModelAdvisor.isNumericLoopback(
            try XCTUnwrap(URL(string: "https://example.com/api/chat"))
        ))
    }
}
