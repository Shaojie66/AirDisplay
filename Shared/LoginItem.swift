import Foundation
import ServiceManagement

/// "登录时自动打开"。默认关，由用户在界面上打开。
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// 返回操作后的状态
    @discardableResult
    static func set(_ on: Bool) -> Bool {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            Log.info("登录时自动打开：\(on ? "开" : "关")")
        } catch {
            Log.info("设置登录项失败：\(error.localizedDescription)")
        }
        return isEnabled
    }
}
