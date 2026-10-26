import Foundation

/// 跨主线程、网络队列和编码回调共用。关闭入口与旧代号失效在同一把锁下完成。
// 所有可变状态及输入回调均在 lock 下访问。
final class OperationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var startsAllowed = true
    private var inputAllowed = false
    private var recovering = false
    private var streamIsReady = false

    var ticket: UInt64? { lock.withLock { startsAllowed ? generation : nil } }
    var epoch: UInt64 { lock.withLock { generation } }
    var permitsOrdinaryRestart: Bool { lock.withLock { startsAllowed && !recovering } }
    func isCurrent(_ ticket: UInt64) -> Bool {
        lock.withLock { startsAllowed && ticket == generation }
    }
    func owns(_ ticket: UInt64) -> Bool { lock.withLock { generation == ticket } }

    @discardableResult
    func block(releaseInput: () -> Void) -> UInt64 {
        lock.withLock {
            generation &+= 1
            recovering = true
            startsAllowed = false
            inputAllowed = false
            streamIsReady = false
            // 已进入 input 的回调持有同一锁；这里执行前，它们必然已返回。
            releaseInput()
            return generation
        }
    }

    func allowRecoveryStart(_ ticket: UInt64) -> Bool {
        lock.withLock {
            guard generation == ticket, recovering else { return false }
            startsAllowed = true
            return true
        }
    }

    func streamReady(_ ticket: UInt64) {
        lock.withLock {
            guard generation == ticket, startsAllowed else { return }
            streamIsReady = true
            inputAllowed = !recovering
        }
    }

    func confirm(_ ticket: UInt64) -> Bool {
        lock.withLock {
            guard generation == ticket, startsAllowed, recovering, streamIsReady else { return false }
            recovering = false
            inputAllowed = true
            return true
        }
    }

    func disableInput(release: () -> Void) {
        lock.withLock { inputAllowed = false; streamIsReady = false; release() }
    }

    func reopenAfterManualStop(_ ticket: UInt64) {
        lock.withLock {
            guard generation == ticket else { return }
            startsAllowed = true; recovering = false; inputAllowed = false; streamIsReady = false
        }
    }

    func input(_ body: () -> Void) {
        lock.withLock { if inputAllowed { body() } }
    }
}

/// 等待前一个系统操作真正返回；失败也保留顺序，下一操作可尝试清理。
@MainActor
final class CaptureTransitions {
    private var tail: Task<Void, Error>?
    func enqueue(_ work: @escaping @MainActor () async throws -> Void) -> Task<Void, Error> {
        let previous = tail
        let task = Task { @MainActor in
            _ = await previous?.result
            try await work()
        }
        tail = task
        return task
    }
}

/// 不含硬件身份或个人设备名；可由系统查询或测试替身产生。
struct TopologyDisplay: Equatable {
    var id: UInt32
    var builtin: Bool
    var active: Bool = true
    var main: Bool = false
    var mirrored: Bool = false
    var x: Double = 0
    var y: Double = 0
    var width: Int = 100
    var height: Int = 100
    var pixelWidth: Int = 200
    var pixelHeight: Int = 200
    var refreshRate: Double? = 60
    var geometryFallback = false
}

/// 模式接口不可用时，仅接受来自两个当前查询、坐标和尺寸一致的几何信息。
struct VerifiedDisplayGeometry {
    let x: Double, y: Double, width: Double, height: Double
    let pixelWidth: Double, pixelHeight: Double

    func matches(x: Double, y: Double, width: Double, height: Double,
                 framebufferWidth: Int, framebufferHeight: Int, scale: Double) -> Bool {
        let values = [self.x, self.y, self.width, self.height, pixelWidth, pixelHeight,
                      x, y, width, height, scale]
        guard values.allSatisfy(\.isFinite), width > 0, height > 0, scale > 0,
              pixelWidth > 0, pixelHeight > 0,
              [width, height, pixelWidth, pixelHeight].allSatisfy({ $0.rounded() == $0 && $0 <= Double(Int32.max) }) else { return false }
        return self.x == x && self.y == y && self.width == width && self.height == height &&
            Double(framebufferWidth) == width && Double(framebufferHeight) == height &&
            pixelWidth == width * scale && pixelHeight == height * scale
    }
}

