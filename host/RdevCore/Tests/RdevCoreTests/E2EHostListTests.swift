import XCTest
@testable import RdevCore

/// Turning a Control Plane's list of live hosts into something a person may be shown.
/// `protocol/test/e2e-host-list.test.ts` asserts the same rules against the same fixture.
///
/// THE LIST IS EVIDENCE OF NOTHING. Every field arrives from §4's adversary, and §9.2 says addresses
/// and room tokens confer no E2E authority. These tests are about the one thing this layer decides:
/// which names a user may be shown as if they meant something.
final class E2EHostListTests: XCTestCase {

    private struct LabelCase: Decodable {
        let name: String, target_device_id: String, signer: String
        let body: String, signature: String, signer_bundle: String
    }
    private struct Fixture: Decodable {
        let rp_id: String, allowed_origins: [String], root_id: String
        let devices: [String: DeviceRow]
        let labels: [String: LabelCase]
    }
    private struct DeviceRow: Decodable { let device_id: String }

    private static let fx: Fixture = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures/e2e-session.json")
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()
    private var fx: Fixture { Self.fx }

    private func hex(_ s: String) -> [UInt8] {
        stride(from: 0, to: s.count, by: 2).map {
            let i = s.index(s.startIndex, offsetBy: $0)
            return UInt8(s[i ... s.index(after: i)], radix: 16)!
        }
    }
    private func b64u(_ b: [UInt8]) -> String { base64urlEncode(Data(b)) }
    private var policy: E2EVerify.Policy {
        .init(rpID: fx.rp_id, allowedOrigins: fx.allowed_origins)
    }

    private func row(name: String = "Isaac\u{2019}s MacBook", code: String = "c1",
                     deviceID: String?? = nil, label: String?? = nil,
                     signature: String?? = nil, bundle: String?? = nil) -> E2EHostList.Listed {
        let c = fx.labels["valid"]!
        return .init(name: name, code: code, token: "t1",
                     e2eDeviceID: deviceID ?? b64u(hex(c.target_device_id)),
                     label: label ?? b64u(hex(c.body)),
                     labelSignature: signature ?? b64u(hex(c.signature)),
                     labelSignerBundle: bundle ?? b64u(hex(c.signer_bundle)))
    }

    private func review(_ listed: E2EHostList.Listed,
                        revoked: Set<[UInt8]> = []) -> E2EHostList.Reviewed {
        E2EHostList.review(listed, trustedRootID: hex(fx.root_id), policy: policy,
                           revokedDeviceIDs: revoked)
    }

    func testAFullyIdentifiedHostIsVerifiedAndConnectable() {
        let r = review(row(name: "Isaac's MacBook"))
        XCTAssertEqual(r.nameSource, .verified)
        XCTAssertEqual(r.displayName, "Isaac's MacBook")
        XCTAssertTrue(r.connectable)
        XCTAssertNil(r.labelFailure)
        XCTAssertFalse(r.nameContested)
        XCTAssertEqual(r.deviceID, hex(fx.labels["valid"]!.target_device_id))
    }

    /// The verified name WINS, and the disagreement is recorded: the directory caught saying
    /// something a signature contradicts.
    func testADirectoryNameContradictingTheLabelLosesAndIsFlagged() {
        let r = review(row(name: "Something Else"))
        XCTAssertEqual(r.displayName, "Isaac's MacBook")
        XCTAssertEqual(r.nameSource, .verified)
        XCTAssertTrue(r.nameContested)
    }

    // MARK: - what makes a row unconnectable

    /// §11.1 requires that "a selected Host's `device_id` must also match the selection", and a
    /// selection with nothing to match is not one.
    func testNoDeviceIDMeansUnconnectable() {
        let r = review(row(deviceID: .some(nil)))
        XCTAssertFalse(r.connectable)
        XCTAssertNil(r.deviceID)
        XCTAssertEqual(r.nameSource, .unverified)
    }

