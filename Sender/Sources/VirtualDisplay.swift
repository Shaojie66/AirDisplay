import AppKit
import CoreGraphics

/// 管理一块 CGVirtualDisplay 虚拟显示器。对象释放时显示器会被系统移除。
final class VirtualDisplay {
    struct Config {
        var name: String
        /// 逻辑分辨率（点）。实际像素 = 点 × 2（HiDPI）。
        var pointWidth: UInt32
        var pointHeight: UInt32
        var refreshRate: Double
        /// 物理尺寸，决定系统算出来的 DPI。
        var sizeInMillimeters: CGSize

        var pixelWidth: UInt32 { pointWidth * 2 }
        var pixelHeight: UInt32 { pointHeight * 2 }

        /// 默认：和 15" MacBook Air (2880×1864, 224 ppi) 像素一一对应。
        static let air15 = Config(
            name: "AirDisplay",
            pointWidth: 1440, pointHeight: 932,
            refreshRate: 60,
            sizeInMillimeters: CGSize(width: 327, height: 211)
        )
    }

    enum Failure: LocalizedError {
        case createFailed, applySettingsFailed
        var errorDescription: String? {
            switch self {
            case .createFailed: return "CGVirtualDisplay 创建失败"
            case .applySettingsFailed: return "applySettings 失败"
            }
        }
    }

    private(set) var display: CGVirtualDisplay?
    private(set) var config: Config?
    var displayID: CGDirectDisplayID? { display?.displayID }
    var isRunning: Bool { display != nil }
    private var generation: UInt64 = 0
    var instanceToken: UInt64 { generation }
    private var removalGeneration: UInt64 = 0

    /// 系统主动移除显示器时回调（比如 WindowServer 重启）。
    var onTerminated: (() -> Void)?

    func start(_ config: Config) throws {
        guard !isRunning else { return }
        generation &+= 1
        let ticket = generation
        cancelPendingRemoval()

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = config.name
        descriptor.maxPixelsWide = config.pixelWidth
        descriptor.maxPixelsHigh = config.pixelHeight
        descriptor.sizeInMillimeters = config.sizeInMillimeters
        descriptor.vendorID = 0xADD1
        descriptor.productID = 0x0001
        // 调试：-displaySerial 2 让第二个实例也能建虚拟屏（序列号相同会创建失败）
        let serial = UserDefaults.standard.integer(forKey: "displaySerial")
        descriptor.serialNum = UInt32(serial > 0 ? serial : 1)
        descriptor.terminationHandler = { [weak self] _, _ in
            guard let self, self.generation == ticket else { return }
            Log.info("虚拟显示器被系统终止")
            self.generation &+= 1
            self.cancelPendingRemoval()
            self.display = nil
            self.config = nil
            self.onTerminated?()
        }

        guard let display = CGVirtualDisplay(descriptor: descriptor) else {
            throw Failure.createFailed
        }

        // hiDPI 打开后，每个像素模式 W×H 会额外提供一个 W/2×H/2 @2x 的模式。
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = [
            CGVirtualDisplayMode(width: config.pixelWidth, height: config.pixelHeight, refreshRate: config.refreshRate),
            CGVirtualDisplayMode(width: config.pointWidth, height: config.pointHeight, refreshRate: config.refreshRate),
        ]
        guard display.apply(settings) else {
            throw Failure.applySettingsFailed
        }

        self.display = display
        self.config = config
        Log.info("虚拟显示器已创建 displayID=\(display.displayID)")

        selectHiDPIMode(config, generation: ticket, attemptsLeft: 30)
    }

    // MARK: - 等显示器配置稳定后再移除

    /// 最近一次系统显示器重配置（任意显示器）的时间，由 CG 回调在主线程更新
    private static let reconfigLock = NSLock()
    private static var lastEvent: TimeInterval = 0
    static var lastReconfigAt: TimeInterval { reconfigLock.withLock { lastEvent } }
    private static var watchingReconfig = false

    /// 开始监听系统显示器重配置。主线程调用，重复调用无副作用。
    static func watchReconfiguration() {
        guard !watchingReconfig else { return }
        watchingReconfig = true
        CGDisplayRegisterReconfigurationCallback({ _, _, _ in
            VirtualDisplay.reconfigLock.withLock { VirtualDisplay.lastEvent = ProcessInfo.processInfo.systemUptime }
        }, nil)
    }

    /// 断线后移除虚拟屏用：等系统连续 `quiet` 秒没有显示器重配置再移除，
    /// 避免和系统正在进行的调整（分辨率切换、随航重连、其他屏插拔）撞在一起。
    /// 最多等 `maxWait` 秒；等待期间 `shouldProceed` 返回 false（比如 Air 又连上了）就放弃移除。
    func stopWhenDisplaysSettle(quiet: TimeInterval = 1.5, maxWait: TimeInterval = 10,
                                shouldProceed: @escaping () -> Bool, done: @escaping () -> Void,
                                onTimeout: @escaping () -> Void = {}) {
        cancelPendingRemoval()
        let removal = removalGeneration, instance = generation
        let deadline = ProcessInfo.processInfo.systemUptime + maxWait
        func attempt() {
            guard generation == instance, removalGeneration == removal, isRunning, shouldProceed() else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let sinceReconfig = now - Self.lastReconfigAt
            if sinceReconfig < quiet {
                guard now < deadline else {
                    Log.info("显示器配置未稳定，保留虚拟屏")
                    onTimeout()
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + min(0.25, deadline - now)) { attempt() }
                return
            }
            stop()
            done()
        }
        attempt()
    }

    func cancelPendingRemoval() { removalGeneration &+= 1 }

    func stop() {
        generation &+= 1
        cancelPendingRemoval()
        guard let id = displayID else { return }
        display = nil   // 释放即移除
        config = nil
        Log.info("虚拟显示器已移除 displayID=\(id)")
    }

    /// 切到 "点 W×H、像素 2W×2H" 的 HiDPI 模式。
    /// 系统登记模式需要主线程 runloop 跑起来，所以用异步重试，不能阻塞等待。
    private func selectHiDPIMode(_ config: Config, generation ticket: UInt64, attemptsLeft: Int) {
        guard generation == ticket, let id = displayID else { return }
        let want = "\(config.pointWidth)×\(config.pointHeight) @2x"

        if let cur = CGDisplayCopyDisplayMode(id),
           cur.width == Int(config.pointWidth), cur.pixelWidth == Int(config.pixelWidth) {
            Log.info("已经是目标模式 \(want)")
            return
        }

        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode]) ?? []
        if let mode = modes.first(where: {
            $0.width == Int(config.pointWidth) && $0.pixelWidth == Int(config.pixelWidth)
        }) {
            var cfg: CGDisplayConfigRef?
            CGBeginDisplayConfiguration(&cfg)
            CGConfigureDisplayWithDisplayMode(cfg, id, mode, nil)
            let err = CGCompleteDisplayConfiguration(cfg, .forSession)
            Log.info("切换到 \(want)：\(err == .success ? "成功" : "失败 \(err.rawValue)")")
            return
        }

        guard attemptsLeft > 0 else {
            let list = modes.map { "\($0.width)x\($0.height)(\($0.pixelWidth)x\($0.pixelHeight))" }
            Log.info("没找到目标模式 \(want)，保持系统默认；可用：\(list.joined(separator: ", "))")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.selectHiDPIMode(config, generation: ticket, attemptsLeft: attemptsLeft - 1)
        }
    }
}