struct TopologySnapshot: Equatable {
    let displays: [TopologyDisplay]
    init(_ displays: [TopologyDisplay]) { self.displays = displays.sorted { $0.id < $1.id } }
    var valid: Bool {
        !displays.isEmpty && Set(displays.map(\.id)).count == displays.count &&
        displays.allSatisfy {
            $0.active && !$0.mirrored && $0.width > 0 && $0.height > 0 &&
            $0.pixelWidth > 0 && $0.pixelHeight > 0 && $0.x.isFinite && $0.y.isFinite &&
            ($0.refreshRate.map { $0.isFinite && $0 >= 0 } ?? $0.geometryFallback) &&
            (!$0.geometryFallback || $0.refreshRate == nil)
        }
    }
}

/// 调用方提供单调时钟；无真实 sleep，也不把无效/空查询当成离线。
struct TopologyStability {
    private var last: TopologySnapshot?
    private var since: TimeInterval = 0
    private var samples = 0
    private var lastEvent: TimeInterval = -.infinity

    mutating func reset() { self = TopologyStability() }

    mutating func observe(_ snapshot: TopologySnapshot?, now: TimeInterval,
                          reconfiguredAt: TimeInterval) -> Bool {
        guard let snapshot, snapshot.valid else { reset(); return false }
        if last != snapshot || lastEvent != reconfiguredAt || now < since {
            last = snapshot; since = now; samples = 0; lastEvent = reconfiguredAt
        }
        samples += 1
        return samples >= 3 && now - since >= 1.5 && now - reconfiguredAt >= 1.5
    }
}

enum RecoveryMethod: Int, CaseIterable {
    case manual, rebuildOnly, automaticSidecar

    var title: String {
        switch self {
        case .manual: return "手动重连 iPad（已验证）"
        case .rebuildOnly: return "仅重建 AirDisplay（实验）"
        case .automaticSidecar: return "自动重连 iPad（实验）"
        }
    }
}

struct RecoveryPolicy {
    enum Phase: Equatable {
        case idle, stopping, waitingOwnRemoval, waitingBuiltin, waitingSidecar, waitingVirtual, waitingStream
        case awaitingConfirmation, paused(String)
    }
    private(set) var phase: Phase = .idle
    private(set) var builtinID: UInt32 = 0
    private(set) var originalDisplayID: UInt32 = 0
    private var sidecarID: UInt32?
    private var virtualID: UInt32?
    private var enteredAt: TimeInterval = 0
    private var stability = TopologyStability()
    private var manual = false
    private var observedOwnRemoval = false
    private(set) var method: RecoveryMethod = .manual
    private(set) var originalSidecarID: UInt32 = 0
    private(set) var canConfirm = false
    private(set) var longUserWait = false
    var isIdle: Bool { phase == .idle }
    var isManualResume: Bool { manual && !isIdle }

    mutating func begin(_ snapshot: TopologySnapshot?, ownedID: UInt32?, now: TimeInterval,
                        method: RecoveryMethod = .manual) -> Bool {
        guard isIdle || { if case .paused = phase { return true }; return false }(),
              let snapshot, snapshot.valid,
              let builtin = snapshot.displays.first(where: { $0.builtin && $0.main }),
              snapshot.displays.filter({ $0.builtin }).count == 1 else { return false }
        if let ownedID {
            guard snapshot.displays.count == 3,
                  snapshot.displays.contains(where: { $0.id == ownedID && !$0.builtin }) else { return false }
        } else {
            // 意外移除后的恢复：必须由界面确认另一块副屏是 iPad。
            guard snapshot.displays.count == 2 else { return false }
        }
        builtinID = builtin.id; originalDisplayID = ownedID ?? 0
        originalSidecarID = snapshot.displays.first(where: { !$0.builtin && $0.id != ownedID })!.id
        self.method = method
        sidecarID = nil; virtualID = nil
        manual = false; canConfirm = false
        move(.stopping, now: now)
        return true
    }

    mutating func stopped(now: TimeInterval) {
        guard phase == .stopping else { return }
        observedOwnRemoval = false
        move(method == .rebuildOnly ? .waitingOwnRemoval : .waitingBuiltin, now: now)
    }

    mutating func retry(ownedID: UInt32? = nil, now: TimeInterval, method: RecoveryMethod = .manual) -> Bool {
        // 自动控制和自身重建必须重新取得当前有效基线，不能靠旧基线猜测目标。
        guard method == .manual, case .paused = phase, builtinID != 0 else { return false }
        self.method = method
        manual = false; sidecarID = nil; virtualID = nil; canConfirm = false
        if let ownedID { originalDisplayID = ownedID }
        move(.stopping, now: now)
        return true
    }

