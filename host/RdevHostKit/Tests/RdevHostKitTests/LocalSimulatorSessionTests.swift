import CoreVideo
import XCTest
import RdevCore
@testable import RdevHostKit

private final class NativeNullVideo: VideoEncoding, @unchecked Sendable {
    var codec: NegotiatedCodec { .av1 }
    func encode(_ buffer: CVPixelBuffer, ptsNs: Int64) {}
    func addSink(_ sink: any VideoTrackSink) {}
    func removeSink(_ sink: any VideoTrackSink) {}
    func removeAllSinks() {}
    func requestKeyframe() {}
    func setFps(_ value: Int) {}
    func setBitrate(_ value: Int) {}
    func setCrop(_ value: CropRect) {}
    func invalidate() {}
}

final class LocalSimulatorSessionTests: XCTestCase {
    let id = "sim:9B45C574-451C-475D-8498-66BD68AEE17D"
    private func fixture(_ body: (ChannelHub, SimManager, SocketClients, MemorySocket, LocalSimulatorSession, FakeSimulators) throws -> Void) rethrows {
        let terminals = TerminalManager(cols: 80, rows: 24)
        let hub = ChannelHub(terminals: terminals, injector: nil, encoder: NativeNullVideo())
        let catalog = FakeSimulators()
        let manager = SimManager(makeEncoder: { _, _, _, _ in NativeNullVideo() }, channelHub: hub,
            defaultPrefs: VideoPrefs(fps: 60, scale: 1, bitrateBps: 2_000_000), bitrateCap: 8_000_000,
            throttleFps: 1, throttleBitrateBps: 100_000, simulators: catalog)
        manager.attachesCaptureForTests = false; hub.simDelegate = manager
        let clients = SocketClients(hub: hub), socket = MemorySocket()
        let local = clients.acceptLocal(socket, manager: manager)
        socket.hello("local"); socket.sends(.control, #"{"t":"client-hello","prefs":{}}"#)
        clients.drainForTests()
        defer { clients.closeAll(reason: "done"); clients.drainForTests(); manager.endSession(); terminals.closeAll() }
        try body(hub, manager, clients, socket, local, catalog)
    }
    func testBlockedUIReceivesCurrentOwnershipInsteadOfQueuedActiveSnapshots() throws {
        try fixture { _, manager, clients, _, local, _ in
            _ = manager.openWindow(sourceID: id, requestedBy: "sock:local")
            let lock = NSLock(), scheduled = DispatchSemaphore(value: 0)
            var jobs: [() -> Void] = [], values: [LocalSimulatorSnapshot] = []
            let observation = local.observeLatest(deliver: { work in
                lock.withLock { jobs.append(work) }; scheduled.signal()
            }, receive: { values.append($0) })
            defer { observation.cancel() }
            XCTAssertEqual(scheduled.wait(timeout: .now() + 2), .success)
            let other = MemorySocket(); clients.accept(other); other.hello("other"); clients.drainForTests()
            XCTAssertFalse(try XCTUnwrap(local.snapshot).driving)
            let queued = lock.withLock { jobs }
            for job in queued { job() }
            XCTAssertFalse(values.isEmpty)
            XCTAssertTrue(values.allSatisfy { !$0.driving }, "old queued work cannot create or front native windows")
        }
    }
    func testScrollPreparationCannotEnableAReplacementLocalAdmission() throws {
        try fixture { _, manager, clients, _, local, _ in
            _ = manager.openWindow(sourceID: id, requestedBy: "sock:local")
            let began = DispatchSemaphore(value:0), resume = DispatchSemaphore(value:0)
            let sink = SimulatorNativeScrollTests.Sink()
            let injector = SimulatorInputInjector(udid:"probe",connect:{nil},connectScroll:{began.signal();resume.wait();return sink},
                display:SimDisplayState(),control:SimulatorControl(run:{_,_,_ in (0,Data())}),nativePointW:400,nativePointH:800)
            manager.setInjectorForTests(id,injector)
            let done = expectation(description:"old preparation completes")
            local.prepareScrollGestures(source:id,generation:try XCTUnwrap(local.snapshot).generation) { ready in
                XCTAssertFalse(ready);done.fulfill()
            }
            XCTAssertEqual(began.wait(timeout:.now()+2),.success)
            let other = MemorySocket();clients.accept(other);other.hello("other");clients.drainForTests()
            resume.signal();wait(for:[done],timeout:2)
            XCTAssertTrue(sink.events.isEmpty)
        }
    }
    func testSnapshotRetriesWhenStateChangesBetweenReadAndStamp() throws {
        try fixture { _, manager, clients, _, local, _ in
            _ = manager.openWindow(sourceID: id, requestedBy: "sock:local")
            local.afterStateReadForTests = {
                local.afterStateReadForTests = nil
                manager.closeWindow(sourceID: self.id, land: false, requestedBy: "sock:local")
            }
            let value = try XCTUnwrap(local.snapshot)
            XCTAssertFalse(value.state.contains(id), "the latest revision must never label old membership")
            clients.drainForTests()
        }
    }
    func testMinimizedInputCannotFallThroughToAnotherSimulator() throws {
        try fixture { hub, manager, clients, _, local, _ in
            let b = "sim:11111111-1111-1111-1111-111111111111"
            _ = manager.openWindow(sourceID: id, requestedBy: "sock:local")
            _ = manager.openWindow(sourceID: b, requestedBy: "sock:local")
            let sink = SimulatorInputInjectorTests.Sink()
            let inj = SimulatorInputInjector(udid: "B", connect: { sink }, display: SimDisplayState(),
                control: SimulatorControl(run: { _, _, _ in (0, Data()) }), nativePointW: 402, nativePointH: 874)
            manager.setInjectorForTests(b, inj); hub.setInjector(inj)
            manager.minimizeWindow(sourceID: id, land: false, requestedBy: "sock:local")
            local.perform(.simTouch(phase: "down", points: [SimPoint(x: 0.5, y: 0.5)]), source: id,
                          generation: try XCTUnwrap(local.snapshot).generation)
            clients.drainForTests(); inj.drainForTests()
            XCTAssertTrue(sink.all.isEmpty, "A's delayed event must never target B")
        }
    }
    func testReplacementRebuildsTheNativeInputAdmission() throws {
        try fixture { _, manager, clients, socket, local, catalog in
            let sink = SimulatorInputInjectorTests.Sink(); catalog.hid = { sink }
            manager.attachesCaptureForTests = true
            _ = manager.openWindow(sourceID: id, requestedBy: "sock:local")
            let deadline = Date().addingTimeInterval(3)
            while manager.injectorForTests(id) == nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            let old = try XCTUnwrap(manager.injectorForTests(id))
            socket.holdsClose = true
            let replacement = MemorySocket(); let next = clients.acceptLocal(replacement, manager: manager)
            replacement.hello("local"); replacement.sends(.control, #"{"t":"client-hello","prefs":{}}"#)
            clients.drainForTests()
            let end = Date().addingTimeInterval(3)
            while (manager.injectorForTests(id) == nil || manager.injectorForTests(id) === old) && Date() < end {
                Thread.sleep(forTimeInterval: 0.01)
            }
            let fresh = try XCTUnwrap(manager.injectorForTests(id) as? SimulatorInputInjector)
            next.perform(.simTouch(phase: "down", points: [SimPoint(x: 0.25, y: 0.25)]), source: id,
                         generation: try XCTUnwrap(next.snapshot).generation)
            clients.drainForTests(); fresh.drainForTests()
            XCTAssertEqual(sink.all.count, 1, "replacement must drive the guest, not just see its pixels")
            XCTAssertFalse(old === fresh)
        }
    }
    func testAnOldTouchBlockedInConnectStaysDeadAfterReturningToSameClient() throws {
        try fixture { _, manager, clients, socket, local, catalog in
            let sink = SimulatorInputInjectorTests.Sink()
            let entered = DispatchSemaphore(value: 0), finish = DispatchSemaphore(value: 0)
            catalog.hid = { entered.signal(); _ = finish.wait(timeout: .now() + 5); return sink }
            manager.attachesCaptureForTests = true
            _ = manager.openWindow(sourceID: id, requestedBy: "sock:local")
            let deadline = Date().addingTimeInterval(3)
            while manager.injectorForTests(id) == nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            let old = try XCTUnwrap(manager.injectorForTests(id) as? SimulatorInputInjector)
            old.simTouch(phase: "down", points: [SimPoint(x: 0.5, y: 0.5)])
            XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
            let other = MemorySocket(); clients.accept(other, presentation: .streamedSources); other.hello("other")
            clients.drainForTests() // no client-hello: remote never rebuilds the stream
            socket.sends(.control, #"{"t":"claim-control"}"#); clients.drainForTests()
            finish.signal(); old.drainForTests()
            XCTAssertTrue(sink.all.isEmpty, "returning to A must not revive input from A's old ownership")
        }
    }
    func testOwnershipClosesPresentationWithoutRemovingTabsAndFencesOldIntents() throws {
        let terminals = TerminalManager(cols: 80, rows: 24)
        let hub = ChannelHub(terminals: terminals, injector: nil, encoder: NativeNullVideo())
        let catalog = FakeSimulators()
        let manager = SimManager(makeEncoder: { _, _, _, _ in XCTFail("native must not encode"); return NativeNullVideo() },
                                 channelHub: hub, defaultPrefs: VideoPrefs(fps: 60, scale: 1, bitrateBps: 2_000_000),
                                 bitrateCap: 8_000_000, throttleFps: 1, throttleBitrateBps: 100_000, simulators: catalog)
        manager.attachesCaptureForTests = false
        hub.simDelegate = manager
        let clients = SocketClients(hub: hub)
        defer { clients.closeAll(reason: "done"); clients.drainForTests(); manager.endSession(); terminals.closeAll() }
        let socket = MemorySocket()
        let local = clients.acceptLocal(socket, manager: manager)
        socket.hello("local")
        socket.sends(.control, #"{"t":"client-hello","prefs":{}}"#)
        socket.sends(.control, "{\"t\":\"subscribe\",\"source\":\"\(id)\"}")
        clients.drainForTests()
        let first = try XCTUnwrap(local.snapshot)
        XCTAssertTrue(first.driving)
        XCTAssertEqual(first.state.streamed, [id])
        XCTAssertNil(manager.encoderForSource(id))
        manager.stopRemoteStreams()
        XCTAssertEqual(manager.subscribedSourceIDs(), [id], "Stop Sharing must keep a locally driven simulator alive")
        let other = MemorySocket(); clients.accept(other); other.hello("other")
        clients.drainForTests()
        XCTAssertFalse(try XCTUnwrap(local.snapshot).driving)
        XCTAssertEqual(try XCTUnwrap(local.snapshot).state.streamed, [id])
        local.perform(.unsubscribe(source: id), source: id, generation: first.generation)
        clients.drainForTests()
        socket.sends(.control, #"{"t":"claim-control"}"#)
        clients.drainForTests()
        let back = try XCTUnwrap(local.snapshot)
        XCTAssertTrue(back.driving)
        XCTAssertGreaterThan(back.generation, first.generation)
        XCTAssertEqual(back.state.streamed, [id], "stale close must not remove the session tab")
        local.perform(.minimizeWindow(source: id), source: id, generation: back.generation)
        clients.drainForTests()
        XCTAssertEqual(try XCTUnwrap(local.snapshot).state.windows.first?.minimized, true)
        socket.clientClose(); clients.drainForTests()
        XCTAssertFalse(try XCTUnwrap(local.snapshot).driving)
    }
}
