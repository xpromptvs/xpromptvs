import XCTest
import CoreVideo
import RdevCore
import LLVCore
import Darwin
@testable import RdevHostKit

/// Opt-in, offline encoder comparison. The separate live gate checks functional
/// transport/presentation, not matched performance. These times include conversion
/// and the synchronous sink.
final class AV1QualificationReplayTests: XCTestCase {
    private struct Manifest: Decodable {
        struct Frame: Decodable { let file: String; let ptsNs: String }
        let frames: [Frame]
    }
    private final class Sink: VideoTrackSink {
        var sinkKey: SinkKey { SinkKey(peer: ObjectIdentifier(self), slot: 0) }
        var frames: [[String: Any]] = []
        var latest: AV1ReferenceFrameMetadata?
        func writeVideo(_ payload: [UInt8], ptsNs: Int64, keyframe: Bool) {
            frames.append(["data": Data(payload).base64EncodedString(), "keyframe": keyframe, "ptsNs": String(ptsNs)])
        }
        func writeVideo(_ payload: [UInt8], ptsNs: Int64, keyframe: Bool, reference: AV1ReferenceFrameMetadata) {
            latest = reference
            writeVideo(payload, ptsNs: ptsNs, keyframe: keyframe)
        }
    }
    private func cpu() -> Double {
        var value = rusage(); getrusage(RUSAGE_SELF, &value)
        return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1e6
    }
    func testReplayCapturedSequenceThroughBothProductPolicies() throws {
        let env = ProcessInfo.processInfo.environment
        guard let input = env["RDEV_AV1_QUALIFICATION_INPUT"], let output = env["RDEV_AV1_QUALIFICATION_OUTPUT"] else {
            throw XCTSkip("owned capture qualification is opt-in")
        }
        let root = URL(fileURLWithPath: input), destination = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("complete.json")))
        XCTAssertGreaterThanOrEqual(manifest.frames.count, 180)
        let repair = env["RDEV_AV1_QUALIFICATION_REPAIR"] == "1"
        let origin = try XCTUnwrap(Int64(manifest.frames[0].ptsNs))
        var reports: [[String: Any]] = []
        for repetition in 0..<3 {
            // Alternate order so thermal/startup effects do not always favor one policy.
            let arms = env["RDEV_AV1_QUALIFICATION_GOLDEN"] == "1" ? ["automatic", "golden"] : ["automatic", "reserved"]
            for arm in (repetition % 2 == 0 ? arms : arms.reversed()) {
                let reserved = arm == "reserved"
                let name = "\(arm)-\(repetition)"
                let adapter = LLVEncoderAdapter(fps: 60, bitrateBps: 1_900_000, label: name)
                defer { adapter.invalidate() }
                let sink = Sink(); adapter.addSink(sink)
                var state = AV1ReferenceState(epoch: "initial")
                var now: UInt64 = 1, wire: UInt64 = 0
                var recoveryFrame = false
                if reserved {
                    adapter.setReferencePlanner { epoch, frameID, force in
                        if state.epoch != epoch { state.reset(epoch: epoch) }
                        return state.prepareFrame(frameID: frameID, nowNs: now,
                            intent: force ? .independentKeyframe : recoveryFrame ? .repairEstablishedStream : nil, nextWireFrameNumber: wire)
                    }
                }
                let exportSource = arm == "automatic" && repetition == 0
                let sourceURL = destination.appendingPathComponent("source.gray.gz")
                var source: FileHandle?
                var compressor: Process?
                var compressedOutput: FileHandle?
                if exportSource {
                    XCTAssertTrue(FileManager.default.createFile(atPath: sourceURL.path, contents: nil))
                    compressedOutput = try FileHandle(forWritingTo: sourceURL)
                    let pipe = Pipe(), process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
                    process.arguments = ["-c", "-1"]
                    process.standardInput = pipe; process.standardOutput = compressedOutput
                    try process.run(); source = pipe.fileHandleForWriting; compressor = process
                }
                defer { try? source?.close(); compressor?.waitUntilExit(); try? compressedOutput?.close() }
                var times: [Double] = [], cpuTimes: [Double] = []
                var width = 0, height = 0
                for (index, entry) in manifest.frames.enumerated() {
                    try autoreleasepool {
                        let image = try JSONDecoder().decode(AV1QualificationFrame.self, from: Data(contentsOf: root.appendingPathComponent(entry.file))).pixelBuffer()
                        let pts = try XCTUnwrap(Int64(entry.ptsNs)) - origin + 1
                        now = UInt64(pts); wire = UInt64(index)
                        recoveryFrame = repair && index == 150
                        if recoveryFrame && arm == "automatic" { adapter.requestKeyframe() }
                        if recoveryFrame && reserved {
                            XCTAssertLessThanOrEqual(try XCTUnwrap(state.confirmed).frameID, 130)
                        }
                        if arm == "golden" {
                            // Qualification-only alternative: five rotating ordinary slots
                            // and a separate ordinary golden slot, never an anchor slot.
                            let next = index % 5
                            let last = UInt8((next + 4) % 5), alt = UInt8((next + 1) % 5)
                            let plan = state.prepareFrame(frameID: UInt64(index + 1), nowNs: now, intent: index == 0 ? .independentKeyframe : nil, nextWireFrameNumber: wire)
                            let mapping: [UInt8] = [last, UInt8(next), plan.candidate?.slot ?? 7, 5, last, last, alt]
                            let refresh: UInt8 = index == 0 ? 255 : (1 << UInt8(next)) | (index % 40 == 0 ? 32 : 0) | plan.refreshSlotMask
                            adapter.setReferenceControl(try AV1ReferenceControl(referenceSlots: mapping, enabledReferences: index == 0 ? 0 : 73, refreshSlotMask: refresh, recovery: false))
                            if let token = plan.candidate {
                                state.didSend(token: token, result: ReferenceSendResult(rtpTimestamp: UInt32(index * 1500), wireFrameNumber: wire, complete: true), nowNs: now, rttNs: 0)
                                _ = state.acknowledge(token: token, recoveryID: nil, nowNs: now)
                            }
                        }
                        let beforeCPU = cpu(), before = DispatchTime.now().uptimeNanoseconds
                        adapter.encode(image, ptsNs: pts)
                        times.append(Double(DispatchTime.now().uptimeNanoseconds - before) / 1e6)
                        cpuTimes.append((cpu() - beforeCPU) * 1000)
                        XCTAssertEqual(sink.frames.count, index + 1)
                        if reserved, let metadata = sink.latest, let token = metadata.token {
                            state.didSend(token: token, result: ReferenceSendResult(rtpTimestamp: UInt32(index * 1500), wireFrameNumber: wire, complete: true), nowNs: now, rttNs: 0)
                            // The simulated receiver cannot acknowledge a frame removed
                            // by the loss fixture. Sent and presented are separate facts.
                            if !repair || index < 130 || index >= 150 {
                                _ = state.acknowledge(token: token, recoveryID: metadata.recoveryID, nowNs: now)
                            }
                        }
                        if exportSource {
                            let luma = try XCTUnwrap(adapter.stagingLumaForTest())
                            width = luma.width; height = luma.height
                            for row in 0..<height { try source?.write(contentsOf: Data(luma.bytes[(row * luma.stride)..<(row * luma.stride + width)])) }
                        }
                    }
                }
                if repair {
                    XCTAssertEqual(sink.frames[150]["keyframe"] as? Bool, arm == "automatic")
                    XCTAssertEqual(sink.frames.filter { $0["keyframe"] as? Bool == true }.count, arm == "automatic" ? 2 : 1)
                }
                try JSONSerialization.data(withJSONObject: sink.frames).write(to: destination.appendingPathComponent(name + ".json"))
                reports.append(["arm": arm, "repetition": repetition,
                                "wallMs": times, "cpuMs": cpuTimes, "width": width, "height": height,
                                "repair": repair, "frames": sink.frames.count, "keyframes": sink.frames.filter { $0["keyframe"] as? Bool == true }.count])
            }
        }
        try JSONSerialization.data(withJSONObject: reports, options: [.sortedKeys]).write(to: destination.appendingPathComponent("encoding.json"))
    }
}