    mutating func resumeManually(now: TimeInterval) {
        manual = true; canConfirm = false
        move(.waitingStream, now: now)
    }

    var hasBaseline: Bool { builtinID != 0 }

    mutating func recordOwnRemoval(_ snapshot: TopologySnapshot) {
        guard phase == .waitingBuiltin, snapshot.valid,
              snapshot.displays.contains(where: { $0.id == builtinID && $0.builtin && $0.main }),
              !snapshot.displays.contains(where: { $0.id == originalDisplayID }) else { return }
        observedOwnRemoval = true
    }

    /// Receiver 换代后，已有勾选和“看过画面”的结论不能用于新流。
    mutating func streamLost(now: TimeInterval) {
        guard phase == .awaitingConfirmation else { return }
        move(.waitingStream, now: now)
    }

    /// 返回 true 只表示允许创建本应用显示器，绝不表示画面已恢复。
    mutating func observe(_ snapshot: TopologySnapshot?, now: TimeInterval,
                          reconfiguredAt: TimeInterval) -> Bool {
        canConfirm = false
        let stable = stability.observe(snapshot, now: now, reconfiguredAt: reconfiguredAt)
        guard let snapshot, snapshot.valid else { return false }
        let ds = snapshot.displays
        switch phase {
        case .waitingOwnRemoval:
            guard ds.count <= 3 else { pause("出现额外显示器，停止自身重建实验", now: now); return false }
            guard ds.contains(where: { $0.id == builtinID && $0.builtin && $0.main }),
                  ds.contains(where: { $0.id == originalSidecarID && !$0.builtin }) else {
                pause("随航已断开或目标发生变化，停止自身重建实验", now: now); return false
            }
            guard !ds.contains(where: { $0.id == originalDisplayID }), ds.count == 2, stable else { return false }
            sidecarID = originalSidecarID
            move(.waitingVirtual, now: now)
            return true
        case .waitingBuiltin:
            recordOwnRemoval(snapshot)
            if ds.contains(where: { $0.id == originalDisplayID }), now - enteredAt >= 10 {
                pause("系统尚未移除原虚拟屏，保持暂停", now: now)
                return false
            }
            guard ds.count == 1, ds[0].id == builtinID, ds[0].builtin, ds[0].main, stable else { return false }
            move(.waitingSidecar, now: now)
        case .waitingSidecar:
            guard ds.count <= 2 else { pause("出现额外显示器，本实验仅支持已知三屏环境", now: now); return false }
            guard ds.count == 2, ds.contains(where: { $0.id == builtinID && $0.builtin && $0.main }),
                  let external = ds.first(where: { !$0.builtin }), stable else { return false }
            sidecarID = external.id
            move(.waitingVirtual, now: now)
            return true
        case .waitingVirtual:
            if ds.count > 3 { pause("出现额外显示器，保持暂停", now: now); return false }
            guard let virtualID, let sidecarID, ds.count == 3,
                  Set(ds.map(\.id)) == Set([builtinID, sidecarID, virtualID]),
                  ds.contains(where: { $0.id == builtinID && $0.builtin && $0.main }), stable else { return false }
            move(.waitingStream, now: now)
        case .waitingStream, .awaitingConfirmation:
            if manual { canConfirm = stable; return false }
            guard let virtualID, let sidecarID, ds.count == 3,
                  Set(ds.map(\.id)) == Set([builtinID, sidecarID, virtualID]),
                  ds.contains(where: { $0.id == builtinID && $0.builtin && $0.main }) else {
                pause("显示器配置已改变，请重新开始恢复", now: now)
                return false
            }
            canConfirm = stable
        default: break
        }
        return false
    }

    mutating func created(_ id: UInt32, now: TimeInterval) {
        guard phase == .waitingVirtual else { return }
        virtualID = id; enteredAt = now; stability.reset()
    }

    mutating func frameDelivered(now: TimeInterval) {
        guard phase == .waitingStream else { return }
        move(.awaitingConfirmation, now: now)
    }

    mutating func confirm() -> Bool {
        guard phase == .awaitingConfirmation, canConfirm else { return false }
        phase = .idle; longUserWait = false; return true
    }

