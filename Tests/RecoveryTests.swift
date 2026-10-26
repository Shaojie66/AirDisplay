import Foundation

/// 只运行生产代码中的 gate/状态机，使用可控时钟，不接触显示器或注入真实输入。
@main
@MainActor
enum RecoveryTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
        checks += 1
        guard condition() else { fatalError("FAIL line \(line): \(message)") }
    }

    static let builtin = TopologyDisplay(id: 1, builtin: true, main: true)
    static let owned = TopologyDisplay(id: 8, builtin: false)
    static let sidecar = TopologyDisplay(id: 12, builtin: false, x: 100)
    static var baseline: TopologySnapshot { TopologySnapshot([builtin, owned, sidecar]) }

    static func main() async {
        testGate()
        testConcurrentInput()
        testStability()
        testVerifiedGeometry()
        testRecovery()
        testInvalidTransitions()
        testFailureBoundaries()
        testHumanWaits()
        testRebuildOnly()
        testAutomaticTopology()
        testSidecarAutomation()
        testReconnectTrigger()
        testVerificationEpochs()
        testRecoveryPresentation()
        await testCaptureTransitions()
        print("PASS: \(checks) recovery checks (no device operations)")
    }

    static func testGate() {
        let gate = OperationGate()
        let old = gate.ticket!
        var inputs = 0, releases = 0
        gate.input { inputs += 1 }
        expect(inputs == 0, "input off until a current frame is delivered")
        gate.streamReady(old)
        gate.input { inputs += 1 }
        expect(inputs == 1, "normal stream accepts input after delivery")
        let ticket = gate.block { releases += 1 }
        expect(releases == 1 && gate.ticket == nil && !gate.isCurrent(old), "block and invalidate before stopping")
        for _ in 0..<20 { gate.input { inputs += 1 } }
        gate.streamReady(old)
        expect(inputs == 1 && gate.ticket == nil, "late input and frame cannot unlock")
        expect(!gate.allowRecoveryStart(old), "stale task cannot restart")
        expect(gate.allowRecoveryStart(ticket), "only current recovery may restart")
        expect(!gate.confirm(ticket), "manual confirmation needs a delivered frame")
        gate.streamReady(ticket)
        gate.input { inputs += 1 }
        expect(inputs == 1, "recovered streaming still disables input before confirmation")
        expect(gate.confirm(ticket), "explicit current confirmation unlocks")
        gate.input { inputs += 1 }
        expect(inputs == 2, "input on after confirmation")
        gate.disableInput { releases += 1 }
        gate.input { inputs += 1 }
        expect(inputs == 2 && releases == 2, "disconnect releases and disables")
        let cancelled = gate.block { releases += 1 }
        let newer = gate.block { releases += 1 }
        gate.reopenAfterManualStop(cancelled)
        expect(gate.ticket == nil && !gate.allowRecoveryStart(cancelled), "old manual stop cannot reopen recovery")
        expect(gate.allowRecoveryStart(newer), "new operation remains usable")
    }

    static func testConcurrentInput() {
        let gate = OperationGate()
        gate.streamReady(gate.ticket!)
        let entered = DispatchSemaphore(value: 0), finish = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var order: [String] = []
        DispatchQueue.global().async {
            gate.input {
                lock.withLock { order.append("down") }
                entered.signal()
                finish.wait()
                lock.withLock { order.append("posted") }
            }
            completed.signal()
        }
        expect(entered.wait(timeout: .now() + 2) == .success, "fake input entered")
        DispatchQueue.global().async {
            finish.signal()
        }
        gate.block { lock.withLock { order.append("released") } }
        expect(completed.wait(timeout: .now() + 2) == .success, "fake input drained")
        gate.input { lock.withLock { order.append("unexpected") } }
        expect(lock.withLock { order } == ["down", "posted", "released"], "release occurs after in-flight input; no new input after release")
    }

    static func testStability() {
        let one = TopologySnapshot([builtin])
        var stable = TopologyStability()
        expect(!stable.observe(one, now: 0, reconfiguredAt: 0), "first sample not stable")
        expect(!stable.observe(one, now: 2, reconfiguredAt: 0), "two samples insufficient even after time")
        expect(stable.observe(one, now: 2.25, reconfiguredAt: 0), "three samples and both quiet periods")
        expect(!stable.observe(one, now: 2.5, reconfiguredAt: 2.4), "same geometry but new config event resets")
        expect(!stable.observe(nil, now: 4, reconfiguredAt: 2.4), "query failure resets")
        expect(!stable.observe(one, now: 4.25, reconfiguredAt: 2.4), "cannot inherit stability through failure")
        expect(!stable.observe(TopologySnapshot([]), now: 6, reconfiguredAt: 2.4), "empty is invalid, not all offline")
        var zero = builtin; zero.width = 0
        expect(!TopologySnapshot([zero]).valid, "unreadable mode invalid")
        var inactive = builtin; inactive.active = false
        expect(!TopologySnapshot([inactive]).valid, "inactive invalid")
        var mirror = builtin; mirror.mirrored = true
        expect(!TopologySnapshot([mirror]).valid, "mirror cannot satisfy independent topology")
        expect(!TopologySnapshot([builtin, builtin]).valid, "duplicate ids invalid")
        expect(TopologySnapshot([owned, builtin]) == TopologySnapshot([builtin, owned]), "enumeration order ignored")
    }

    static func observations(_ policy: inout RecoveryPolicy, _ snapshot: TopologySnapshot?, from: Double) -> Bool {
        var create = false
        for i in 0...6 { create = policy.observe(snapshot, now: from + Double(i) * 0.25, reconfiguredAt: from) || create }
        return create
    }

    static func testVerifiedGeometry() {
        let geometry = VerifiedDisplayGeometry(x: -1194, y: 95, width: 1194, height: 834,
                                               pixelWidth: 2388, pixelHeight: 1668)
        func matches(x: Double = -1194, y: Double = 95, width: Double = 1194,
                     framebufferWidth: Int = 1194, scale: Double = 2) -> Bool {
            geometry.matches(x: x, y: y, width: width, height: 834,
                             framebufferWidth: framebufferWidth, framebufferHeight: 834, scale: scale)
        }
        expect(matches(), "current AppKit and CG geometry agree for Sidecar at negative coordinates")
        expect(!matches(x: 1194), "wrong display position rejected")
        expect(!matches(y: 188), "AppKit coordinates must be converted to CG coordinates")
        expect(!matches(width: 1195), "different point dimensions rejected")
        expect(!matches(framebufferWidth: 0), "unreadable live framebuffer rejected")
        expect(!matches(scale: 1), "backing pixels must agree with scale")
        expect(!matches(x: .nan) && !matches(scale: .infinity), "nonfinite readings rejected")
        var fallback = sidecar
        fallback.refreshRate = nil; fallback.geometryFallback = true
        let snapshot = TopologySnapshot([builtin, owned, fallback])
        expect(snapshot.valid, "verified geometry explicitly carries unknown refresh rate")
        var policy = RecoveryPolicy()
        expect(policy.begin(snapshot, ownedID: 8, now: 0), "verified Sidecar geometry permits recovery entry")
        fallback.geometryFallback = false
        expect(!TopologySnapshot([fallback]).valid, "missing mode without verified geometry remains invalid")
        fallback.geometryFallback = true; fallback.refreshRate = 60
        expect(!TopologySnapshot([fallback]).valid, "geometry fallback must not fabricate refresh rate")
        fallback.refreshRate = nil
        var stability = TopologyStability()
        _ = stability.observe(TopologySnapshot([sidecar]), now: 0, reconfiguredAt: 0)
        _ = stability.observe(TopologySnapshot([sidecar]), now: 1, reconfiguredAt: 0)
        expect(!stability.observe(TopologySnapshot([fallback]), now: 2, reconfiguredAt: 0), "changing query source resets stability")
    }

    static func testRecovery() {
        var policy = RecoveryPolicy()
        expect(policy.begin(baseline, ownedID: 8, now: 0), "known three-screen baseline accepted")
        expect(!policy.begin(baseline, ownedID: 8, now: 0.1), "double click ignored")
        expect(!observations(&policy, TopologySnapshot([builtin]), from: 0), "cannot advance while stop pending")
        expect(policy.phase == .stopping, "release object is not removal evidence")
        policy.stopped(now: 2)
        expect(!observations(&policy, TopologySnapshot([builtin, sidecar]), from: 2), "two screens do not prove offline stage")
        expect(policy.phase == .waitingBuiltin, "must observe only built-in")
        expect(!observations(&policy, TopologySnapshot([builtin]), from: 4), "offline stage does not create display")
        expect(policy.phase == .waitingSidecar, "wait for user reconnect")
        // The OS is allowed to reuse a display ID after a real offline interval.
        var reused = sidecar; reused.id = 8
        expect(observations(&policy, TopologySnapshot([builtin, reused]), from: 6), "reused id allowed after observed offline")
        expect(policy.phase == .waitingVirtual, "only grants controlled creation")
        expect(!observations(&policy, baseline, from: 8), "object must be registered before waiting for stream")
        policy.created(20, now: 10)
        var recreated = owned; recreated.id = 20
        let three = TopologySnapshot([builtin, reused, recreated])
        expect(!observations(&policy, three, from: 10), "new screen waits for system topology")
        expect(policy.phase == .waitingStream, "current virtual online and stable")
        expect(!policy.confirm(), "topology does not prove frames")
        policy.frameDelivered(now: 12)
        expect(!policy.confirm(), "confirmation also needs fresh stable topology")
        _ = observations(&policy, three, from: 12)
        expect(policy.phase == .awaitingConfirmation && policy.canConfirm, "frame remains pending human confirmation")
        _ = policy.observe(nil, now: 14, reconfiguredAt: 12)
        expect(!policy.canConfirm && !policy.confirm(), "query failure revokes permission to confirm")
        _ = observations(&policy, three, from: 15)
        expect(policy.confirm() && policy.isIdle, "only human confirmation ends recovery")
    }

    static func testInvalidTransitions() {
        for invalid in [nil, TopologySnapshot([]), TopologySnapshot([builtin, owned]),
                        TopologySnapshot([builtin, owned, sidecar, TopologyDisplay(id: 30, builtin: false)])] {
            var p = RecoveryPolicy()
            expect(!p.begin(invalid, ownedID: 8, now: 0), "invalid or extra display baseline refused")
        }
        var p = RecoveryPolicy()
        _ = p.begin(baseline, ownedID: 8, now: 0)
        p.checkDeadline(now: 10)
        if case .paused = p.phase { expect(true, "stop timeout pauses") } else { expect(false, "timeout must pause") }
        p.stopped(now: 11)
        expect(!observations(&p, TopologySnapshot([builtin]), from: 11), "late stop cannot advance paused operation")
        expect(p.retry(now: 14), "explicit retry retains baseline")
        p.stopped(now: 14)
        _ = observations(&p, TopologySnapshot([builtin]), from: 14)
        expect(!observations(&p, nil, from: 16), "query failure cannot recreate")
        p.checkDeadline(now: 80)
        expect(p.phase == .waitingSidecar && p.longUserWait && !p.canConfirm, "slow user remains waiting without implying success")
        p.resumeManually(now: 81)
        p.frameDelivered(now: 82)
        expect(!p.confirm(), "manual resume does not bypass confirmation")
        _ = observations(&p, baseline, from: 82)
        expect(p.confirm(), "explicit manual picture confirmation available")
    }

    static func testFailureBoundaries() {
        var p = RecoveryPolicy()
        _ = p.begin(baseline, ownedID: 8, now: 0)
        p.stopped(now: 0)
        _ = observations(&p, nil, from: 0)
        p.checkDeadline(now: 10)
        if case .paused = p.phase { expect(true, "cannot verify removal within ten seconds") }
        else { expect(false, "query failure cannot imply system removed display") }
        expect(p.retry(ownedID: 20, now: 11) && p.originalDisplayID == 20, "retry tracks latest owned instance")
        p.stopped(now: 11)
        _ = observations(&p, TopologySnapshot([builtin]), from: 11)
        expect(p.phase == .waitingSidecar, "valid builtin-only stage available on retry")
        _ = observations(&p, baseline, from: 13)
        if case .paused = p.phase { expect(true, "extra screen pauses instead of treating it as Sidecar") }
        else { expect(false, "unknown extra screen must stop automatic progression") }

        let gate = OperationGate()
        let token = gate.block(releaseInput: {})
        expect(!gate.permitsOrdinaryRestart, "settings and ordinary startup blocked at recovery entry")
        expect(gate.allowRecoveryStart(token), "controlled startup allowed")
        expect(!gate.permitsOrdinaryRestart, "ordinary restart remains blocked during recovered streaming")
        gate.streamReady(token)
        expect(gate.confirm(token) && gate.permitsOrdinaryRestart, "ordinary restarts return after human confirmation")
    }

    static func testHumanWaits() {
        var p = RecoveryPolicy()
        _ = p.begin(baseline, ownedID: 8, now: 0)
        p.stopped(now: 0)
        _ = observations(&p, TopologySnapshot([builtin, sidecar]), from: 0)
        p.checkDeadline(now: 180)
        expect(p.phase == .waitingBuiltin && p.longUserWait, "waiting for disconnect survives three minutes after own removal")
        expect(!p.confirm(), "elapsed time cannot confirm a picture")
        var model = RecoveryPresentation(policy: p, frameID: nil)
        expect(model.canCancel && !model.canBegin && model.detail.contains("没有超时退出"), "long wait remains cancellable with visible reminder")
        expect(model.detail.contains("保留旧画面"), "explain paused picture on Air")
        _ = observations(&p, TopologySnapshot([builtin]), from: 181)
        expect(p.phase == .waitingSidecar && !p.longUserWait, "late disconnect still advances and clears reminder")
        p.checkDeadline(now: 400)
        expect(p.phase == .waitingSidecar && p.longUserWait, "waiting for reconnect survives another three minutes")
        expect(!observations(&p, nil, from: 401), "long wait never turns query failure into permission to create")
        expect(observations(&p, TopologySnapshot([builtin, sidecar]), from: 402), "late valid reconnect permits controlled creation")
        p.created(20, now: 404)
        var recreated = owned; recreated.id = 20
        let all = TopologySnapshot([builtin, sidecar, recreated])
        _ = observations(&p, all, from: 404)
        p.frameDelivered(now: 406)
        _ = observations(&p, all, from: 406)
        p.checkDeadline(now: 900)
        model = RecoveryPresentation(policy: p, frameID: 42)
        expect(p.phase == .awaitingConfirmation && p.longUserWait && model.canConfirm, "picture confirmation has no short human deadline")
        expect(p.confirm() && !p.longUserWait, "only explicit confirmation ends long wait")
        expect(!RecoveryPresentation(policy: p, frameID: nil).detail.contains("没有超时退出"), "no stale long-wait notice after confirmation")

        var technical = RecoveryPolicy()
        _ = technical.begin(baseline, ownedID: 8, now: 0)
        technical.stopped(now: 0)
        _ = observations(&technical, TopologySnapshot([builtin]), from: 0)
        _ = observations(&technical, TopologySnapshot([builtin, sidecar]), from: 2)
        technical.created(20, now: 4)
        technical.checkDeadline(now: 14)
        if case .paused = technical.phase { expect(true, "technical virtual creation still times out") }
        else { expect(false, "technical deadline must remain") }
        technical.resumeManually(now: 15)
        technical.checkDeadline(now: 75)
        if case .paused = technical.phase { expect(true, "missing stream still times out") }
        else { expect(false, "stream deadline must remain") }
        p.pause("cancelled", now: 901)
        expect(!p.longUserWait && !p.canConfirm, "explicit cancel always remains available")
    }

    static func testRebuildOnly() {
        var p = RecoveryPolicy()
        expect(p.begin(baseline, ownedID: 8, now: 0, method: .rebuildOnly), "self rebuild takes a valid baseline")
        p.stopped(now: 0)
        expect(p.phase == .waitingOwnRemoval, "self rebuild does not request Sidecar disconnection")
        expect(!observations(&p, baseline, from: 0), "old owned display must actually go offline")
        expect(observations(&p, TopologySnapshot([builtin, sidecar]), from: 2), "same Sidecar remains online while only AirDisplay is rebuilt")
        p.created(20, now: 4)
        var rebuilt = owned; rebuilt.id = 20
        let all = TopologySnapshot([builtin, sidecar, rebuilt])
        _ = observations(&p, all, from: 4)
        p.frameDelivered(now: 6)
        expect(!p.confirm(), "self rebuild still requires current stable topology and human verification")
        _ = observations(&p, all, from: 6)
        expect(p.confirm(), "explicit three-screen confirmation completes self rebuild")

        _ = p.begin(baseline, ownedID: 8, now: 10, method: .rebuildOnly)
        p.stopped(now: 10)
        _ = p.observe(TopologySnapshot([builtin]), now: 11, reconfiguredAt: 10)
        if case .paused = p.phase { expect(true, "self rebuild aborts if Sidecar disappears") }
        else { expect(false, "self rebuild cannot silently become full recovery") }
        expect(!p.retry(now: 12, method: .rebuildOnly), "self rebuild cannot reuse stale baseline on retry")
        expect(!p.retry(now: 12, method: .automaticSidecar), "automatic Sidecar target needs a current baseline")
    }

    static func testAutomaticTopology() {
        var p = RecoveryPolicy()
        expect(p.begin(baseline, ownedID: 8, now: 0, method: .automaticSidecar), "automatic mode takes same strict baseline")
        p.stopped(now: 0)
        p.recordOwnRemoval(TopologySnapshot([builtin, sidecar]))
        p.checkDeadline(now: 11)
        expect(p.phase == .waitingBuiltin, "verified own removal permits waiting for system disconnection callback")
        expect(!observations(&p, TopologySnapshot([builtin, sidecar]), from: 12), "successful API reply alone is not an offline snapshot")
        expect(p.phase == .waitingBuiltin, "must still observe builtin-only stage")
        _ = observations(&p, TopologySnapshot([builtin]), from: 14)
        expect(p.phase == .waitingSidecar, "automatic mode observes all-offline evidence")
        let presentation = RecoveryPresentation(policy: p, frameID: nil)
        expect(presentation.busy && presentation.title.contains("自动"), "automatic guide does not ask user to reconnect manually")
        p.checkDeadline(now: 46)
        if case .paused = p.phase { expect(true, "automatic reconnection has a technical deadline") }
        else { expect(false, "automatic mode cannot wait forever for private API effect") }
    }

    @MainActor final class FakeSidecar: SidecarTransport {
        var selections = 0
        var requests: [SidecarAction] = []
        var replies: [@MainActor (Bool) -> Void] = []
        var selectionError: Error?
        var requestError: Error?
        func selectConnectedTarget() throws {
            selections += 1
            if let selectionError { throw selectionError }
        }
        func request(_ action: SidecarAction, completion: @escaping @MainActor (Bool) -> Void) throws {
            if let requestError { throw requestError }
            requests.append(action); replies.append(completion)
        }
    }

    static func testSidecarAutomation() {
        let fake = FakeSidecar()
        let a = SidecarAutomation(transport: fake)
        var current = true, failures: [String] = []
        do {
            try a.start(operation: 1, isCurrent: { current }, onFailure: { failures.append($0) })
            do { _ = try a.ensure(.connect, operation: 1, now: 0); expect(false, "cannot connect before disconnect") }
            catch { expect(fake.requests.isEmpty, "invalid order sends no system request") }
            var ready = try a.ensure(.disconnect, operation: 1, now: 0)
            expect(!ready, "disconnect waits for system completion")
            ready = try a.ensure(.disconnect, operation: 1, now: 1)
            expect(!ready, "polling cannot duplicate disconnect")
            expect(fake.requests == [.disconnect], "only one disconnect per operation")
            fake.replies[0](true)
            expect(fake.requests == [.disconnect], "completion alone cannot automatically launch next action")
            ready = try a.ensure(.disconnect, operation: 1, now: 2)
            expect(ready, "confirmed callback resolves disconnect command")
            ready = try a.ensure(.connect, operation: 1, now: 3)
            expect(!ready, "connect is separately issued after topology stage")
            fake.replies[0](false)
            expect(a.hasUnresolvedRequest && failures.isEmpty, "duplicate old callback cannot disturb new request")
            fake.replies[1](true)
            ready = try a.ensure(.connect, operation: 1, now: 4)
            expect(ready, "connect command completes once")
            expect(fake.requests == [.disconnect, .connect], "bounded request sequence")

            try a.start(operation: 2, isCurrent: { current }, onFailure: { failures.append($0) })
            _ = try a.ensure(.disconnect, operation: 2, now: 10)
            a.cancel()
            expect(a.hasUnresolvedRequest, "cancel cannot pretend pending system mutation has ended")
            do { try a.start(operation: 3, isCurrent: { true }, onFailure: { _ in }); expect(false, "overlapping automation forbidden") }
            catch { expect(true, "new automation blocked while old request unresolved") }
            fake.replies[2](true)
            expect(!a.hasUnresolvedRequest && failures.isEmpty, "late cancelled completion only releases pending state")
            do { _ = try a.ensure(.connect, operation: 2, now: 11); expect(false, "cancelled operation cannot connect") }
            catch { expect(fake.requests.count == 3, "cancelled callback cannot enqueue reconnect") }

            try a.start(operation: 3, isCurrent: { current }, onFailure: { failures.append($0) })
            _ = try a.ensure(.disconnect, operation: 3, now: 20)
            a.checkDeadline(now: 40)
            a.checkDeadline(now: 41)
            expect(failures.count == 1 && a.hasUnresolvedRequest, "timeout reports once and preserves unresolved system request")
            do { try a.start(operation: 4, isCurrent: { true }, onFailure: { _ in }); expect(false, "timeout cannot permit overlapping retry") }
            catch { expect(true, "timed-out request blocks retries until real return") }
            fake.replies[3](true)
            expect(!a.hasUnresolvedRequest && failures.count == 1, "late success after timeout cannot revive workflow")

            try a.start(operation: 4, isCurrent: { current }, onFailure: { failures.append($0) })
            _ = try a.ensure(.disconnect, operation: 4, now: 50)
            current = false
            fake.replies[4](false)
            expect(!a.hasUnresolvedRequest && failures.count == 1, "obsolete errors cannot pause a newer operation")
            do { _ = try a.ensure(.connect, operation: 4, now: 51); expect(false, "obsolete operation cannot act") }
            catch { expect(fake.requests.count == 5, "epoch invalidation prevents new system calls") }
        } catch { expect(false, "unexpected automation error: \(error)") }

        let unavailable = FakeSidecar()
        unavailable.selectionError = SidecarControlFailure.ambiguousTarget
        let failed = SidecarAutomation(transport: unavailable)
        do { try failed.start(operation: 1, isCurrent: { true }, onFailure: { _ in }); expect(false, "ambiguous target refused") }
        catch { expect(unavailable.requests.isEmpty, "unknown target never causes disconnection") }

        let rejectedTransport = FakeSidecar()
        let rejected = SidecarAutomation(transport: rejectedTransport)
        var rejectedCount = 0
        do {
            try rejected.start(operation: 1, isCurrent: { true }, onFailure: { _ in rejectedCount += 1 })
            _ = try rejected.ensure(.disconnect, operation: 1, now: 0)
            rejectedTransport.replies[0](false)
            rejectedTransport.replies[0](false)
            expect(rejectedCount == 1 && !rejected.hasUnresolvedRequest, "system rejection reports failure exactly once")
            do { _ = try rejected.ensure(.connect, operation: 1, now: 1); expect(false, "rejection cannot lead to connect") }
            catch { expect(rejectedTransport.requests == [.disconnect], "rejected disconnect never causes reconnect") }
        } catch { expect(false, "unexpected rejection-test setup failure") }

        let throwingTransport = FakeSidecar()
        throwingTransport.requestError = SidecarControlFailure.incompatible
        let throwing = SidecarAutomation(transport: throwingTransport)
        do {
            try throwing.start(operation: 1, isCurrent: { true }, onFailure: { _ in })
            do { _ = try throwing.ensure(.disconnect, operation: 1, now: 0); expect(false, "incompatible request must throw") }
            catch { expect(!throwing.hasUnresolvedRequest && throwingTransport.requests.isEmpty, "failure before invocation leaves no phantom pending request") }
        } catch { expect(false, "unexpected throwing-test setup failure") }
    }

    static func testReconnectTrigger() {
        let two = TopologySnapshot([builtin, owned])
        var t = SidecarReconnectTrigger()
        func samples(_ tracker: inout SidecarReconnectTrigger, _ snapshot: TopologySnapshot?,
                     _ presence: SidecarPresence, from: Double, ownedID: UInt32? = 8,
                     suspended: Bool = false) -> Int {
            var fires = 0
            for i in 0...6 {
                if tracker.observe(snapshot, presence: presence, ownedID: ownedID, suspended: suspended,
                                   now: from + Double(i) * 0.25, reconfiguredAt: from) { fires += 1 }
            }
            return fires
        }
        expect(samples(&t, baseline, .matching, from: 0) == 0 && t.isArmed, "startup with three displays only establishes a baseline")
        var moved = sidecar; moved.x = -100
        expect(samples(&t, TopologySnapshot([builtin, owned, moved]), .matching, from: 2) == 0, "layout changes cannot trigger a reset")
        expect(samples(&t, two, .unknown, from: 4) == 0 && !t.awaitsReconnect, "unknown Sidecar status is not disconnection evidence")
        expect(samples(&t, two, .absent, from: 6) == 0 && t.awaitsReconnect, "stable CG and Sidecar disconnection evidence arms one reconnect")
        expect(samples(&t, nil, .matching, from: 8) == 0, "query failures never trigger")
        expect(samples(&t, baseline, .matching, from: 10) == 1, "verified reconnect triggers once, including reused display ID")
        expect(samples(&t, baseline, .matching, from: 12) == 0, "same event cannot fire again")
        _ = samples(&t, two, .absent, from: 14)
        expect(samples(&t, baseline, .matching, from: 16) == 0, "consumed trigger stays blocked until explicit rearm")

        t.reset()
        _ = samples(&t, baseline, .matching, from: 18)
        _ = samples(&t, two, .absent, from: 20, suspended: true)
        expect(samples(&t, baseline, .matching, from: 22, suspended: true) == 0, "own recovery events are suppressed")
        expect(samples(&t, baseline, .matching, from: 24) == 0 && t.isArmed, "completion rearms using a new baseline rather than a fake reconnect")
        _ = samples(&t, two, .absent, from: 26)
        expect(samples(&t, baseline, .other, from: 28) == 0 && !t.isArmed, "a different target can never trigger recovery")
        expect(samples(&t, baseline, .matching, from: 30) == 0, "returning known target after mismatch establishes new baseline")

        _ = samples(&t, two, .absent, from: 32)
        var newOwned = owned; newOwned.id = 99
        expect(samples(&t, TopologySnapshot([builtin, newOwned, sidecar]), .matching, from: 34, ownedID: 99) == 0, "Receiver-driven virtual screen replacement invalidates the old event")
        expect(samples(&t, baseline, .matching, from: 36, ownedID: nil) == 0 && !t.isArmed, "no owned virtual display means no automatic reset")
        _ = samples(&t, baseline, .matching, from: 38)
        let extra = TopologySnapshot([builtin, owned, sidecar, TopologyDisplay(id: 88, builtin: false)])
        expect(samples(&t, extra, .matching, from: 40) == 0 && !t.isArmed, "extra display disarms tracking")
        expect(samples(&t, baseline, .matching, from: 42) == 0, "removing unrelated display cannot become a Sidecar reconnect")
        _ = samples(&t, two, .absent, from: 44)
        expect(!t.observe(baseline, presence: .matching, ownedID: 8, suspended: false, now: 46, reconfiguredAt: 46), "first reconnect snapshot cannot fire")
        expect(!t.observe(baseline, presence: .matching, ownedID: 8, suspended: false, now: 48, reconfiguredAt: 47.9), "fresh config event resets stability even after elapsed time")
        expect(samples(&t, baseline, .matching, from: 50) == 1, "only a fresh quiet window completes reconnect")
    }

    static func testCaptureTransitions() async {
        let queue = CaptureTransitions()
        let gate = OperationGate()
        let ticket = gate.ticket!
        var events: [String] = []
        var finishStart: CheckedContinuation<Void, Never>?
        let start = queue.enqueue {
            events.append("starting")
            await withCheckedContinuation { finishStart = $0 }
            if gate.isCurrent(ticket) { events.append("unexpected publish") }
            events.append("start returned")
        }
        for _ in 0..<1000 {
            if finishStart != nil { break }
            await Task.yield()
        }
        expect(finishStart != nil, "controlled fake capture start entered")
        gate.block(releaseInput: {})
        let stop = queue.enqueue { events.append("stopped") }
        await Task.yield()
        expect(events == ["starting"], "stop waits for an in-flight start")
        finishStart?.resume()
        do { try await start.value; try await stop.value }
        catch { expect(false, "fake lifecycle must complete") }
        expect(events == ["starting", "start returned", "stopped"], "late start cannot publish; stop completes afterwards")
        enum FakeFailure: Error { case failed }
        let failedStop = queue.enqueue { throw FakeFailure.failed }
        _ = await failedStop.result
        let retry = queue.enqueue { events.append("retry cleanup") }
        do { try await retry.value } catch { expect(false, "cleanup retry should run") }
        expect(events.last == "retry cleanup", "failed system operation does not prevent cleanup retry")
    }

    static func testVerificationEpochs() {
        var verification = RecoveryVerification()
        verification.set(0, checked: true)
        expect(!verification.permitsConfirmation(operation: 0, frameID: nil), "no frame means no visual confirmation")
        verification.update(operation: 1, frameID: 42)
        for index in 0..<3 { verification.set(index, checked: true) }
        expect(verification.permitsConfirmation(operation: 1, frameID: 42), "three checks belong to current frame")
        verification.update(operation: 1, frameID: 42)
        expect(verification.permitsConfirmation(operation: 1, frameID: 42), "polling the same frame retains checks")
        verification.update(operation: 1, frameID: 43)
        expect(!verification.permitsConfirmation(operation: 1, frameID: 43), "new connection invalidates all old checks")
        expect(!verification.isChecked(0) && !verification.isChecked(1) && !verification.isChecked(2), "every check resets")
        for index in 0..<3 { verification.set(index, checked: true) }
        verification.update(operation: 2, frameID: 43)
        expect(!verification.permitsConfirmation(operation: 2, frameID: 43), "new recovery invalidates same-stream checks")
        verification.update(operation: 2, frameID: 43, manualResume: true)
        verification.set(0, checked: true); verification.set(2, checked: true)
        expect(verification.permitsConfirmation(operation: 2, frameID: 43), "AirDisplay-only restoration needs Mac and Air, not an absent iPad")
        verification.update(operation: 2, frameID: 43, manualResume: false)
        expect(!verification.permitsConfirmation(operation: 2, frameID: 43), "manual confirmation cannot become full Sidecar confirmation")
        verification.update(operation: 2, frameID: nil)
        verification.set(0, checked: true)
        expect(!verification.isChecked(0), "disconnected state cannot collect checks")
    }

    static func testRecoveryPresentation() {
        var policy = RecoveryPolicy()
        var model = RecoveryPresentation(policy: policy, frameID: nil)
        expect(model.canBegin && !model.canConfirm && !model.canResumeOnly, "idle offers start but no completion")
        expect(!RecoveryPresentation(policy: policy, frameID: nil, changingDisplay: true).canBegin, "normal stop also blocks recovery start")
        expect(policy.begin(TopologySnapshot([builtin, sidecar]), ownedID: nil, now: 0), "unexpected virtual-display loss can still enter recovery")
        model = RecoveryPresentation(policy: policy, frameID: nil)
        expect(model.busy && model.canCancel && !model.canBegin, "stop stage offers cancel and cannot restart")
        policy.stopped(now: 0)
        _ = observations(&policy, TopologySnapshot([builtin]), from: 1)
        model = RecoveryPresentation(policy: policy, frameID: nil)
        expect(model.step == 3 && !model.canConfirm, "reconnect instruction follows observed builtin-only stage")
        _ = observations(&policy, TopologySnapshot([builtin, sidecar]), from: 3)
        policy.created(20, now: 5)
        var owned = self.owned; owned.id = 20
        let all = TopologySnapshot([builtin, sidecar, owned])
        _ = observations(&policy, all, from: 5)
        policy.frameDelivered(now: 7)
        _ = observations(&policy, all, from: 7)
        expect(RecoveryPresentation(policy: policy, frameID: 42).canConfirm, "only a stable delivered frame offers confirmation")
        expect(!RecoveryPresentation(policy: policy, frameID: nil).canConfirm, "lost connection immediately disables confirm")
        policy.streamLost(now: 9)
        expect(policy.phase == .waitingStream && !policy.confirm(), "stream loss requires a fresh frame and another human check")
        policy.pause("cancelled", now: 10)
        model = RecoveryPresentation(policy: policy, frameID: 42)
        expect(model.canBegin && model.canResumeOnly && !model.canConfirm && !model.canCancel, "paused has explicit retry/restore choices, no success")
        var nanMode = builtin; nanMode.refreshRate = .nan
        expect(!TopologySnapshot([nanMode]).valid, "nonfinite mode cannot count as stable")
    }
}
