import XCTest
@testable import Rigel

final class SsdpTest: XCTestCase {
    func testMSearchPacketBytes() {
        let data = Ssdp.packet(searchTarget: "roku:ecp")
        let expected = "M-SEARCH * HTTP/1.1\r\n" +
            "HOST: 239.255.255.250:1900\r\n" +
            "MAN: \"ssdp:discover\"\r\n" +
            "MX: 3\r\n" +
            "ST: roku:ecp\r\n\r\n"
        XCTAssertEqual(String(data: data, encoding: .utf8), expected)
    }

    func testMSearchPacketDlnaTarget() {
        let data = Ssdp.packet(searchTarget: "urn:schemas-upnp-org:device:MediaRenderer:1")
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n"))
    }

    func testParseReply() throws {
        let raw = "HTTP/1.1 200 OK\r\n" +
            "CACHE-CONTROL: max-age=3600\r\n" +
            "LOCATION: http://192.168.1.10:8060/\r\n" +
            "SERVER: Roku\r\n" +
            "ST: roku:ecp\r\n" +
            "USN: uuid:roku:ecp:1Q00A0000000\r\n\r\n"
        let reply = Ssdp.parseReply(Data(raw.utf8))
        let r = try XCTUnwrap(reply)
        XCTAssertEqual(r.usn, "uuid:roku:ecp:1Q00A0000000")
        XCTAssertEqual(r.location, "http://192.168.1.10:8060/")
        XCTAssertEqual(r.searchTarget, "roku:ecp")
        XCTAssertEqual(r.server, "Roku")
    }

    func testParseReplyRejectsNon200() {
        let raw = "HTTP/1.1 404 Not Found\r\n\r\n"
        XCTAssertNil(Ssdp.parseReply(Data(raw.utf8)))
    }
}
