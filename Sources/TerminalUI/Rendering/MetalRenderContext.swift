import Foundation
import Metal
import QuartzCore

/// Metal の描画に使う、作るのに時間のかかるもの（デバイス、コマンドキュー、コンパイルしたパイプライン）。
///
/// 作ったあとは変えないので、スレッドをまたいで渡してよい（`MTLDevice` などはスレッドセーフ）。
final class MetalRenderContext: @unchecked Sendable {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let rectPipeline: MTLRenderPipelineState
    let glyphPipeline: MTLRenderPipelineState
    let imagePipeline: MTLRenderPipelineState
    /// 描画先のピクセル形式（sRGB の値のまま合成する）。
    static let pixelFormat = MTLPixelFormat.bgra8Unorm
    /// コンパイルにかかった時間。
    let compileDuration: Duration

    enum LoadError: Error, CustomStringConvertible {
        case noDevice
        case missingFunction(String)
        case noQueue

        var description: String {
            switch self {
            case .noDevice: return "Metal のデバイスがありません"
            case .missingFunction(let name): return "シェーダーに \(name) がありません"
            case .noQueue: return "コマンドキューを作れません"
            }
        }
    }

    /// シェーダーをコンパイルし、パイプラインを作る（数十 ms かかる。メインスレッドでは呼ばない）。
    init(device: MTLDevice? = MTLCreateSystemDefaultDevice(), source: String = MetalShaders.source) throws {
        guard let device else { throw LoadError.noDevice }
        let clock = ContinuousClock()
        let start = clock.now
        let library = try device.makeLibrary(source: source, options: nil)
        func function(_ name: String) throws -> MTLFunction {
            guard let function = library.makeFunction(name: name) else { throw LoadError.missingFunction(name) }
            return function
        }
        func pipeline(vertex: String, fragment: String) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = try function(vertex)
            descriptor.fragmentFunction = try function(fragment)
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = Self.pixelFormat
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        rectPipeline = try pipeline(vertex: "rect_vertex", fragment: "rect_fragment")
        glyphPipeline = try pipeline(vertex: "glyph_vertex", fragment: "glyph_fragment")
        imagePipeline = try pipeline(vertex: "image_vertex", fragment: "image_fragment")
        guard let queue = device.makeCommandQueue() else { throw LoadError.noQueue }
        queue.label = "Tabghostty.render"
        self.device = device
        self.queue = queue
        compileDuration = clock.now - start
    }
}

/// `MetalRenderContext` を、起動時に 1 回だけバックグラウンドで作る（phase5 design D1 の Risks）。
///
/// 作り終わるまで、ビューは Core Text で描く。作れなかったら（デバイスが無い、コンパイルに失敗した）ログを出し、
/// Core Text で描き続ける。
@MainActor
enum MetalRenderContextLoader {
    enum State {
        case idle
        case loading([(MetalRenderContext?) -> Void])
        case ready(MetalRenderContext)
        case failed
    }

    private static var state = State.idle

    /// 作り始める（もう始めていれば何もしない）。アプリの起動時に呼ぶと、最初の画面から Metal で描ける。
    static func preload() {
        request { _ in }
    }

    /// 作り終わったら（作れなかったら nil で）`completion` を呼ぶ。作り終わっていれば、すぐに呼ぶ。
    static func request(_ completion: @escaping (MetalRenderContext?) -> Void) {
        switch state {
        case .ready(let context):
            completion(context)
        case .failed:
            completion(nil)
        case .loading(var waiters):
            waiters.append(completion)
            state = .loading(waiters)
        case .idle:
            state = .loading([completion])
            Task.detached(priority: .userInitiated) {
                let result = Result { try MetalRenderContext() }
                await MainActor.run { finish(result) }
            }
        }
    }

    private static func finish(_ result: Result<MetalRenderContext, any Error>) {
        guard case .loading(let waiters) = state else { return }
        let context: MetalRenderContext?
        switch result {
        case .success(let made):
            context = made
            state = .ready(made)
            let milliseconds = Double(made.compileDuration.components.attoseconds) / 1e15
                + Double(made.compileDuration.components.seconds) * 1000
            RenderLog.logger.notice(
                "Metal のシェーダーをコンパイルしました（\(made.device.name, privacy: .public)、\(milliseconds, format: .fixed(precision: 1)) ms）。Metal で描きます"
            )
        case .failure(let error):
            context = nil
            state = .failed
            RenderLog.logger.error("Metal で描けません（\(String(describing: error), privacy: .public)）。Core Text で描きます")
        }
        waiters.forEach { $0(context) }
    }
}
