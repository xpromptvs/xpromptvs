import AppKit
import Metal
import QuartzCore
import RdevCore
import RdevHostKit
import ShellstormCore

/// A latest-frame mailbox feeding one GPU submission. Nothing reads IOSurface pixels on the CPU.
final class SimulatorMetalRenderer: @unchecked Sendable {
    private let device: MTLDevice
    private let commands: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let layer: CAMetalLayer
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "rdev.native-sim.render", qos: .userInteractive)
    private var schedule = SimulatorRenderSchedule()
    private var latest: SimulatorSurfaceFrame?
    private var viewport = CGSize.zero
    private var stopped = false
    private var count = 0
    private var lastAgeMs: Double = -1
    private var ages: [Double] = []
    private var received = 0
    var timing: [String: Any] { lock.withLock {
        let sorted = ages.sorted()
        func percentile(_ p: Double) -> Double { sorted.isEmpty ? -1 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
        return ["samples": sorted.count, "p50": percentile(0.5), "p95": percentile(0.95), "p99": percentile(0.99), "submissions": received, "presented": count]
    } }
    var onError: ((String) -> Void)?
    var metrics: (presented: Int, callbackAgeMs: Double) { lock.withLock { (count, lastAgeMs) } }

    init(layer: CAMetalLayer) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let commands = device.makeCommandQueue() else {
            throw NSError(domain: "NativeSimulator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Metal is unavailable"])
        }
        self.device = device; self.commands = commands; self.layer = layer
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "sim_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "sim_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        layer.device = device; layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true; layer.maximumDrawableCount = 2
        layer.presentsWithTransaction = false
        layer.colorspace = CGColorSpace(name: CGColorSpace.itur_709)
    }
    func submit(_ frame: SimulatorSurfaceFrame) {
        let run = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            received += 1
            latest = frame
            return schedule.offer(sequence: frame.sequence)
        }
        if run { queue.async { [weak self] in self?.draw() } }
    }
    func clear() { lock.withLock { latest = nil } }
    func setViewport(size: CGSize, scale: CGFloat) {
        let frame = lock.withLock { viewport = CGSize(width: size.width * scale, height: size.height * scale); return latest }
        if let frame { submit(frame) }
    }
    func setVisible(_ visible: Bool) {
        let frame = lock.withLock { schedule.setVisible(visible); return latest }
        if visible, let frame { submit(frame) }
    }
    func stop() { lock.withLock { stopped = true; latest = nil; schedule.stop() } }

    private func finished() {
        let again = lock.withLock { schedule.completed() != nil }
        if again { queue.async { [weak self] in self?.draw() } }
    }
    private func draw() {
        guard lock.withLock({ !stopped && latest != nil && viewport.width > 0 && viewport.height > 0 }) else { finished(); return }
        // nextDrawable may wait for a display. Take the newest frame AFTER that wait, not a queued one.
        guard let drawable = layer.nextDrawable() else { finished(); return }
        guard let (frame, size) = lock.withLock({ !stopped ? latest.map { ($0, viewport) } : nil }),
              size.width > 0, size.height > 0 else { finished(); return }
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: frame.surface.width, height: frame.surface.height, mipmapped: false)
        textureDescriptor.storageMode = .shared; textureDescriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: textureDescriptor, iosurface: frame.surface, plane: 0),
              let command = commands.makeCommandBuffer() else {
            onError?("Couldn't display the simulator framebuffer"); finished(); return
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { finished(); return }
        let shown = frame.rotation.shownSize(nativeW: frame.surface.width, nativeH: frame.surface.height)
        let fit = min(size.width / CGFloat(shown.w), size.height / CGFloat(shown.h))
        let sx = Float(CGFloat(shown.w) * fit / size.width), sy = Float(CGFloat(shown.h) * fit / size.height)
        let corners: [(Double, Double)] = [(0, 1), (1, 1), (0, 0), (1, 0)]
        var vertices: [SIMD4<Float>] = corners.map { x, y in
            let uv = frame.rotation.nativePoint(shownX: x, shownY: y)
            return SIMD4(Float(x * 2 - 1) * sx, Float(1 - y * 2) * sy, Float(uv.x), Float(uv.y))
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&vertices, length: MemoryLayout<SIMD4<Float>>.stride * vertices.count, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        drawable.addPresentedHandler { [weak self] shown in
            guard let self else { return }
            self.lock.withLock {
                self.count += 1
                let age = (shown.presentedTime - Double(frame.callbackNanos) / 1e9) * 1000
                // Zero/unavailable presentation timestamps are not a zero-latency measurement.
                self.lastAgeMs = shown.presentedTime > 0 && age >= 0 ? age : -1
                if self.lastAgeMs >= 0 { self.ages.append(age); if self.ages.count > 4096 { self.ages.removeFirst() } }
            }
        }
        command.addCompletedHandler { [weak self, frame, texture] buffer in
            _ = frame.surface; _ = texture  // retain imported pixels until the GPU finishes sampling
            if buffer.status == .error { self?.onError?(buffer.error?.localizedDescription ?? "Simulator rendering failed") }
            self?.finished()
        }
        #if RDEV_DEV_BUILD
        // Stress retained mutable surfaces: hold a prepared draw before GPU sampling. Test-only.
        if let text = ProcessInfo.processInfo.environment["RDEV_TEST_NATIVE_RENDER_DELAY_MS"], let ms = Double(text), ms > 0 {
            Thread.sleep(forTimeInterval: min(ms, 100) / 1000)
        }
        #endif
        command.present(drawable)
        command.commit()
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct V { float4 position [[position]]; float2 uv; };
    vertex V sim_vertex(uint id [[vertex_id]], constant float4 *vertices [[buffer(0)]]) {
        V out; out.position = float4(vertices[id].xy, 0, 1); out.uv = vertices[id].zw; return out;
    }
    fragment float4 sim_fragment(V in [[stage_in]], texture2d<float> image [[texture(0)]]) {
        constexpr sampler sample(filter::linear, address::clamp_to_edge);
        return float4(image.sample(sample, in.uv).rgb, 1);
    }
    """
}
