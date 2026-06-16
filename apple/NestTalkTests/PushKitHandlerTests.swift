#if os(iOS)
import XCTest
import CallKit
import PushKit
@testable import NestTalk_iOS

/// Spy CXProvider — records the order of reportNewIncomingCall + reportCall
/// calls. The PushKit synchrony rule: the outer `completion()` MUST fire
/// only AFTER reportNewIncomingCall has at least been entered.
private final class OrderRecordingProvider: CXProvider {
    enum Event: Equatable { case reportNew(UUID), reportEnded(UUID), completion }

    private(set) var events: [Event] = []
    private let lock = NSLock()

    /// When set, `reportNewIncomingCall` fires its completion with this
    /// error instead of nil — used to simulate CallKit rejecting a
    /// duplicate UUID (`callUUIDAlreadyExists`).
    var reportError: Error?

    init() {
        // CXProviderConfiguration must declare at least one
        // supportedHandleType, otherwise CallKit traps on init at
        // runtime under iOS 14+. Match what CallKitProvider uses in
        // production so the spy walks the same code paths.
        let cfg = CXProviderConfiguration()
        cfg.supportsVideo = true
        cfg.maximumCallsPerCallGroup = 1
        cfg.maximumCallGroups = 1
        cfg.supportedHandleTypes = [.generic]
        super.init(configuration: cfg)
    }

    override func reportNewIncomingCall(
        with UUID: UUID,
        update: CXCallUpdate,
        completion: @escaping (Error?) -> Void
    ) {
        lock.lock(); events.append(.reportNew(UUID)); lock.unlock()
        // Mimic CallKit's eventual completion fire — synchronous OK here.
        // `reportError` lets a test simulate CallKit rejecting the UUID.
        completion(reportError)
    }

    override func reportCall(
        with UUID: UUID,
        endedAt dateEnded: Date?,
        reason endedReason: CXCallEndedReason
    ) {
        lock.lock(); events.append(.reportEnded(UUID)); lock.unlock()
    }

    func recordCompletion() {
        lock.lock(); events.append(.completion); lock.unlock()
    }
}

final class PushKitHandlerTests: XCTestCase {