    mutating func pause(_ reason: String, now: TimeInterval) { move(.paused(reason), now: now) }
    mutating func checkDeadline(now: TimeInterval) {
        switch phase {
        case .stopping, .waitingOwnRemoval, .waitingVirtual:
            if now - enteredAt >= 10 { pause("操作超过 10 秒，保持暂停；请检查连接后重试", now: now) }
        case .waitingBuiltin where !observedOwnRemoval && now - enteredAt >= 10:
            pause("无法确认系统已移除原虚拟屏，保持暂停", now: now)
        case .waitingBuiltin, .waitingSidecar:
            if method == .automaticSidecar {
                if now - enteredAt >= 30 { pause("自动随航重连未取得预期的稳定显示状态，请切换手动恢复", now: now) }
            } else { longUserWait = now - enteredAt >= 60 }
        case .awaitingConfirmation:
            // 人工操作不可用短截止时间作废，继续查询但绝不跳过验证或解锁输入。
            longUserWait = now - enteredAt >= 60
        case .waitingStream:
            if now - enteredAt >= 60 { pause("超过 60 秒仍未收到当前 Air 连接的画面，请检查接收端后重试", now: now) }
        default: break
        }
    }
    private mutating func move(_ phase: Phase, now: TimeInterval) {
        self.phase = phase; enteredAt = now; stability.reset(); canConfirm = false; longUserWait = false
    }
}

enum SidecarAction: Hashable { case disconnect, connect }

/// 身份比较在私有适配层内完成，核心状态机不接触设备身份。
enum SidecarPresence { case unknown, absent, matching, other }

struct SidecarReconnectTrigger {
    private enum State { case unarmed, online, offline, consumed }
    private var state: State = .unarmed
    private var builtinID: UInt32?
    private var ownedID: UInt32?
    private var stability = TopologyStability()
    var isArmed: Bool { state == .online || state == .offline }
    var awaitsReconnect: Bool { state == .offline }

    mutating func reset() { self = SidecarReconnectTrigger() }

    /// 初始上线不触发；只消费已观测到稳定离线后的同一目标重新上线。
    mutating func observe(_ snapshot: TopologySnapshot?, presence: SidecarPresence,
                          ownedID: UInt32?, suspended: Bool, now: TimeInterval,
                          reconfiguredAt: TimeInterval) -> Bool {
        guard !suspended else { reset(); return false }
        guard state != .consumed else { return false }
        guard let ownedID else { reset(); return false }
        if let previous = self.ownedID, previous != ownedID { reset() }
        guard presence != .other else { reset(); return false }
        guard let snapshot, snapshot.valid, presence != .unknown else {
            stability.reset(); return false
        }
        let ds = snapshot.displays
        guard ds.count == 2 || ds.count == 3,
              ds.filter({ $0.builtin }).count == 1,
              let builtin = ds.first(where: { $0.builtin && $0.main }),
              ds.contains(where: { $0.id == ownedID && !$0.builtin }) else { reset(); return false }
        if let previous = builtinID, previous != builtin.id { reset() }
        self.ownedID = ownedID; builtinID = builtin.id
        let stable = stability.observe(snapshot, now: now, reconfiguredAt: reconfiguredAt)
        guard stable else { return false }
        if ds.count == 3, presence == .matching {
            if state == .offline {
                state = .consumed
                return true
            }
            state = .online
        } else if ds.count == 2, presence == .absent, state == .online {
            state = .offline
            stability.reset()
        }
        return false
    }
}

enum SidecarControlFailure: LocalizedError {
    case unavailable, ambiguousTarget, incompatible, pending, obsolete, requestFailed, timedOut
    var errorDescription: String? {
        switch self {
        case .unavailable: return "系统随航控制接口不可用，请切换手动恢复"
        case .ambiguousTarget: return "无法确认唯一的已连接 iPad，请切换手动恢复"
        case .incompatible: return "当前系统随航接口签名不兼容，请切换手动恢复"
        case .pending: return "上一次系统随航请求尚未返回，禁止重复自动请求；请保持暂停或使用手动恢复"
        case .obsolete: return "本次自动随航操作已失效"
        case .requestFailed: return "系统拒绝随航请求，请检查 iPad 是否唤醒、解锁并可连接，再使用手动恢复"
        case .timedOut: return "系统随航请求超过 20 秒未返回，已停止自动流程；晚到结果不会恢复推流或输入"
        }
    }
}

/// 测试使用替身；只有 SidecarController 的实现会调用系统。
@MainActor
protocol SidecarTransport: AnyObject {
    func selectConnectedTarget() throws
    func request(_ action: SidecarAction, completion: @escaping @MainActor (Bool) -> Void) throws
}

