import DoryCore
import XCTest

final class GVProxyQEMUFrameDecoderTests: XCTestCase {
    func testDecodesFragmentedAndCoalescedEthernetFrames() throws {
        let first = Data(repeating: 0x11, count: 14)
        let second = Data(repeating: 0x22, count: 1514)
        let stream = try GVProxyQEMUFrameDecoder.encode(first)
            + GVProxyQEMUFrameDecoder.encode(second)
        var decoder = GVProxyQEMUFrameDecoder()

        XCTAssertEqual(try decoder.append(stream.prefix(2)), [])
        XCTAssertEqual(try decoder.append(stream.dropFirst(2).prefix(20)), [first])
        XCTAssertEqual(try decoder.append(stream.dropFirst(22)), [second])
    }

    func testRejectsInvalidOrOversizedFrameLengths() throws {
        var decoder = GVProxyQEMUFrameDecoder()
        XCTAssertThrowsError(try decoder.append(Data([0, 0, 0, 13]))) {
            XCTAssertEqual($0 as? GVProxyQEMUFrameError, .invalidFrameLength(13))
        }
        XCTAssertThrowsError(try GVProxyQEMUFrameDecoder.encode(
            Data(repeating: 0, count: GVProxyQEMUFrameDecoder.maximumFrameLength + 1)
        ))
    }
}
