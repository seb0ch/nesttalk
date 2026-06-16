import XCTest
#if os(iOS)
@testable import NestTalk_iOS
#elseif os(macOS)
@testable import NestTalk_macOS
#endif

final class TypingServiceTests: XCTestCase {

    actor Recorder {
        var sent: [String] = []
        func record(_ outbound: ControlOutbound) {
            switch outbound {
            case .typingStart(let to): sent.append("start:\(to)")
            case .typingStop(let to):  sent.append("stop:\(to)")
            case .callSignal:          sent.append("call_signal")
            }
        }
        func snapshot() -> [String] { sent }
    }

    func test_keystroke_emits_typing_start_first_call() async {
        let rec = Recorder()
        let svc = TypingService { await rec.record($0) }
        await svc.keystroke(toUserId: "mom")
        let sent = await rec.snapshot()
        XCTAssertEqual(sent, ["start:mom"])
    }

    func test_keystroke_within_coalesce_window_does_not_resend() async {
        let rec = Recorder()
        let svc = TypingService { await rec.record($0) }
        await svc.keystroke(toUserId: "mom")
        await svc.keystroke(toUserId: "mom")
        await svc.keystroke(toUserId: "mom")
        let sent = await rec.snapshot()
        XCTAssertEqual(sent, ["start:mom"], "only first within 3s window emits")
    }

    func test_traffic_cap_rejects_after_10_frames() async {
        let rec = Recorder()
        let svc = TypingService { await rec.record($0) }
        // Hammer different recipients to bypass coalesce.
        for i in 0..<20 {
            await svc.keystroke(toUserId: "u\(i)")
        }
        let count = await svc._trafficCount()
        XCTAssertLessThanOrEqual(count, 10, "cap limits to 10/min")
    }

    func test_flush_emits_stop_for_all_active_typers() async {
        let rec = Recorder()
        let svc = TypingService { await rec.record($0) }
        await svc.keystroke(toUserId: "mom")
        await svc.keystroke(toUserId: "dad")
        await svc.flush()
        let sent = await rec.snapshot()
        XCTAssertTrue(sent.contains("stop:mom"))
        XCTAssertTrue(sent.contains("stop:dad"))
    }

    func test_typing_observer_marks_user_typing_then_stops() async {
        let observer = await TypingObserver()
        await observer.ingest(.typingStart(from: "mom", to: "self", atMillis: 1))
        let started = await observer.typing["mom"]
        XCTAssertEqual(started, true)
        await observer.ingest(.typingStop(from: "mom", to: "self", atMillis: 2))
        let stopped = await observer.typing["mom"]
        XCTAssertEqual(stopped, false)
    }
}
