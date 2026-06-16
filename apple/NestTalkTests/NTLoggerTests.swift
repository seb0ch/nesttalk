import XCTest
#if os(iOS)
@testable import NestTalk_iOS
#elseif os(macOS)
@testable import NestTalk_macOS
#endif

final class NTLoggerTests: XCTestCase {

    private var tempBase: URL!

    override func setUp() {
        super.setUp()
        tempBase = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nt-logger-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempBase)
        super.tearDown()
    }

    func test_info_writes_a_line_to_the_day_file() throws {
        let logger = NTLogger(category: "test", baseURL: tempBase)
        logger.info("hello world")
        // Sink writes async — give it a tick.
        let exp = expectation(description: "wait for write")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        let entries = try FileManager.default.contentsOfDirectory(
            at: tempBase, includingPropertiesForKeys: nil
        )
        let logs = entries.filter { $0.pathExtension == "log" }
        XCTAssertGreaterThan(logs.count, 0)
        let body = try String(contentsOf: logs[0])
        XCTAssertTrue(body.contains("hello world"))
        XCTAssertTrue(body.contains("[test]"))
    }

    func test_log_levels_get_distinct_tags() throws {
        let logger = NTLogger(category: "lvl", baseURL: tempBase)
        logger.info("a")
        logger.error("b")
        logger.debug("c")
        let exp = expectation(description: "wait for writes")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        let logs = try FileManager.default.contentsOfDirectory(
            at: tempBase, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "log" }
        XCTAssertEqual(logs.count, 1)
        let body = try String(contentsOf: logs[0])
        XCTAssertTrue(body.contains("[info]"))
        XCTAssertTrue(body.contains("[error]"))
        XCTAssertTrue(body.contains("[debug]"))
    }
}
