import Cocoa
import FlutterMacOS

public class MultiWindowManagerPlugin: NSObject, FlutterPlugin {
    public static var RegisterGeneratedPlugins: ((FlutterPluginRegistry) -> Void)?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let _ = MultiWindowManagerPlugin(registrar)
    }

    private var registrar: FlutterPluginRegistrar!

    private var mainWindow: NSWindow {
        return (self.registrar.view?.window)!
    }

    private var _inited: Bool = false
    private var windowManager: MultiWindowManager = MultiWindowManager()
    // Kept alive so hot restart can call ensureInitialized on this channel again
    private var _bootstrapChannel: FlutterMethodChannel?

    public init(_ registrar: FlutterPluginRegistrar) {
        super.init()
        self.registrar = registrar

        windowManager.staticChannel = FlutterMethodChannel(
            name: "multi_window_manager_static",
            binaryMessenger: registrar.messenger
        )
        windowManager.staticChannel?.setMethodCallHandler(staticHandle)

        _bootstrapChannel = FlutterMethodChannel(
            name: "multi_window_manager",
            binaryMessenger: registrar.messenger
        )
        _bootstrapChannel?.setMethodCallHandler(handle)
        windowManager.channel = _bootstrapChannel
    }

    private func ensureInitialized(windowId: Int64, isEnabledReuse: Bool = false) {
        if !_inited {
            windowManager.id = windowId
            windowManager.mainWindow = mainWindow
            windowManager.isReuseEnabled = isEnabledReuse

            // Bootstrap channel keeps its handler so hot restarts can call
            // ensureInitialized again without MissingPluginException.
            let perWindowChannel = FlutterMethodChannel(
                name: "multi_window_manager_\(windowManager.id)",
                binaryMessenger: registrar.messenger
            )
            perWindowChannel.setMethodCallHandler(handle)
            windowManager.channel = perWindowChannel

            MultiWindowManager.windowManagers[windowId] = windowManager
            _inited = true
        }
    }

    public func staticHandle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let methodName: String = call.method
        let args: [String: Any] = call.arguments as? [String: Any] ?? [:]

        switch methodName {
        case "createWindow":
            let encodedArgs = args["args"] as? [String] ?? []
            let windowId = MultiWindowManager.createWindow(args: encodedArgs)
            result(windowId >= 0 ? windowId : nil)

        case "getAllWindowManagerIds":
            let keys = Array<Int64>(MultiWindowManager.windowManagers.keys.filter {
                MultiWindowManager.windowManagers[$0] != nil
            })
            result(keys)

        case "getActiveWindowIds":
            // Returns IDs of windows that are not hidden for reuse.
            // A window is considered active when it is not a hidden reuse-enabled window.
            var activeIds: [Int64] = []
            for (key, value) in MultiWindowManager.windowManagers {
                if let wm = value {
                    let isHidden = wm.isReuseEnabled && !wm.isVisible() && !wm.isBeingReused
                    if !isHidden {
                        activeIds.append(key)
                    }
                }
            }
            result(activeIds)

        case "getHiddenWindowIds":
            // Returns IDs of reuse-enabled windows that are currently invisible
            // and not yet claimed by a concurrent createWindowOrReuse() call.
            var hiddenIds: [Int64] = []
            for (key, value) in MultiWindowManager.windowManagers {
                if let wm = value {
                    if wm.isReuseEnabled && !wm.isVisible() && !wm.isBeingReused {
                        hiddenIds.append(key)
                    }
                }
            }
            result(hiddenIds)

        case "claimWindow":
            // Atomically marks a hidden reuse-enabled window as "being reused" to
            // prevent concurrent callers from claiming the same window.
            // The claim is released in MultiWindowManager.show() when isBeingReused is reset.
            let targetId = windowIdFromArgs(args, key: "windowId")
            if targetId >= 0,
               let optional = MultiWindowManager.windowManagers[targetId],
               let wm = optional,
               wm.isReuseEnabled && !wm.isVisible() && !wm.isBeingReused
            {
                wm.isBeingReused = true
                result(true)
            } else {
                result(false)
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let methodName: String = call.method
        let args: [String: Any] = call.arguments as? [String: Any] ?? [:]
        let windowId = windowIdFromArgs(args, key: "windowId")

        var wManager = windowManager
        if windowId >= 0,
           let optional = MultiWindowManager.windowManagers[windowId],
           let wm = optional
        {
            wManager = wm
        }

        switch methodName {
        case "ensureInitialized":
            if windowId >= 0 {
                let isEnabledReuse = args["isEnabledReuse"] as? Bool ?? false
                ensureInitialized(windowId: windowId, isEnabledReuse: isEnabledReuse)
                result(true)
                windowManager.emitGlobalEvent("initialized")
            } else {
                result(FlutterError(
                    code: "0",
                    message: "Cannot ensureInitialized! windowId >= 0 is required",
                    details: nil
                ))
            }

        case "invokeMethodToWindow":
            let targetId = windowIdFromArgs(args, key: "targetWindowId")
            if let optional = MultiWindowManager.windowManagers[targetId],
               let wm = optional
            {
                wm.channel?.invokeMethod("onEvent", arguments: args["args"]) { value in
                    if value is FlutterError {
                        result(value)
                    } else if (value as? NSObject) == FlutterMethodNotImplemented {
                        result(FlutterMethodNotImplemented)
                    } else {
                        result(value)
                    }
                }
            } else {
                result(FlutterError(
                    code: "0",
                    message: "Cannot invokeMethodToWindow! targetWindowId not found",
                    details: nil
                ))
            }

        case "waitUntilReadyToShow":
            wManager.waitUntilReadyToShow()
            result(true)

        case "setAsFrameless":
            wManager.setAsFrameless()
            result(true)

        case "destroy":
            wManager.destroy()
            result(true)

        case "close":
            wManager.close()
            result(true)

        case "isPreventClose":
            result(wManager.isPreventClose())

        case "setPreventClose":
            wManager.setPreventClose(args)
            result(true)

        case "focus":
            wManager.focus()
            result(true)

        case "blur":
            wManager.blur()
            result(true)

        case "isFocused":
            result(wManager.isFocused())

        case "show":
            wManager.show(args)
            result(true)

        case "hide":
            wManager.hide()
            result(true)

        case "isVisible":
            result(wManager.isVisible())

        case "isMaximized":
            result(wManager.isMaximized())

        case "maximize":
            wManager.maximize()
            result(true)

        case "unmaximize":
            wManager.unmaximize()
            result(true)

        case "isMinimized":
            result(wManager.isMinimized())

        case "isMaximizable":
            result(wManager.isMaximizable())

        case "setMaximizable":
            wManager.setIsMaximizable(args)
            result(true)

        case "minimize":
            wManager.minimize()
            result(true)

        case "restore":
            wManager.restore()
            result(true)

        case "isDockable":
            result(wManager.isDockable())

        case "isDocked":
            result(wManager.isDocked())

        case "dock":
            wManager.dock(args)
            result(true)

        case "undock":
            wManager.undock()
            result(true)

        case "isFullScreen":
            result(wManager.isFullScreen())

        case "setFullScreen":
            wManager.setFullScreen(args)
            result(true)

        case "setAspectRatio":
            wManager.setAspectRatio(args)
            result(true)

        case "setBackgroundColor":
            wManager.setBackgroundColor(args)
            result(true)

        case "getBounds":
            result(wManager.getBounds())

        case "setBounds":
            wManager.setBounds(args)
            result(true)

        case "setMinimumSize":
            wManager.setMinimumSize(args)
            result(true)

        case "setMaximumSize":
            wManager.setMaximumSize(args)
            result(true)

        case "isResizable":
            result(wManager.isResizable())

        case "setResizable":
            wManager.setResizable(args)
            result(true)

        case "isMovable":
            result(wManager.isMovable())

        case "setMovable":
            wManager.setMovable(args)
            result(true)

        case "isMinimizable":
            result(wManager.isMinimizable())

        case "setMinimizable":
            wManager.setMinimizable(args)
            result(true)

        case "isClosable":
            result(wManager.isClosable())

        case "setClosable":
            wManager.setClosable(args)
            result(true)

        case "isAlwaysOnTop":
            result(wManager.isAlwaysOnTop())

        case "setAlwaysOnTop":
            wManager.setAlwaysOnTop(args)
            result(true)

        case "isAlwaysOnBottom":
            result(wManager.isAlwaysOnBottom())

        case "setAlwaysOnBottom":
            wManager.setAlwaysOnBottom(args)
            result(true)

        case "getTitle":
            result(wManager.getTitle())

        case "setTitle":
            wManager.setTitle(args)
            result(true)

        case "setTitleBarStyle":
            wManager.setTitleBarStyle(args)
            result(true)

        case "getTitleBarHeight":
            result(wManager.getTitleBarHeight())

        case "isSkipTaskbar":
            result(wManager.isSkipTaskbar())

        case "setSkipTaskbar":
            wManager.setSkipTaskbar(args)
            result(true)

        case "setBadgeLabel":
            wManager.setBadgeLabel(args)
            result(true)

        case "setProgressBar":
            wManager.setProgressBar(args)
            result(true)

        case "isVisibleOnAllWorkspaces":
            result(wManager.isVisibleOnAllWorkspaces())

        case "setVisibleOnAllWorkspaces":
            wManager.setVisibleOnAllWorkspaces(args)
            result(true)

        case "hasShadow":
            result(wManager.hasShadow())

        case "setHasShadow":
            wManager.setHasShadow(args)
            result(true)

        case "getOpacity":
            result(wManager.getOpacity())

        case "setOpacity":
            wManager.setOpacity(args)
            result(true)

        case "setBrightness":
            wManager.setBrightness(args)
            result(true)

        case "setIgnoreMouseEvents":
            wManager.setIgnoreMouseEvents(args)
            result(true)

        case "setIcon":
            wManager.setIcon(args)
            result(true)

        case "popUpWindowMenu":
            wManager.popUpWindowMenu()
            result(true)

        case "startDragging":
            wManager.startDragging()
            result(true)

        case "startResizing":
            wManager.startResizing(args)
            result(true)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // Extracts an Int64 window ID from a method call argument dictionary.
    // Handles both Int (32-bit Dart ints) and Int64 (large Dart ints) codec values.
    private func windowIdFromArgs(_ args: [String: Any], key: String) -> Int64 {
        if let v = args[key] as? Int64 { return v }
        if let v = args[key] as? Int { return Int64(v) }
        if let v = args[key] as? NSNumber { return v.int64Value }
        return -1
    }

    deinit {
        debugPrint("MultiWindowManagerPlugin dealloc")
    }
}
