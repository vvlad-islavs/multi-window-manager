import Cocoa
import FlutterMacOS

public class WindowManagerPlusPlugin: NSObject, FlutterPlugin {
    public static var RegisterGeneratedPlugins:((FlutterPluginRegistry) -> Void)?
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let _ = WindowManagerPlusPlugin(registrar)
    }
    
    private var registrar: FlutterPluginRegistrar!;
    
    private var mainWindow: NSWindow {
        get {
            return (self.registrar.view?.window)!;
        }
    }
    
    private var _inited: Bool = false
    private var windowManager: WindowManagerPlus = WindowManagerPlus()
    // Kept alive so hot restart can call ensureInitialized on this channel again
    private var _bootstrapChannel: FlutterMethodChannel?
    
    public init(_ registrar: FlutterPluginRegistrar) {
        super.init()
        self.registrar = registrar
        
        windowManager.staticChannel = FlutterMethodChannel(name: "window_manager_plus_static", binaryMessenger: registrar.messenger)
        windowManager.staticChannel?.setMethodCallHandler(staticHandle)
        
        _bootstrapChannel = FlutterMethodChannel(name: "window_manager_plus", binaryMessenger: registrar.messenger)
        _bootstrapChannel?.setMethodCallHandler(handle)
        windowManager.channel = _bootstrapChannel
    }
    
    private func ensureInitialized(windowId: Int64) {
        if (!_inited) {
            windowManager.id = windowId;
            windowManager.mainWindow = mainWindow
            
            // The bootstrap channel (_bootstrapChannel) keeps its handler so that
            // hot restarts can call ensureInitialized again without MissingPluginException.
            let perWindowChannel = FlutterMethodChannel(name: "window_manager_plus_\(windowManager.id)", binaryMessenger: registrar.messenger)
            perWindowChannel.setMethodCallHandler(handle)
            windowManager.channel = perWindowChannel
            
            WindowManagerPlus.windowManagers[windowId] = windowManager
            _inited = true
        }
    }
    
    public func staticHandle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let methodName: String = call.method
        let args: [String: Any] = call.arguments as? [String: Any] ?? [:]
        
        switch (methodName) {
        case "createWindow":
            let encodedArgs = args["args"] as? [String] ?? []
            let windowId = WindowManagerPlus.createWindow(args: encodedArgs)
            result(windowId >= 0 ? windowId : nil)
            break
        case "getAllWindowManagerIds":
            let keys = Array<Int64>(WindowManagerPlus.windowManagers.keys.filter { key in
                return WindowManagerPlus.windowManagers[key] != nil
            })
            result(keys)
            break
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let methodName: String = call.method
        let args: [String: Any] = call.arguments as? [String: Any] ?? [:]
        let windowId = args["windowId"] as? Int64 ?? -1;
        
        var wManager = windowManager
        if windowId >= 0, let wm = WindowManagerPlus.windowManagers[windowId], let wm2 = wm {
            wManager = wm2
        }
        
        switch (methodName) {
        case "ensureInitialized":
            if (windowId >= 0) {
                ensureInitialized(windowId: windowId)
                result(true)
                windowManager.emitGlobalEvent("initialized")
            } else {
                result(FlutterError(code: "0", message: "Cannot ensureInitialized! windowId >= 0 is required", details: nil))
            }
            break
        case "invokeMethodToWindow":
            if let targetWindowId = args["targetWindowId"] as? Int64, let wm = WindowManagerPlus.windowManagers[targetWindowId], let wm2 = wm {
                wm2.channel?.invokeMethod("onEvent", arguments: args["args"]) {(value) -> Void in
                    if value is FlutterError {
                        result(value)
                    }
                    else if (value as? NSObject) == FlutterMethodNotImplemented {
                        result(FlutterMethodNotImplemented)
                    }
                    else {
                        result(value)
                    }
                }
            } else {
                result(FlutterError(code: "0", message: "Cannot invokeMethodToWindow! targetWindowId not found", details: nil))
            }
            break
        case "waitUntilReadyToShow":
            wManager.waitUntilReadyToShow()
            result(true)
            break
        case "setAsFrameless":
            wManager.setAsFrameless()
            result(true)
            break
        case "destroy":
            wManager.destroy()
            result(true)
            break
        case "close":
            wManager.close()
            result(true)
            break
        case "isPreventClose":
            result(wManager.isPreventClose())
            break
        case "setPreventClose":
            wManager.setPreventClose(args)
            result(true)
            break
        case "focus":
            wManager.focus()
            result(true)
            break
        case "blur":
            wManager.blur()
            result(true)
            break
        case "isFocused":
            result(wManager.isFocused())
            break
        case "show":
            wManager.show()
            result(true)
            break
        case "hide":
            wManager.hide()
            result(true)
            break
        case "isVisible":
            result(wManager.isVisible())
            break
        case "isMaximized":
            result(wManager.isMaximized())
            break
        case "maximize":
            wManager.maximize()
            result(true)
            break
        case "unmaximize":
            wManager.unmaximize()
            result(true)
            break
        case "isMinimized":
            result(wManager.isMinimized())
            break
        case "isMaximizable":
            result(wManager.isMaximizable())
            break
        case "setMaximizable":
            wManager.setIsMaximizable(args)
            result(true)
            break
        case "minimize":
            wManager.minimize()
            result(true)
            break
        case "restore":
            wManager.restore()
            result(true)
            break
        case "isDockable":
            result(wManager.isDockable())
            break
        case "isDocked":
            result(wManager.isDocked())
            break
        case "dock":
            wManager.dock(args)
            result(true)
            break
        case "undock":
            wManager.undock()
            result(true)
            break
        case "isFullScreen":
            result(wManager.isFullScreen())
            break
        case "setFullScreen":
            wManager.setFullScreen(args)
            result(true)
            break
        case "setAspectRatio":
            wManager.setAspectRatio(args)
            result(true)
            break
        case "setBackgroundColor":
            wManager.setBackgroundColor(args)
            result(true)
            break
        case "getBounds":
            result(wManager.getBounds())
            break
        case "setBounds":
            wManager.setBounds(args)
            result(true)
            break
        case "setMinimumSize":
            wManager.setMinimumSize(args)
            result(true)
            break
        case "setMaximumSize":
            wManager.setMaximumSize(args)
            result(true)
            break
        case "isResizable":
            result(wManager.isResizable())
            break
        case "setResizable":
            wManager.setResizable(args)
            result(true)
            break
        case "isMovable":
            result(wManager.isMovable())
            break
        case "setMovable":
            wManager.setMovable(args)
            result(true)
            break
        case "isMinimizable":
            result(wManager.isMinimizable())
            break
        case "setMinimizable":
            wManager.setMinimizable(args)
            result(true)
            break
        case "isClosable":
            result(wManager.isClosable())
            break
        case "setClosable":
            wManager.setClosable(args)
            result(true)
            break
        case "isAlwaysOnTop":
            result(wManager.isAlwaysOnTop())
            break
        case "setAlwaysOnTop":
            wManager.setAlwaysOnTop(args)
            result(true)
            break
        case "getTitle":
            result(wManager.getTitle())
            break
        case "setTitle":
            wManager.setTitle(args)
            result(true)
            break
        case "setTitleBarStyle":
            wManager.setTitleBarStyle(args)
            result(true)
            break
        case "getTitleBarHeight":
            result(wManager.getTitleBarHeight())
            break
        case "isSkipTaskbar":
            result(wManager.isSkipTaskbar())
            break
        case "setSkipTaskbar":
            wManager.setSkipTaskbar(args)
            result(true)
            break
        case "setBadgeLabel":
            wManager.setBadgeLabel(args)
            result(true)
            break
        case "setProgressBar":
            wManager.setProgressBar(args)
            result(true)
            break
        case "isVisibleOnAllWorkspaces":
            result(wManager.isVisibleOnAllWorkspaces())
            break
        case "setVisibleOnAllWorkspaces":
            wManager.setVisibleOnAllWorkspaces(args)
            result(true)
            break
        case "hasShadow":
            result(wManager.hasShadow())
            break
        case "setHasShadow":
            wManager.setHasShadow(args)
            result(true)
            break
        case "getOpacity":
            result(wManager.getOpacity())
            break
        case "setOpacity":
            wManager.setOpacity(args)
            result(true)
            break
        case "setBrightness":
            wManager.setBrightness(args)
            result(true)
            break
        case "setIgnoreMouseEvents":
            wManager.setIgnoreMouseEvents(args)
            result(true)
            break
        case "startDragging":
            wManager.startDragging()
            result(true)
            break
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    deinit {
        debugPrint("WindowManagerPluginPlus dealloc")
    }
}
