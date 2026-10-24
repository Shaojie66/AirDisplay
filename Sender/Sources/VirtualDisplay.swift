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

    /// 系统主动移除显示器时回调（比如 WindowServer 重启）。
    var onTerminated: (() -> Void)?

    func start(_ config: Config) throws {
        stop()

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
            Log.info("虚拟显示器被系统终止")
            self?.display = nil
            self?.onTerminated?()
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

        selectHiDPIMode(config, attemptsLeft: 30)
    }

    func stop() {
        guard let id = displayID else { return }
        display = nil   // 释放即移除
        config = nil
        Log.info("虚拟显示器已移除 displayID=\(id)")
    }

    /// 切到 "点 W×H、像素 2W×2H" 的 HiDPI 模式。
    /// 系统登记模式需要主线程 runloop 跑起来，所以用异步重试，不能阻塞等待。
    private func selectHiDPIMode(_ config: Config, attemptsLeft: Int) {
        guard let id = displayID else { return }
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
            self?.selectHiDPIMode(config, attemptsLeft: attemptsLeft - 1)
        }
    }
}