/// 限定每轮各发一次断开、连接请求。请求无法撤回时，取消只撤销后续动作。
@MainActor
final class SidecarAutomation {
    private struct Pending {
        let id: UInt64
        let action: SidecarAction
        let operation: UInt64
        let startedAt: TimeInterval
        var expired = false
    }
    private let transport: SidecarTransport
    private var pending: Pending?
    private var serial: UInt64 = 0
    private var operation: UInt64?
    private var attempted = Set<SidecarAction>()
    private var completed = Set<SidecarAction>()
    private var isCurrent: (() -> Bool)?
    private var onFailure: ((String) -> Void)?
    var hasUnresolvedRequest: Bool { pending != nil }
    func hasRequested(_ action: SidecarAction) -> Bool { attempted.contains(action) }
    var onAction: ((SidecarAction) -> Void)?

    init(transport: SidecarTransport) { self.transport = transport }

    func start(operation: UInt64, isCurrent: @escaping () -> Bool,
               onFailure: @escaping (String) -> Void) throws {
        guard pending == nil else { throw SidecarControlFailure.pending }
        cancel()
        try transport.selectConnectedTarget()
        self.operation = operation; self.isCurrent = isCurrent; self.onFailure = onFailure
        attempted.removeAll(); completed.removeAll()
    }

    /// true 仅代表 API 请求已完成；调用方仍须独立查询系统拓扑及稳定性。
    func ensure(_ action: SidecarAction, operation: UInt64, now: TimeInterval) throws -> Bool {
        guard self.operation == operation, isCurrent?() == true else { throw SidecarControlFailure.obsolete }
        if completed.contains(action) { return true }
        guard action != .connect || completed.contains(.disconnect) else { throw SidecarControlFailure.obsolete }
        if pending != nil { return false }
        guard !attempted.contains(action) else { throw SidecarControlFailure.requestFailed }
        attempted.insert(action); serial &+= 1
        let id = serial
        pending = Pending(id: id, action: action, operation: operation, startedAt: now)
        onAction?(action)
        do {
            try transport.request(action) { [weak self] success in
                self?.finish(id: id, operation: operation, success: success)
            }
        } catch {
            if pending?.id == id { pending = nil }
            throw error
        }
        return completed.contains(action)
    }

    private func finish(id: UInt64, operation: UInt64, success: Bool) {
        guard let call = pending, call.id == id else { return }
        pending = nil
        guard !call.expired, self.operation == operation, isCurrent?() == true else { return }
        if success { completed.insert(call.action) }
        else {
            let failure = onFailure
            cancel()
            failure?(SidecarControlFailure.requestFailed.localizedDescription)
        }
    }

    func checkDeadline(now: TimeInterval) {
        guard let call = pending, !call.expired, operation == call.operation,
              now - call.startedAt >= 20 else { return }
        pending?.expired = true
        let failure = onFailure
        cancel()
        failure?(SidecarControlFailure.timedOut.localizedDescription)
    }

    func cancel() {
        operation = nil; isCurrent = nil; onFailure = nil
        completed.removeAll(); attempted.removeAll()
        // pending 保留到真实回调返回；超时不能被误认为系统操作已结束。
    }
}

/// 控制面板和菜单使用同一份操作可用性，避免仅禁用 UI 而遗漏控制器检查。
struct RecoveryPresentation: Equatable {
    let phase: RecoveryPolicy.Phase
    let canConfirm: Bool
    let frameID: UInt64?
    let title: String
    let detail: String
    let step: Int
    let busy: Bool
    let canBegin: Bool
    let canCancel: Bool
    let canResumeOnly: Bool
    let manualResume: Bool

