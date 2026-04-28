# MultiWindowManager

[![pub version][pub-image]][pub-url]

[pub-image]: https://img.shields.io/pub/v/multi_window_manager.svg
[pub-url]: https://pub.dev/packages/multi_window_manager

Flutter desktop plugin for creating and managing multiple windows: resizing, repositioning, and inter-window communication.

Fork and re-work of [window_manager_plus](https://pub.dev/packages/window_manager_plus), which itself is based on [window_manager](https://pub.dev/packages/window_manager).
Key additions: **window reuse cache** (avoid re-creating Flutter engines), **cross-window registry** backed by shared native state, **fixed critical errors** fixed restart and crash after close secondary window, **fast isolate-isolate channel** fast channel for realtime windows notify (in process).

**Linux is not currently supported.**

---

- [Platform Support](#platform-support)
- [Setup](#setup)
  - [Windows](#windows-setup)
  - [macOS](#macos-setup)
- [Usage](#usage)
  - [Initialization](#initialization)
  - [Create a window](#create-a-window)
  - [Reuse cached windows](#reuse-cached-windows)
  - [Communication between windows](#communication-between-windows)
  - [Window events](#window-events)
  - [Window registry](#window-registry)
  - [Confirm before closing](#confirm-before-closing)
  - [Quit on close](#quit-on-close)
  - [Hidden at launch](#hidden-at-launch)
- [API](#api)
  - [MultiWindowManager](#multiwindowmanager-1)
  - [WindowListener](#windowlistener-1)
  - [WindowRegistry](#windowregistry-1)

---

## Platform Support

| Linux | macOS | Windows |
|:-----:|:-----:|:-------:|
|  n/a  |   +   |    +    |

---

## Setup

### Windows setup

Edit `windows/runner/main.cpp`:

```diff
 #include <flutter/dart_project.h>
 #include <flutter/flutter_view_controller.h>
 #include <windows.h>

+#include <iostream>
 #include "flutter_window.h"
 #include "utils.h"
+#include "multi_window_manager/multi_window_manager_plugin.h"

 int APIENTRY wWinMain(...) {
   ...

   FlutterWindow window(project);
   Win32Window::Point origin(10, 10);
   Win32Window::Size size(1280, 720);
   if (!window.CreateAndShow(L"my_app", origin, size)) {
     return EXIT_FAILURE;
   }
-  window.SetQuitOnClose(true);
+  window.SetQuitOnClose(false);  // let MultiWindowManager decide when to quit

+  MultiWindowManagerPluginSetWindowCreatedCallback(
+      [](std::vector<std::string> command_line_arguments) {
+        flutter::DartProject project(L"data");
+        project.set_dart_entrypoint_arguments(std::move(command_line_arguments));
+
+        auto window = std::make_shared<FlutterWindow>(project);
+        Win32Window::Point origin(10, 10);
+        Win32Window::Size size(1280, 720);
+        if (!window->CreateAndShow(L"my_app", origin, size)) {
+          std::cerr << "Failed to create window" << std::endl;
+        }
+        window->SetQuitOnClose(false);
+        return std::move(window);
+      });

   ::MSG msg;
   ...
```

`SetQuitOnClose(false)` prevents each child window from terminating the process when it closes.

### macOS setup

Edit `macos/Runner/MainFlutterWindow.swift`:

```diff
 import Cocoa
 import FlutterMacOS
+import multi_window_manager

 class MainFlutterWindow: NSPanel {
     override func awakeFromNib() {
         ...
         RegisterGeneratedPlugins(registry: flutterViewController)
+        MultiWindowManagerPlugin.RegisterGeneratedPlugins = RegisterGeneratedPlugins
         super.awakeFromNib()
     }

+    override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
+        super.order(place, relativeTo: otherWin)
+        hiddenWindowAtLaunch()
+    }
 }
```

Edit `macos/Runner/AppDelegate.swift`:

```diff
 import Cocoa
 import FlutterMacOS
+import multi_window_manager

 @main
 class AppDelegate: FlutterAppDelegate {
   override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
-    return true
+    // Close the app only when windows not contains MainFlutterWindow
+    return !NSApp.windows.contains(where: { $0 is MainFlutterWindow })
   }
 }
```

---

## Usage

### Initialization

Call `ensureInitialized` once before accessing `MultiWindowManager.current`.

The `args` list passed to `main()` carries the window ID in `args[0]` (absent for the main window).

```dart
import 'package:flutter/material.dart';
import 'package:multi_window_manager/multi_window_manager.dart';

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  final windowId = args.isEmpty ? 0 : int.tryParse(args[0]) ?? 0;

  if (windowId == 0) {
    // Main window - never participates in the reuse cache.
    await MultiWindowManager.ensureInitialized(windowId);
  } else {
    // Secondary window - optionally enable reuse cache.
    await MultiWindowManager.ensureInitializedSecondary(
      windowId,
      isEnabledReuse: true, // hide instead of destroy on close
    );
  }

  WindowOptions windowOptions = const WindowOptions(
    size: Size(800, 600),
    center: true,
    backgroundColor: Colors.transparent,
    titleBarStyle: TitleBarStyle.hidden,
  );

  MultiWindowManager.current.waitUntilReadyToShow(windowOptions, () async {
    await MultiWindowManager.current.show();
    await MultiWindowManager.current.focus();
  });

  runApp(const MyApp());
}
```

### Create a window

```dart
// Spawn a new Flutter engine window, passing optional string arguments.
final newWindow = await MultiWindowManager.createWindow(['type=dashboard', 'userId=42']);
if (newWindow != null) {
  print('Created window ${newWindow.id}');
}
```

The arguments are available in `main(List<String> args)` of the new window as `args[1]`, `args[2]`, etc.

### Reuse cached windows

`createWindowOrReuse` avoids spawning a new Flutter engine when a previously-hidden reuse-enabled window is available. Claiming a hidden window is atomic - concurrent calls from different windows cannot pick the same target.

```dart
// Any window can call this - main or secondary.
final window = await MultiWindowManager.createWindowOrReuse(
  args: ['type=dashboard', 'userId=42'],
);
```

For a window to participate in the reuse cache:

1. Initialize it with `isEnabledReuse: true` (see [Initialization](#initialization)).
2. Use `ReuseWindow` as the root widget:

```dart
// Secondary window entry-point:
runApp(MaterialApp(
  home: ReuseWindow(
    initialArgs: parsedArgs,
    windowOptions: const WindowOptions(
      size: Size(1280, 720),
      center: true,
      titleBarStyle: TitleBarStyle.hidden,
    ),
    loadingBuilder: (context) => const Center(child: CircularProgressIndicator()),
    builder: (context, args) {
      // Called on first show AND on every reuse with the latest args.
      return MyPage(args: args);
    },
  ),
));
```

When the user closes a `ReuseWindow`, the native layer hides the OS window instead of destroying the Flutter engine. `createWindowOrReuse` can later reclaim it with new args, rebuilding the content without the overhead of creating a new engine.

`setPreventClose` works independently from the reuse mechanism, so inner widgets can still show "are you sure?" dialogs without breaking reuse.

### Communication between windows

```dart
// Send an event from any window to window with id 1.
final result = await MultiWindowManager.current.invokeMethodToWindow(
  1,
  'showNotification',
  {'message': 'Hello from window ${MultiWindowManager.current.id}'},
);

// In window 1 - implement WindowListener.onEventFromWindow:
class _MyWidgetState extends State<MyWidget> with WindowListener {
  @override
  void initState() {
    super.initState();
    MultiWindowManager.current.addListener(this);
  }

  @override
  void dispose() {
    MultiWindowManager.current.removeListener(this);
    super.dispose();
  }

  @override
  Future<dynamic> onEventFromWindow(
      String eventName, int fromWindowId, dynamic arguments) async {
    if (eventName == 'showNotification') {
      print('Message from $fromWindowId: ${arguments['message']}');
      return 'acknowledged';
    }
    return null;
  }
}
```

To get all registered window IDs:

```dart
final ids = await MultiWindowManager.getAllWindowManagerIds();
```

### Window events

```dart
class _MyWidgetState extends State<MyWidget> with WindowListener {
  @override
  void initState() {
    super.initState();
    MultiWindowManager.current.addListener(this);
  }

  @override
  void dispose() {
    MultiWindowManager.current.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowFocus([int? windowId]) => setState(() {});

  @override
  void onWindowClose([int? windowId]) { /* ... */ }

  @override
  void onWindowMaximize([int? windowId]) { /* ... */ }

  @override
  void onWindowMinimize([int? windowId]) { /* ... */ }

  // Catches every event by name, including reuse events.
  @override
  void onWindowEvent(String eventName, [int? windowId]) {
    print('event: $eventName  window: $windowId');
  }
}
```

For **global** listeners (receive events from all windows with `windowId` set):

```dart
MultiWindowManager.addGlobalListener(myGlobalListener);
MultiWindowManager.removeGlobalListener(myGlobalListener);
```

### Window registry

`MultiWindowManager.registry` is a per-isolate reactive view backed by the shared native state. Use it to drive UI that reflects the live window list.

```dart
// In a widget:
ValueListenableBuilder<List<int>>(
  valueListenable: MultiWindowManager.registry.activeWindows,
  builder: (context, ids, _) => Text('Open windows: $ids'),
);

ValueListenableBuilder<List<int>>(
  valueListenable: MultiWindowManager.registry.hiddenWindows,
  builder: (context, ids, _) => Text('Cached (reusable) windows: $ids'),
);
```

For a guaranteed-fresh read bypassing the local cache:

```dart
final activeIds = await MultiWindowManager.registry.getActiveWindowIds();
final hiddenIds = await MultiWindowManager.registry.getHiddenWindowIds();
```

### Confirm before closing

```dart
class _MyWidgetState extends State<MyWidget> with WindowListener {
  @override
  void initState() {
    super.initState();
    MultiWindowManager.current.addListener(this);
    MultiWindowManager.current.setPreventClose(true);
  }

  @override
  void dispose() {
    MultiWindowManager.current.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose([int? windowId]) async {
    if(!await MultiWindowManager.current.isPreventClose()) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Close window?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await MultiWindowManager.current.setPreventClose(false);
      await MultiWindowManager.current.close();
    }
  }
}
```

### Quit on close

#### macOS

```diff
 override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
-  return true
+  return false
 }
```

#### Windows

Set `SetQuitOnClose(false)` for every window (see [Windows setup](#windows-setup)).
To exit when the main window closes, handle `onWindowClose` and call `exit(0)`.

### Hidden at launch

#### Windows

Edit `windows/runner/win32_window.cpp` to create the window without `WS_VISIBLE`:

```diff
 HWND window = CreateWindow(
-    window_class, title.c_str(), WS_OVERLAPPEDWINDOW | WS_VISIBLE,
+    window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
     ...);
```

Edit `windows/runner/flutter_window.cpp` to remove the auto-show:

```diff
 flutter_controller_->engine()->SetNextFrameCallback([&]() {
-  this->Show();
 });
```

---

## API

<!-- README_DOC_GEN -->
### MultiWindowManager

#### Instance methods

##### [addListener](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/addListener.html)([WindowListener](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/WindowListener-class.html) listener) -> void

Subscribe to window events for this window.

##### [removeListener](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/removeListener.html)([WindowListener](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/WindowListener-class.html) listener) -> void

Unsubscribe from window events.

##### [show](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/show.html)({bool inactive = false}) -> Future\<void\>

Shows and gives focus to the window.

##### [hide](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/hide.html)() -> Future\<void\>

Hides the window.

##### [close](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/close.html)() -> Future\<void\>

Try to close the window (respects `setPreventClose`).

##### [destroy](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/destroy.html)() -> Future\<void\>

Force-close app, bypassing `setPreventClose`.

##### [focus](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/focus.html)() -> Future\<void\>

Focuses on the window.

##### [blur](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/blur.html)() -> Future\<void\>

Removes focus from the window.

##### [isFocused](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/isFocused.html)() -> Future\<bool\>

Returns whether the window is currently focused.

##### [center](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/center.html)({bool animate = false}) -> Future\<void\>

Moves the window to the center of the screen.

##### [setPosition](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/setPosition.html)(Offset position, {bool animate = false}) -> Future\<void\>

Moves the window to a position.

##### [getPosition](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/getPosition.html)() -> Future\<Offset\>

Returns the current window position.

##### [setAlignment](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/setAlignment.html)(Alignment alignment, {bool animate = false}) -> Future\<void\>

Moves the window to a screen-aligned position.

##### [setSize](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/setSize.html)(Size size, {bool animate = false}) -> Future\<void\>

Resizes the window.

##### [getSize](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/getSize.html)() -> Future\<Size\>

Returns the current window size.

##### [setBounds](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/setBounds.html)(Rect? bounds, {Offset? position, Size? size, bool animate = false}) -> Future\<void\>

Resizes and moves the window to the supplied bounds.

##### [getBounds](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/getBounds.html)() -> Future\<Rect\>

Returns the window bounds as a `Rect`.

##### [setMinimumSize](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/setMinimumSize.html)(Size size) -> Future\<void\>

Sets the minimum window size.

##### [setMaximumSize](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/setMaximumSize.html)(Size size) -> Future\<void\>

Sets the maximum window size.

##### [maximize](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/maximize.html)({bool vertically = false}) -> Future\<void\>

Maximizes the window. `vertically` simulates aero snap (Windows only).

##### [unmaximize](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/unmaximize.html)() -> Future\<void\>

Unmaximizes the window.

##### [isMaximized](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/isMaximized.html)() -> Future\<bool\>

Returns whether the window is maximized.

##### [isMaximizable](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/isMaximizable.html)() -> Future\<bool\>

Returns whether the window can be maximized by the user.

##### [setMaximizable](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/setMaximizable.html)(bool isMaximizable) -> Future\<void\>

Sets whether the window can be maximized by the user.

##### [minimize](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/minimize.html)() -> Future\<void\>

Minimizes the window.

##### [restore](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/restore.html)() -> Future\<void\>

Restores the window from a minimized state.

##### [isMinimized](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/isMinimized.html)() -> Future\<bool\>

Returns whether the window is minimized.

##### [isMinimizable](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/isMinimizable.html)() -> Future\<bool\>

Returns whether the window can be minimized by the user.

##### [setMinimizable](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/setMinimizable.html)(bool isMinimizable) -> Future\<void\>

Sets whether the window can be minimized by the user.

##### [setFullScreen](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/setFullScreen.html)(bool isFullScreen) -> Future\<void\>

Sets whether the window should be in full-screen mode.

##### [isFullScreen](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/isFullScreen.html)() -> Future\<bool\>

Returns whether the window is in full-screen mode.

##### [isVisible](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/isVisible.html)() -> Future\<bool\>

Returns whether the window is visible to the user.

##### [setTitle](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/setTitle.html)(String title) -> Future\<void\>

Changes the title of the native window.

##### [getTitle](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/getTitle.html)() -> Future\<String\>

Returns the title of the native window.

##### [setTitleBarStyle](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/setTitleBarStyle.html)(TitleBarStyle titleBarStyle, {bool windowButtonVisibility = true}) -> Future\<void\>

Changes the title bar style of the native window.

##### [getTitleBarHeight](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/getTitleBarHeight.html)() -> Future\<int\>

Returns the title bar height in logical pixels.

##### [setAlwaysOnTop](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/setAlwaysOnTop.html)(bool isAlwaysOnTop) -> Future\<void\>

Sets whether the window is always on top of other windows.

##### [isAlwaysOnTop](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/isAlwaysOnTop.html)() -> Future\<bool\>

Returns whether the window is always on top.

##### [setAlwaysOnBottom](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/setAlwaysOnBottom.html)(bool isAlwaysOnBottom) -> Future\<void\>

Sets whether the window is always below other windows.

##### [isAlwaysOnBottom](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/isAlwaysOnBottom.html)() -> Future\<bool\>

Returns whether the window is always on the bottom.

##### [setOpacity](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/setOpacity.html)(double opacity) -> Future\<void\>

Sets the window opacity (0.0 fully transparent, 1.0 fully opaque).

##### [getOpacity](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/getOpacity.html)() -> Future\<double\>

Returns the current window opacity.

##### [setBackgroundColor](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/setBackgroundColor.html)(Color backgroundColor) -> Future\<void\>

Sets the background color of the window.

##### [setPreventClose](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/setPreventClose.html)(bool isPreventClose) -> Future\<void\>

Intercepts the native close signal. Use with `onWindowClose` to show a confirmation dialog.

##### [isPreventClose](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/isPreventClose.html)() -> Future\<bool\>

Returns whether the native close signal is being intercepted.

##### [setResizable](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/setResizable.html)(bool isResizable) -> Future\<void\>

Sets whether the window can be resized by the user.

##### [isResizable](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/isResizable.html)() -> Future\<bool\>

Returns whether the window is resizable.

##### [setMovable](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/setMovable.html)(bool isMovable) -> Future\<void\>

Sets whether the window can be moved by the user.

##### [isMovable](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/isMovable.html)() -> Future\<bool\>

Returns whether the window is movable.

##### [setClosable](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/setClosable.html)(bool isClosable) -> Future\<void\>

Sets whether the window can be manually closed by the user.

##### [isClosable](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/isClosable.html)() -> Future\<bool\>

Returns whether the window can be closed by the user.

##### [setSkipTaskbar](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/setSkipTaskbar.html)(bool isSkipTaskbar) -> Future\<void\>

Makes the window not show in the taskbar / dock.

##### [isSkipTaskbar](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/isSkipTaskbar.html)() -> Future\<bool\>

Returns whether the window is hidden from the taskbar.

##### [setHasShadow](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/setHasShadow.html)(bool hasShadow) -> Future\<void\>

Sets whether the window has a shadow (frameless windows only on Windows).

##### [hasShadow](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/hasShadow.html)() -> Future\<bool\>

Returns whether the window has a shadow.

##### [setProgressBar](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/setProgressBar.html)(double progress) -> Future\<void\>

Sets the taskbar progress bar value (0.0 to 1.0). Windows only.

##### [setIcon](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/setIcon.html)(String iconPath) -> Future\<void\>

Sets the window / taskbar icon.

##### [dock](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/dock.html)({required DockSide side, required int width}) -> Future\<void\>

Docks the window to a screen edge. Windows only.

##### [undock](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/undock.html)() -> Future\<bool\>

Undocks the window. Windows only.

##### [isDocked](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/isDocked.html)() -> Future\<DockSide?\>

Returns the current dock side, or `null` if not docked.

##### [setAsFrameless](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/setAsFrameless.html)() -> Future\<void\>

Removes the native window frame (title bar, border, etc.).

##### [setAspectRatio](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/setAspectRatio.html)(double aspectRatio) -> Future\<void\>

Locks the window to a fixed aspect ratio.

##### [setBrightness](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/setBrightness.html)(Brightness brightness) -> Future\<void\>

Sets the brightness (light/dark) of the window.

##### [setIgnoreMouseEvents](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/setIgnoreMouseEvents.html)(bool ignore, {bool forward = false}) -> Future\<void\>

Makes the window ignore all mouse events.

##### [popUpWindowMenu](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/popUpWindowMenu.html)() -> Future\<void\>

Pops up the native window menu.

##### [startDragging](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/startDragging.html)() -> Future\<void\>

Starts a window drag from a custom title bar widget.

##### [startResizing](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/startResizing.html)(ResizeEdge resizeEdge) -> Future\<void\>

Starts a window resize from a custom border widget.

##### [waitUntilReadyToShow](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/waitUntilReadyToShow.html)([WindowOptions? options, VoidCallback? callback]) -> Future\<void\>

Applies `WindowOptions` and calls `callback` once the window is ready to display.

##### [invokeMethodToWindow](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/invokeMethodToWindow.html)(int targetWindowId, String method, [dynamic args]) -> Future

Sends an event to another window. The result is the return value of `WindowListener.onEventFromWindow` in the target window.

##### [getDevicePixelRatio](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/getDevicePixelRatio.html)() -> double

Returns the device pixel ratio for this window.

##### [toString](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/toString.html)() -> String

Returns a string representation including the window ID.

#### Static methods

##### [ensureInitialized](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/ensureInitialized.html)(int windowId) -> Future\<void\>

Initialize for the main window (`windowId = 0`). Must be called before accessing `MultiWindowManager.current`.

##### [ensureInitializedSecondary](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/ensureInitializedSecondary.html)(int windowId, {bool isEnabledReuse = false}) -> Future\<void\>

Initialize for a secondary window. Set `isEnabledReuse: true` to enable the reuse cache for this window.

##### [createWindow](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/createWindow.html)([List\<String\>? args]) -> Future\<MultiWindowManager?\>

Spawns a new window. Returns a `MultiWindowManager` instance for the new window, or `null` on failure.

##### [createWindowOrReuse](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/createWindowOrReuse.html)({List\<String\>? args}) -> Future\<MultiWindowManager?\>

Atomically claims a hidden reuse-cached window and reinitializes it with `args`, or spawns a new one if none are available. Safe to call from any window (main or secondary).

##### [fromWindowId](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/fromWindowId.html)(int windowId) -> MultiWindowManager

Returns a `MultiWindowManager` instance for any registered window by ID.

##### [getAllWindowManagerIds](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/getAllWindowManagerIds.html)() -> Future\<List\<int\>\>

Returns the IDs of all windows currently registered in the process.

##### [addGlobalListener](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/addGlobalListener.html)([WindowListener](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/WindowListener-class.html) listener) -> void

Subscribes to events from **all** windows. The `windowId` parameter in callbacks identifies the source window.

##### [removeGlobalListener](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/removeGlobalListener.html)([WindowListener](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/WindowListener-class.html) listener) -> void

Unsubscribes a global listener.

##### [registry](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/MultiWindowManager/registry.html) -> [WindowRegistry](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/WindowRegistry-class.html)

Process-wide reactive window registry. See [WindowRegistry](#windowregistry-1).

---

### WindowListener

Mixin used with `addListener` / `addGlobalListener`. When used as a global listener, `windowId` identifies the source window; when used as a local listener it is always `null`.

##### [onWindowClose](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/WindowListener/onWindowClose.html)([int? windowId]) -> void

Emitted when the window is going to be closed.

##### [onWindowFocus](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/WindowListener/onWindowFocus.html)([int? windowId]) -> void

Emitted when the window gains focus.

##### [onWindowBlur](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/WindowListener/onWindowBlur.html)([int? windowId]) -> void

Emitted when the window loses focus.

##### [onWindowMaximize](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/WindowListener/onWindowMaximize.html)([int? windowId]) -> void

Emitted when the window is maximized.

##### [onWindowUnmaximize](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/WindowListener/onWindowUnmaximize.html)([int? windowId]) -> void

Emitted when the window exits a maximized state.

##### [onWindowMinimize](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/WindowListener/onWindowMinimize.html)([int? windowId]) -> void

Emitted when the window is minimized.

##### [onWindowRestore](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/WindowListener/onWindowRestore.html)([int? windowId]) -> void

Emitted when the window is restored from a minimized state.

##### [onWindowResize](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/WindowListener/onWindowResize.html)([int? windowId]) -> void

Emitted while the window is being resized.

##### [onWindowResized](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/WindowListener/onWindowResized.html)([int? windowId]) -> void

Emitted once when the window finishes resizing. Windows / macOS only.

##### [onWindowMove](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/WindowListener/onWindowMove.html)([int? windowId]) -> void

Emitted while the window is being moved.

##### [onWindowMoved](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/WindowListener/onWindowMoved.html)([int? windowId]) -> void

Emitted once when the window finishes moving. Windows / macOS only.

##### [onWindowEnterFullScreen](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/WindowListener/onWindowEnterFullScreen.html)([int? windowId]) -> void

Emitted when the window enters full-screen mode.

##### [onWindowLeaveFullScreen](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/WindowListener/onWindowLeaveFullScreen.html)([int? windowId]) -> void

Emitted when the window leaves full-screen mode.

##### [onWindowDocked](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/WindowListener/onWindowDocked.html)([int? windowId]) -> void

Emitted when the window enters a docked state. Windows only.

##### [onWindowUndocked](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/WindowListener/onWindowUndocked.html)([int? windowId]) -> void

Emitted when the window leaves a docked state. Windows only.

##### [onWindowEvent](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/WindowListener/onWindowEvent.html)(String eventName, [int? windowId]) -> void

Emitted for every window event, including reuse lifecycle events.

##### [onEventFromWindow](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/WindowListener/onEventFromWindow.html)(String eventName, int fromWindowId, dynamic arguments) -> Future

Receives inter-window messages sent via `invokeMethodToWindow`. The return value is forwarded back to the caller.

---

### WindowRegistry

Accessible via `MultiWindowManager.registry`. Backed by shared native C++ state, so it is consistent across all Flutter engines in the process.

##### [activeWindows](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/WindowRegistry/activeWindows.html) -> ValueNotifier\<List\<int\>\>

IDs of currently visible / active windows. Updated automatically on every lifecycle event.

##### [hiddenWindows](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/WindowRegistry/hiddenWindows.html) -> ValueNotifier\<List\<int\>\>

IDs of reuse-cached hidden windows available for reclaiming. Updated automatically.

##### [hasHiddenWindows](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/WindowRegistry/hasHiddenWindows.html) -> bool

Whether at least one reusable window is available (reflects the last `refresh` result).

##### [getActiveWindowIds](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/WindowRegistry/getActiveWindowIds.html)() -> Future\<List\<int\>\>

Queries the native layer directly. Always returns a fresh value.

##### [getHiddenWindowIds](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/WindowRegistry/getHiddenWindowIds.html)() -> Future\<List\<int\>\>

Queries the native layer directly. Always returns a fresh value.

##### [refresh](https://pub.dev/documentation/multi_window_manager/latest/multi_window_manager/WindowRegistry/refresh.html)() -> Future\<void\>

Re-queries native state and updates `activeWindows` and `hiddenWindows`. Called automatically by `MultiWindowManager` on every lifecycle event.

<!-- README_DOC_GEN -->

---

## License

[MIT](./LICENSE)