    func testAWrongWidthOrUndecodableDeviceIDMeansUnconnectable() {
        for bad in ["", "AAAA", "not base64!", b64u(Array(repeating: 0, count: 31))] {
            XCTAssertFalse(review(row(deviceID: .some(bad))).connectable, bad)
        }
    }

    /// A caller has to render SOMETHING, and a blank row tells a user less than a marked one.
    func testAnUnconnectableRowStillCarriesItsUnverifiedName() {
        let r = review(row(name: "Old Mac", deviceID: .some(nil)))
        XCTAssertEqual(r.displayName, "Old Mac")
        XCTAssertEqual(r.nameSource, .unverified)
    }

    // MARK: - what makes a name unverified

    func testNoLabelLeavesTheNameUnverifiedButStillSelectable() {
        let r = review(row(label: .some(nil), signature: .some(nil), bundle: .some(nil)))
        XCTAssertEqual(r.nameSource, .unverified)
        XCTAssertTrue(r.connectable, "only its NAME is unvouched for")
        XCTAssertNil(r.labelFailure)
    }

    /// Three fields that only mean anything together. A row carrying two of them has a name nothing
    /// vouches for, not one to half-believe.
    func testAPartialLabelIsNoLabel() {
        XCTAssertEqual(review(row(label: .some(nil))).nameSource, .unverified)
        XCTAssertEqual(review(row(signature: .some(nil))).nameSource, .unverified)
        XCTAssertEqual(review(row(bundle: .some(nil))).nameSource, .unverified)
        XCTAssertNil(review(row(label: .some(nil))).labelFailure)
    }

    func testALabelForADifferentDeviceIsRefusedAndSaysSo() {
        let r = review(row(deviceID: .some(b64u(hex(fx.devices["C"]!.device_id)))))
        XCTAssertEqual(r.nameSource, .unverified)
        XCTAssertEqual(r.labelFailure, .deviceMismatch)
        // Still connectable: the device id is well formed, and only the NAME failed to verify.
        XCTAssertTrue(r.connectable)
    }

    func testALabelSignedWithoutEnrollIsRefused() {
        let c = fx.labels["signer-not-authorised"]!
        let r = review(.init(name: "x", code: "c", token: "t",
                             e2eDeviceID: b64u(hex(c.target_device_id)),
                             label: b64u(hex(c.body)),
                             labelSignature: b64u(hex(c.signature)),
                             labelSignerBundle: b64u(hex(c.signer_bundle))))
        XCTAssertEqual(r.labelFailure, .signerNotAuthorised)
        XCTAssertEqual(r.nameSource, .unverified)
    }

    func testARevokedSignerCannotVouchForAName() {
        let r = review(row(), revoked: [hex(fx.devices["H"]!.device_id)])
        XCTAssertEqual(r.labelFailure, .signerChain)
        XCTAssertEqual(r.nameSource, .unverified)
    }

    func testGarbageInTheLabelFieldsIsRefusedWithoutTrapping() {
        for bad in ["not base64!", "", "AAAA"] {
            XCTAssertEqual(review(row(label: .some(bad))).nameSource, .unverified, bad)
        }
    }

    // MARK: - the listing as a whole

    /// NOTHING IS DROPPED. A row silently missing is indistinguishable from a device that is not
    /// running, and §12.2 is emphatic that absence must never be read as a verdict.
    func testOrderIsPreservedAndUnconnectableRowsAreMarkedNotRemoved() {
        let list = E2EHostList.review(
            [row(code: "a"), row(code: "b", deviceID: .some(nil)), row(code: "c", label: .some(nil))],
            trustedRootID: hex(fx.root_id), policy: policy)
        XCTAssertEqual(list.map(\.code), ["a", "b", "c"])
        XCTAssertEqual(list.map(\.connectable), [true, false, true])
        XCTAssertEqual(list.map(\.nameSource), [.verified, .unverified, .unverified])
    }

    func testAnEmptyListingReviewsToAnEmptyListing() {
        XCTAssertTrue(E2EHostList.review([], trustedRootID: hex(fx.root_id), policy: policy).isEmpty)
    }
}