    func test_well_formed_payload_reports_new_incoming_call_before_outer_completion() {
        let spy = OrderRecordingProvider()
        let handler = PushKitHandler.shared
        handler.providerForReporting = spy
        defer { handler.providerForReporting = nil }

        let uuid = UUID()
        let exp = expectation(description: "outer completion")
        handler.process(
            dictionaryPayload: ["call_uuid": uuid.uuidString, "from_name": "Mom"],
            type: .voIP
        ) {
            spy.recordCompletion()
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        // Synchrony invariant: reportNewIncomingCall MUST appear before
        // .completion in the recorded sequence. Apple revokes the VoIP
        // entitlement if completion fires first.
        let firstReport = spy.events.firstIndex { if case .reportNew = $0 { true } else { false } }
        let firstCompletion = spy.events.firstIndex(of: .completion)
        XCTAssertNotNil(firstReport, "must call reportNewIncomingCall")
        XCTAssertNotNil(firstCompletion, "outer completion must fire")
        if let r = firstReport, let c = firstCompletion {
            XCTAssertLessThan(r, c, "reportNewIncomingCall must precede outer completion")
        }
        XCTAssertEqual(spy.events.first, .reportNew(uuid))
    }

    func test_malformed_payload_still_reports_synthetic_call() {
        let spy = OrderRecordingProvider()
        let handler = PushKitHandler.shared
        handler.providerForReporting = spy
        defer { handler.providerForReporting = nil }

        let exp = expectation(description: "outer completion")
        handler.process(
            dictionaryPayload: [:],  // missing call_uuid
            type: .voIP
        ) {
            spy.recordCompletion()
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        // Synthetic-ring path: must still call reportNewIncomingCall first
        // (so iOS sees something) followed by reportCall(endedAt:).
        let hasNew = spy.events.contains { if case .reportNew = $0 { true } else { false } }
        let hasEnded = spy.events.contains { if case .reportEnded = $0 { true } else { false } }
        XCTAssertTrue(hasNew, "synthetic ring must include reportNewIncomingCall")
        XCTAssertTrue(hasEnded, "synthetic ring must follow with reportCall(endedAt:)")
        XCTAssertEqual(spy.events.last, .completion)
    }

    func test_non_voip_type_short_circuits_to_completion() {
        let spy = OrderRecordingProvider()
        let handler = PushKitHandler.shared
        handler.providerForReporting = spy
        defer { handler.providerForReporting = nil }

        let exp = expectation(description: "outer completion")
        // Any payload, but the registry passed a non-voIP type — handled
        // through the synthetic-ring path so iOS still sees a report.
        handler.process(
            dictionaryPayload: ["call_uuid": UUID().uuidString],
            type: PKPushType(rawValue: "unsupported")
        ) {
            spy.recordCompletion()
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(spy.events.last, .completion)
    }

    /// Directional-call bug: a VoIP push for a call already registered with
    /// CallKit (by the WS-driven CallCoordinator, which uses the SAME server
    /// call id as the UUID) makes `reportNewIncomingCall` fail with
    /// `callUUIDAlreadyExists`. The handler must treat that as SUCCESS — the
    /// call is already ringing — NOT report it ended, which tore down the
    /// live call (Mac→iPhone "failed after a few seconds").
    func test_duplicate_uuid_error_does_not_end_the_call() {
        let spy = OrderRecordingProvider()
        spy.reportError = NSError(
            domain: CXErrorDomainIncomingCall,
            code: CXErrorCodeIncomingCallError.callUUIDAlreadyExists.rawValue
        )
        let handler = PushKitHandler.shared
        handler.providerForReporting = spy
        defer { handler.providerForReporting = nil }

        let uuid = UUID()
        let exp = expectation(description: "outer completion")
        handler.process(
            dictionaryPayload: ["call_uuid": uuid.uuidString, "from_name": "Mom"],
            type: .voIP
        ) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)

        XCTAssertTrue(spy.events.contains { if case .reportNew = $0 { true } else { false } },
                      "must still report the incoming call")
        XCTAssertFalse(spy.events.contains { if case .reportEnded = $0 { true } else { false } },
                       "a duplicate-UUID error means the call is already ringing — must NOT end it")
    }

    /// A genuinely fatal report error (not a benign duplicate) must still end
    /// the call so iOS doesn't see an unfulfilled ring.
    func test_fatal_report_error_still_ends_the_call() {
        let spy = OrderRecordingProvider()
        spy.reportError = NSError(
            domain: CXErrorDomainIncomingCall,
            code: CXErrorCodeIncomingCallError.filteredByDoNotDisturb.rawValue
        )
        let handler = PushKitHandler.shared
        handler.providerForReporting = spy
        defer { handler.providerForReporting = nil }

        let exp = expectation(description: "outer completion")
        handler.process(
            dictionaryPayload: ["call_uuid": UUID().uuidString, "from_name": "Mom"],
            type: .voIP
        ) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)

        XCTAssertTrue(spy.events.contains { if case .reportEnded = $0 { true } else { false } },
                      "a non-duplicate report failure must end the call")
    }

    /// APNs env must come from the embedded provisioning profile (the token's
    /// true environment), not just the Release compile flag — otherwise a
    /// dev-signed Release build reports "prod" with a sandbox token and APNs
    /// rejects the VoIP push (BadEnvironmentKeyInToken).
    func test_apnsEnv_from_provisioning_profile() {
        func blob(_ apsEnv: String) -> Data {
            Data(("0\u{82}CMS-DER-noise\u{00}<?xml version=\"1.0\" encoding=\"UTF-8\"?>" +
                  "<plist version=\"1.0\"><dict><key>Entitlements</key><dict>" +
                  "<key>aps-environment</key><string>\(apsEnv)</string>" +
                  "</dict></dict></plist>\u{00}signature-trailer").utf8)
        }
        XCTAssertEqual(PushKitHandler.apnsEnv(fromProvisioning: blob("development")), "dev")
        XCTAssertEqual(PushKitHandler.apnsEnv(fromProvisioning: blob("production")), "prod")
        XCTAssertNil(PushKitHandler.apnsEnv(fromProvisioning: Data("not a provisioning profile".utf8)))
        // Unknown aps-environment value → nil (falls back to compile flag).
        XCTAssertNil(PushKitHandler.apnsEnv(fromProvisioning: blob("staging")))
        // `</plist>` before `<?xml` must not trap on an inverted range.
        XCTAssertNil(PushKitHandler.apnsEnv(fromProvisioning: Data("</plist> then <?xml later".utf8)))
    }
}
#endif
