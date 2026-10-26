import Foundation
import ObjectiveC
import Darwin

/// SidecarCore 适配层。私有入口参考 SidecarLauncher，许可见 THIRD_PARTY_NOTICES.md。
/// 不保存设备名称或标识，不启动外部命令；唯一目标在本轮开始时绑定。
@MainActor
final class SidecarController: SidecarTransport {
    private static let library = dlopen("/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore", RTLD_LAZY)
    private var manager: NSObject?
    private var target: NSObject?
    private var watchedIdentity: NSObject?
    var requiresWatchedTarget = false
    var hasWatchedTarget: Bool { watchedIdentity != nil }

    private func identity(of device: NSObject) throws -> NSObject {
        _ = try checkedMethod(type(of: device), "identifier", returns: "@", arguments: [])
        let value = device.perform(NSSelectorFromString("identifier"))?.takeUnretainedValue()
        guard let identity = value as? NSObject,
              identity is NSUUID || ((identity as? NSString)?.length ?? 0) > 0 else {
            throw SidecarControlFailure.ambiguousTarget
        }
        return identity
    }

    private func connectedTargets(_ manager: NSObject) throws -> [NSObject] {
        _ = try checkedMethod(type(of: manager), "connectedDevices", returns: "@", arguments: [])
        let raw = manager.perform(NSSelectorFromString("connectedDevices"))?.takeUnretainedValue()
        if let array = raw as? [NSObject] { return array }
        if let set = raw as? NSSet, let array = set.allObjects as? [NSObject] { return array }
        throw SidecarControlFailure.ambiguousTarget
    }

    /// 身份仅在内存中比较；不返回身份值给调用方，不持久化。
    func bindEventTarget() throws {
        try selectConnectedTarget()
        guard let target else { throw SidecarControlFailure.ambiguousTarget }
        watchedIdentity = try identity(of: target)
    }

    func clearEventTarget() { watchedIdentity = nil }

    func eventPresence() -> SidecarPresence {
        guard let manager, let watchedIdentity else { return .unknown }
        do {
            let devices = try connectedTargets(manager)
            if devices.isEmpty { return .absent }
            guard devices.count == 1 else { return .other }
            return watchedIdentity.isEqual(try identity(of: devices[0])) ? .matching : .other
        } catch { return .unknown }
    }

    private func checkedMethod(_ cls: AnyClass, _ name: String,
                               returns: String, arguments: [String]) throws -> Method {
        guard let method = class_getInstanceMethod(cls, NSSelectorFromString(name)),
              method_getNumberOfArguments(method) == arguments.count + 2 else { throw SidecarControlFailure.incompatible }
        let result = method_copyReturnType(method)
        defer { free(result) }
        guard String(cString: result) == returns else { throw SidecarControlFailure.incompatible }
        for (index, expected) in arguments.enumerated() {
            guard let type = method_copyArgumentType(method, UInt32(index + 2)) else {
                throw SidecarControlFailure.incompatible
            }
            let value = String(cString: type)
            free(type)
            guard value == expected else { throw SidecarControlFailure.incompatible }
        }
        return method
    }

    func selectConnectedTarget() throws {
        manager = nil; target = nil
        guard Self.library != nil,
              let cls = NSClassFromString("SidecarDisplayManager") as? NSObject.Type,
              let shared = class_getClassMethod(cls, NSSelectorFromString("sharedManager")),
              method_getNumberOfArguments(shared) == 2 else { throw SidecarControlFailure.unavailable }
        let returnType = method_copyReturnType(shared)
        defer { free(returnType) }
        guard String(cString: returnType) == "@" else { throw SidecarControlFailure.incompatible }
        let instance = cls.perform(NSSelectorFromString("sharedManager"))?.takeUnretainedValue()
        guard let manager = instance as? NSObject else { throw SidecarControlFailure.unavailable }
        _ = try checkedMethod(cls, "connectedDevices", returns: "@", arguments: [])
        _ = try checkedMethod(cls, "connectToDevice:completion:", returns: "v", arguments: ["@", "@?"])
        _ = try checkedMethod(cls, "disconnectFromDevice:completion:", returns: "v", arguments: ["@", "@?"])
        let targets = try connectedTargets(manager)
        guard targets.count == 1 else { throw SidecarControlFailure.ambiguousTarget }
        if requiresWatchedTarget {
            guard let watchedIdentity, watchedIdentity.isEqual(try identity(of: targets[0])) else {
                throw SidecarControlFailure.ambiguousTarget
            }
        }
        self.manager = manager; target = targets[0]
    }

    func request(_ action: SidecarAction, completion: @escaping @MainActor (Bool) -> Void) throws {
        guard let manager, let target else { throw SidecarControlFailure.ambiguousTarget }
        let name = action == .disconnect ? "disconnectFromDevice:completion:" : "connectToDevice:completion:"
        let method = try checkedMethod(type(of: manager), name, returns: "v", arguments: ["@", "@?"])
        typealias Request = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Void
        let invoke = unsafeBitCast(method_getImplementation(method), to: Request.self)
        let callback: @convention(block) (NSError?) -> Void = { error in
            let success = error == nil
            Task { @MainActor in completion(success) }
        }
        invoke(manager, NSSelectorFromString(name), target, callback as AnyObject)
    }
}