    init(policy: RecoveryPolicy, frameID: UInt64?, changingDisplay: Bool = false) {
        self.phase = policy.phase
        self.frameID = frameID
        manualResume = policy.isManualResume
        canConfirm = !changingDisplay && policy.phase == .awaitingConfirmation && policy.canConfirm && frameID != nil
        canBegin = !changingDisplay && (policy.isIdle || { if case .paused = policy.phase { return true }; return false }())
        canCancel = !policy.isIdle && { if case .paused = policy.phase { return false }; return true }()
        canResumeOnly = { if case .paused = policy.phase { return true }; return false }()
        let instruction: String
        switch policy.phase {
        case .idle:
            title = "恢复 iPad 重复画面"
            instruction = "请选择恢复方式。仅重建 AirDisplay 会保持 iPad 在线；自动重连会由软件断开、重新连接唯一的已连接 iPad。两种新方式仍需实验验证，最终均要逐屏确认。"
            step = 0; busy = false
        case .stopping:
            title = "1 · 停止 AirDisplay"
            instruction = "正在停止旧画面连接。此时请不要重新连接随航；准备好后会提示你。"
            step = 1; busy = true
        case .waitingOwnRemoval:
            title = "2 · 等待 AirDisplay 离线"
            instruction = "正在确认旧虚拟屏已经离线、原 iPad 仍在线。请保持随航连接；稳定后会自动重建 AirDisplay。Air 暂时保留旧画面，输入禁用。"
            step = 2; busy = true
        case .waitingBuiltin:
            title = policy.method == .automaticSidecar ? "2 · 自动断开 iPad" : "2 · 断开 iPad 随航"
            instruction = policy.method == .automaticSidecar
                ? "软件正在重置已连接的 iPad 随航。请不要手动切换连接；系统确认只剩内建屏后会自动重连。Air 暂时保留旧画面，输入禁用。"
                : "请在 Pro 的「系统设置 → 显示器」中断开 iPad。等待这里确认只剩 Mac 内建屏，再重新连接。Air 暂停推流，会保留旧画面且不能操作。"
            step = 2; busy = policy.method == .automaticSidecar
        case .waitingSidecar:
            title = policy.method == .automaticSidecar ? "3 · 自动重新连接 iPad" : "3 · 重新连接 iPad"
            instruction = policy.method == .automaticSidecar
                ? "已确认只剩内建屏，正在自动连接同一台 iPad。请保持 iPad 唤醒且已解锁；收到系统稳定上线证据后才会重建 AirDisplay。"
                : "已确认只剩内建屏。现在在 Pro 上重新连接 iPad 随航，并选择「扩展显示屏」。Air 此时仍保留旧画面，等待连接完成后恢复。"
            step = 3; busy = policy.method == .automaticSidecar
        case .waitingVirtual:
            title = "4 · 恢复 AirDisplay"
            instruction = "副屏已重新接入，正在等待 AirDisplay 显示模式稳定。"
            step = 4; busy = true
        case .waitingStream:
            title = "4 · 等待 Air 画面"
            instruction = "请保持 Air 接收端打开。连接后将显示画面核对步骤，远程键鼠暂时禁用。"
            step = 4; busy = true
        case .awaitingConfirmation:
            title = manualResume ? "核对 Mac 和 Air 的画面" : "5 · 逐屏核对动态画面"
            instruction = manualResume
                ? "本次仅恢复 AirDisplay，不确认随航是否恢复。点「显示核对标记」，确认 Mac 和 Air 的编号及动态计数不同，再恢复输入。"
                : "点「显示核对标记」，看三块实际屏幕上的编号、颜色和变化的计数是否各不相同。逐项勾选后再恢复输入；若仍然重复，请报告失败。"
            step = 5; busy = false
        case .paused(let reason):
            title = "恢复已暂停"
            instruction = reason + "。Air 的画面与输入保持暂停，会保留旧画面。请在 Pro 上重试完整流程，或仅恢复 AirDisplay；后者不代表随航问题已解决。"
            step = 0; busy = false
        }
        detail = instruction + (policy.longUserWait ? "\n\n仍在等待你的操作，没有超时退出。完成上述步骤后会继续；也可以取消并保持暂停。" : "")
    }
}

/// 勾选必须属于同一轮恢复、同一条已交付画面的流。
struct RecoveryVerification {
    private(set) var operation: UInt64 = 0
    private(set) var frameID: UInt64?
    private var checked = Set<Int>()
    private var required = Set([0, 1, 2])
    mutating func update(operation: UInt64, frameID: UInt64?, manualResume: Bool = false) {
        let required = manualResume ? Set([0, 2]) : Set([0, 1, 2])
        if self.operation != operation || self.frameID != frameID || self.required != required {
            self.operation = operation; self.frameID = frameID; checked.removeAll()
            self.required = required
        }
    }
    mutating func set(_ index: Int, checked: Bool) {
        guard frameID != nil, required.contains(index) else { return }
        if checked { self.checked.insert(index) } else { self.checked.remove(index) }
    }
    func isChecked(_ index: Int) -> Bool { checked.contains(index) }
    func permitsConfirmation(operation: UInt64, frameID: UInt64?) -> Bool {
        frameID != nil && self.frameID == frameID && self.operation == operation && checked == required
    }
}
