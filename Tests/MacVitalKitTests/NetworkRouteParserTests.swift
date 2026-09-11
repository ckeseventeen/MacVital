import Darwin
import XCTest

final class NetworkRouteParserTests: XCTestCase {
    func testShortAddressMessageDoesNotStopInterfaceParsing() {
        let fixture = interfaceMessage(type: UInt8(IFT_LOOP), bytesIn: 100, bytesOut: 200)
            + routeMessage(type: UInt8(RTM_NEWADDR), length: 8)
            + interfaceMessage(type: UInt8(IFT_ETHER), bytesIn: 12_345, bytesOut: 67_890)

        let counters = fixture.withUnsafeBytes { NetworkRouteParser.parse($0) }

        XCTAssertEqual(counters, NetworkByteCounters(bytesIn: 12_345, bytesOut: 67_890))
    }

    func testTruncatedMessageStopsWithoutReadingPastTheBuffer() {
        var fixture = routeMessage(type: UInt8(RTM_NEWADDR), length: 64)
        fixture.removeLast(1)

        let counters = fixture.withUnsafeBytes { NetworkRouteParser.parse($0) }

        XCTAssertEqual(counters, NetworkByteCounters())
    }

    private func routeMessage(type: UInt8, length: Int) -> Data {
        var message = Data(repeating: 0, count: length)
        message[0] = UInt8(length & 0xff)
        message[1] = UInt8((length >> 8) & 0xff)
        message[2] = UInt8(RTM_VERSION)
        message[3] = type
        return message
    }

    private func interfaceMessage(
        type: UInt8,
        bytesIn: UInt64,
        bytesOut: UInt64
    ) -> Data {
        var header = if_msghdr2()
        header.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size)
        header.ifm_version = UInt8(RTM_VERSION)
        header.ifm_type = UInt8(RTM_IFINFO2)
        header.ifm_data.ifi_type = type
        header.ifm_data.ifi_ibytes = bytesIn
        header.ifm_data.ifi_obytes = bytesOut
        return withUnsafeBytes(of: &header) { Data($0) }
    }
}
