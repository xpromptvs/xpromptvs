import XCTest
import CoreVideo
import LLVCore
import RdevCore
@testable import RdevHostKit

/// Exercises the product factory, including its CBR and screen-content controls.
final class AV1ReferenceCodecTests: XCTestCase {
    private final class Sink: VideoTrackSink {
        var sinkKey: SinkKey { SinkKey(peer: ObjectIdentifier(self), slot: 0) }
        var frames: [[String: Any]] = []
        var metadata: [AV1ReferenceFrameMetadata] = []
        var onFrame: (() -> Void)?
        func writeVideo(_ payload: [UInt8], ptsNs: Int64, keyframe: Bool, reference: AV1ReferenceFrameMetadata) {
            metadata.append(reference)
            writeVideo(payload, ptsNs: ptsNs, keyframe: keyframe)
        }
        func writeVideo(_ payload: [UInt8], ptsNs: Int64, keyframe: Bool) {
            frames.append(["data": Data(payload).base64EncodedString(), "keyframe": keyframe, "ptsNs": ptsNs])
            onFrame?()
        }
    }
    private func image(_ frame: Int, width: Int = 320, height: Int = 180) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &result), kCVReturnSuccess)
        let buffer = try XCTUnwrap(result)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height { for x in 0..<width {
            let offset = y * stride + x * 4
            let moving = (x + frame * 3) % 160 < 30
            bytes[offset] = UInt8((x / 8 + y / 8) % 2 == 0 ? 30 : 210)
            bytes[offset + 1] = UInt8(moving ? 220 : 40)
            bytes[offset + 2] = UInt8((y + frame) % 100 + 40)
            bytes[offset + 3] = 255
        } }
        return buffer
    }
    func testProductProfileRecoveryAndIdleRepeatRemainInterFrames() throws {
        for badAnchor in [false, true] {
            let adapter = LLVEncoderAdapter(fps: 60, bitrateBps: 1_500_000, label: "reference-fixture")
            let sink = Sink(); adapter.addSink(sink)
            var state = AV1ReferenceState(epoch: "initial")
            var currentFrame = 0
            if !badAnchor {
                adapter.setReferencePlanner { epoch, frameID, force in
                    if state.epoch != epoch { state.reset(epoch: epoch) }
                    return state.prepareFrame(frameID: frameID, nowNs: UInt64(currentFrame + 1) * 16_666_667,
                        intent: force ? .independentKeyframe : currentFrame == 70 ? .repairEstablishedStream : nil,
                        nextWireFrameNumber: UInt64(currentFrame))
                }
            }
            for frame in 0..<100 {
                currentFrame = frame
                // Fixture policy only: every ordinary frame uses six recent ordinary slots.
                // Slot 6 is the initial confirmed keyframe, never refreshed by ordinary traffic.
                let slots = (0..<6).map { UInt8((frame + 5 - $0) % 6) } + [UInt8(7)]
                let control: AV1ReferenceControl
                if frame == 70 {
                    control = try AV1ReferenceControl(referenceSlots: [badAnchor ? 3 : 6, 0, 1, 2, 3, 4, 5],
                        enabledReferences: 1, refreshSlotMask: 63, recovery: true)
                } else {
                    control = try AV1ReferenceControl(referenceSlots: slots, enabledReferences: frame == 0 ? 0 : 63,
                        refreshSlotMask: frame == 0 ? 255 : 1 << (frame % 6), recovery: false)
                }
                if badAnchor { adapter.setReferenceControl(control) }
                if frame == 70 { XCTAssertTrue(adapter.encodeRecoveryFromStaging(ptsNs: Int64(frame + 1) * 16_666_667)) }
                else { adapter.encode(try image(frame), ptsNs: Int64(frame + 1) * 16_666_667) }
                if !badAnchor, let output = ProcessInfo.processInfo.environment["RDEV_AV1_REFERENCE_FIXTURES"] {
                    let directory = URL(fileURLWithPath: output)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let source = try image(frame == 70 ? 69 : frame)
                    CVPixelBufferLockBaseAddress(source, .readOnly)
                    defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
                    let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(source)).assumingMemoryBound(to: UInt8.self)
                    let stride = CVPixelBufferGetBytesPerRow(source)
                    var ppm = Data("P6\n320 180\n255\n".utf8)
                    for y in 0..<180 { for x in 0..<320 {
                        let i = y * stride + x * 4
                        ppm.append(contentsOf: [base[i + 2], base[i + 1], base[i]])
                    } }
                    try ppm.write(to: directory.appendingPathComponent("source-\(frame).ppm"))
                }
                if !badAnchor, frame == 0 {
                    let token = try XCTUnwrap(sink.metadata.last?.token)
                    state.didSend(token: token, result: ReferenceSendResult(rtpTimestamp: 123, wireFrameNumber: 0, complete: true), nowNs: 1, rttNs: nil)
                    XCTAssertEqual(state.acknowledge(token: token, recoveryID: nil, nowNs: 2), .promote(token))
                }
                if frame == 40 { adapter.setBitrate(1_200_000) }
            }
            XCTAssertEqual(sink.frames.count, 100)
            XCTAssertEqual(sink.frames.compactMap { $0["keyframe"] as? Bool }.filter { $0 }.count, 1)
            XCTAssertEqual(sink.frames[70]["keyframe"] as? Bool, false)
            if !badAnchor {
                XCTAssertEqual(sink.metadata[70].dependencies, [1])
                XCTAssertEqual(sink.metadata[70].refreshSlotMask, 63)
                XCTAssertNotNil(sink.metadata[70].recoveryID)
                XCTAssertEqual(sink.metadata[71].dependencies, [71])
            }
            if let output = ProcessInfo.processInfo.environment["RDEV_AV1_REFERENCE_FIXTURES"] {
                let directory = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: sink.frames).write(to: directory.appendingPathComponent(badAnchor ? "unconfirmed.json" : "confirmed.json"))
            }
            adapter.invalidate()
        }
    }
    func testRecoveryDoesNotAllowAnOlderQueuedCaptureToMoveTheClockBackwards() throws {
        let adapter = LLVEncoderAdapter(fps: 60, bitrateBps: 1_500_000, label: "recovery-clock")
        let sink = Sink(); adapter.addSink(sink)
        adapter.encode(try image(0), ptsNs: 20)
        XCTAssertTrue(adapter.encodeRecoveryFromStaging(ptsNs: 20))
        adapter.encode(try image(1), ptsNs: 19)
        adapter.encode(try image(2), ptsNs: 22)
        XCTAssertEqual(sink.frames.compactMap { $0["ptsNs"] as? Int64 }, [20, 21, 22])
    }
    func testMetadataTracksTheRealEpochAndAllEnabledDependencies() throws {
        let adapter = LLVEncoderAdapter(fps: 60, bitrateBps: 1_500_000, label: "reference-metadata")
        let sink = Sink(); adapter.addSink(sink)
        var state = AV1ReferenceState(epoch: "initial")
        adapter.setReferencePlanner { epoch, frameID, force in
            if state.epoch != epoch { state.reset(epoch: epoch) }
            return state.prepareFrame(frameID: frameID, nowNs: frameID * 16_666_667,
                                      intent: force ? .independentKeyframe : nil)
        }
        for frame in 0..<9 { adapter.encode(try image(frame), ptsNs: Int64(frame + 1)) }
        XCTAssertEqual(sink.metadata.count, 9)
        let first = try XCTUnwrap(sink.metadata.first)
        XCTAssertEqual(first.frameID, 1)
        XCTAssertEqual(first.dependencies, [])
        XCTAssertEqual(first.token?.frameID, 1)
        XCTAssertEqual(sink.metadata[1].dependencies, [1])
        XCTAssertEqual(Set(sink.metadata[8].dependencies), Set([4, 5, 6, 7, 8]))
        adapter.setBitrate(1_200_000)
        adapter.encode(try image(9), ptsNs: 10)
        XCTAssertEqual(sink.metadata.last?.epoch, first.epoch)
        adapter.setFps(30)
        adapter.encode(try image(10), ptsNs: 11)
        let recreated = try XCTUnwrap(sink.metadata.last)
        XCTAssertNotEqual(recreated.epoch, first.epoch)
        XCTAssertEqual(recreated.frameID, 1)
        XCTAssertEqual(recreated.dependencies, [])
        XCTAssertEqual(recreated.token?.epoch, recreated.epoch)
        adapter.encode(try image(11, height: 182), ptsNs: 12)
        XCTAssertNotEqual(sink.metadata.last?.epoch, recreated.epoch)
        XCTAssertEqual(sink.metadata.last?.dependencies, [])
        adapter.invalidate()
    }
    func testRejectedPlanInvalidatesEpochAndRearmsAKeyframe() throws {
        let adapter = LLVEncoderAdapter(fps: 60, bitrateBps: 1_500_000, label: "rejected-plan")
        let sink = Sink(); adapter.addSink(sink)
        var state = AV1ReferenceState(epoch: "initial")
        var reject = false
        adapter.setReferencePlanner { epoch, frameID, force in
            if state.epoch != epoch { state.reset(epoch: epoch) }
            var plan = state.prepareFrame(frameID: frameID, nowNs: frameID,
                                          intent: force ? .independentKeyframe : nil)
            if reject {
                plan.candidate = ReferenceToken(epoch: "stale", frameID: frameID, slot: 7, slotGeneration: 1)
                reject = false
            }
            return plan
        }
        adapter.encode(try image(0), ptsNs: 1)
        let oldEpoch = try XCTUnwrap(sink.metadata.last?.epoch)
        reject = true
        adapter.encode(try image(1), ptsNs: 2)
        XCTAssertEqual(sink.frames.count, 1, "a rejected frame publishes no bytes or metadata")
        adapter.encode(try image(2), ptsNs: 3)
        XCTAssertEqual(sink.frames.count, 2)
        XCTAssertNotEqual(sink.metadata.last?.epoch, oldEpoch)
        XCTAssertEqual(sink.frames.last?["keyframe"] as? Bool, true)
        XCTAssertEqual(sink.metadata.last?.dependencies, [])
    }
    func testActualCodecRefusalRearmsInsteadOfLosingTheRequest() throws {
        let adapter = LLVEncoderAdapter(fps: 60, bitrateBps: 1_500_000, label: "codec-refusal")
        let sink = Sink(); adapter.addSink(sink)
        let independent = try AV1ReferenceControl(referenceSlots: [0, 1, 2, 3, 4, 5, 6],
            enabledReferences: 0, refreshSlotMask: 255, recovery: false)
        adapter.setReferenceControl(independent)
        adapter.encode(try image(0), ptsNs: 1)
        // Explicit mode refuses a frame with no fresh plan. This exercises a real C bridge error.
        adapter.encode(try image(1), ptsNs: 2)
        XCTAssertEqual(sink.frames.count, 1)
        adapter.setReferenceControl(independent)
        adapter.encode(try image(2), ptsNs: 3)
        XCTAssertEqual(sink.frames.count, 2)
        XCTAssertEqual(sink.frames.last?["keyframe"] as? Bool, true)
    }
    func testInvalidCaptureDoesNotConsumeTheReferencePlan() throws {
        let adapter = LLVEncoderAdapter(fps: 60, bitrateBps: 1_500_000, label: "invalid-capture")
        let sink = Sink(); adapter.addSink(sink)
        var calls = 0
        var state = AV1ReferenceState(epoch: "initial")
        adapter.setReferencePlanner { epoch, frameID, force in
            calls += 1
            if state.epoch != epoch { state.reset(epoch: epoch) }
            return state.prepareFrame(frameID: frameID, nowNs: frameID, intent: force ? .independentKeyframe : nil)
        }
        var invalid: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32ARGB, nil, &invalid), kCVReturnSuccess)
        adapter.encode(try XCTUnwrap(invalid), ptsNs: 1)
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(adapter.encodeRecoveryFromStaging(ptsNs: 2))
        adapter.encode(try image(0), ptsNs: 3)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(sink.frames.last?["keyframe"] as? Bool, true)
        adapter.setFps(30)
        XCTAssertFalse(adapter.encodeRecoveryFromStaging(ptsNs: 4), "old staging cannot bypass an encoder rebuild")
        adapter.encode(try image(1), ptsNs: 5)
        XCTAssertEqual(sink.frames.last?["keyframe"] as? Bool, true)
        adapter.invalidate()
        XCTAssertFalse(adapter.encodeRecoveryFromStaging(ptsNs: 6))
    }
    func testQueuedRecoveryCannotEnterAReplacementPlanner() {
        let queue = DispatchQueue(label: "test.recovery-generation")
        let adapter = LLVEncoderAdapter(fps: 60, bitrateBps: 1_500_000, recoveryQueue: queue)
        let sink = Sink(); adapter.addSink(sink)
        adapter.setReferencePlanner { _, _, _ in ReferenceFramePlan(forceIndependent: true) }
        queue.suspend()
        adapter.requestRecovery(.repairEstablishedStream)
        adapter.disableReferencePlanner()
        var calls = 0
        adapter.setReferencePlanner({ _, _, _ in ReferenceFramePlan(forceIndependent: true) }, onRequest: { _ in calls += 1 })
        queue.resume()
        queue.sync {}
        XCTAssertEqual(calls, 0, "an old receiver's queued request must not reach its replacement")
        adapter.invalidate()
    }

    func testRequestedRecoveryUsesIdleStagingOffTheCaptureQueue() throws {
        let adapter = LLVEncoderAdapter(fps: 60, bitrateBps: 1_500_000, label: "idle-request")
        let sink = Sink(); adapter.addSink(sink)
        var state = AV1ReferenceState(epoch: "initial")
        var intent: RecoveryIntent?
        adapter.setReferencePlanner({ epoch, frameID, force in
            if state.epoch != epoch { state.reset(epoch: epoch) }
            defer { intent = nil }
            return state.prepareFrame(frameID: frameID, nowNs: frameID, intent: force ? .independentKeyframe : intent, nextWireFrameNumber: frameID)
        }, onRequest: { intent = $0 })
        let captureKey = DispatchSpecificKey<Bool>()
        let captureQueue = DispatchQueue(label: "test.capture")
        captureQueue.setSpecific(key: captureKey, value: true)
        let source = try image(0)
        let captureStarted = DispatchTime.now().uptimeNanoseconds
        captureQueue.sync { adapter.encode(source, ptsNs: 1) }
        let token = try XCTUnwrap(sink.metadata.last?.token)
        state.didSend(token: token, result: ReferenceSendResult(rtpTimestamp: 1, wireFrameNumber: 1, complete: true), nowNs: 1, rttNs: nil)
        XCTAssertEqual(state.acknowledge(token: token, recoveryID: nil, nowNs: 1), .promote(token))
        let idle = expectation(description: "idle recovery emitted")
        sink.onFrame = {
            XCTAssertNil(DispatchQueue.getSpecific(key: captureKey))
            idle.fulfill()
        }
        adapter.setBitrate(1_200_000)
        adapter.requestRecovery(.repairEstablishedStream)
        wait(for: [idle], timeout: 2)
        sink.onFrame = nil
        XCTAssertEqual(sink.frames.count, 2)
        XCTAssertEqual(sink.frames.last?["keyframe"] as? Bool, false)
        XCTAssertEqual(sink.metadata.last?.epoch, token.epoch)
        XCTAssertNotNil(sink.metadata.last?.recoveryID)
        // A source may use an epoch unrelated to system uptime. After an idle
        // repeat, its next fresh capture must still reach the encoder.
        let resumedPTS = Int64(DispatchTime.now().uptimeNanoseconds - captureStarted) + 1
        captureQueue.sync { adapter.encode(source, ptsNs: resumedPTS) }
        XCTAssertEqual(sink.frames.count, 3, "idle recovery must preserve the capture clock epoch")
        let independent = expectation(description: "independent fallback emitted")
        sink.onFrame = { independent.fulfill() }
        adapter.requestRecovery(.independentKeyframe)
        wait(for: [independent], timeout: 2)
        sink.onFrame = nil
        XCTAssertEqual(sink.frames.last?["keyframe"] as? Bool, true)
        XCTAssertNotEqual(sink.metadata.last?.epoch, token.epoch)
        adapter.disableReferencePlanner()
        let before = sink.metadata.count
        adapter.encode(try image(1), ptsNs: Int64(DispatchTime.now().uptimeNanoseconds))
        XCTAssertEqual(sink.metadata.count, before)
        XCTAssertEqual(sink.frames.last?["keyframe"] as? Bool, true)
        adapter.invalidate()
    }
    func testUnmappedRefreshIsRejectedRatherThanSilentlyIgnored() {
        XCTAssertThrowsError(try AV1ReferenceControl(referenceSlots: [0, 1, 2, 3, 4, 5, 7],
            enabledReferences: 63, refreshSlotMask: 64, recovery: false))
    }
    func testIdleRecoveryWithoutAStagingImageRefuses() {
        let adapter = LLVEncoderAdapter(fps: 60, bitrateBps: 1_500_000, label: "no-staging")
        XCTAssertFalse(adapter.encodeRecoveryFromStaging(ptsNs: 1))
    }
    func testInvalidReferenceMappingRefusesBeforeEncoding() {
        XCTAssertThrowsError(try AV1ReferenceControl(referenceSlots: [8, 0, 0, 0, 0, 0, 0], enabledReferences: 1, refreshSlotMask: 1, recovery: false))
        XCTAssertThrowsError(try AV1ReferenceControl(referenceSlots: [0], enabledReferences: 1, refreshSlotMask: 1, recovery: false))
    }
}
