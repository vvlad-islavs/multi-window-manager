import 'dart:convert';
import 'dart:developer';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:multi_window_manager/src/title_bar_style.dart';
import 'package:multi_window_manager/src/window_listener.dart';
import 'package:multi_window_manager/src/window_manager.dart';
import 'package:multi_window_manager/src/window_options.dart';

/// Generic host widget for **secondary windows** in a multi-window setup.
///
/// Handles the full lifecycle without knowing about application-specific window
/// types ([WindowType] in your app):
///
/// - **Initial display**: calls [waitUntilReadyToShow] with [windowOptions].
/// - **Hide instead of close**: relies on the native [kWindowEventReuseClose]
///   mechanism (enabled by passing `isEnabledReuse: true` to
///   [MultiWindowManager.ensureInitialized]).  The native WM_CLOSE handler
///   hides the window and emits [kWindowEventReuseClose] globally so the main
///   window registry is updated automatically - **without touching
///   [setPreventClose]**.  This means inner widgets can use [setPreventClose]
///   freely for their own "are you sure?" dialogs.
/// - **Reuse**: on [kWindowEventShowWindow] (sent by
///   [MultiWindowManager.createWindowOrReuse]) the window repositions/shows
///   itself and rebuilds via [builder] with the new args.
///
/// ### Usage (secondary window entry-point)
/// ```dart
/// // In ensureInitialized (secondary window main):
/// await MultiWindowManager.ensureInitialized(id, isEnabledReuse: true);
///
/// // Then run:
/// runApp(
///   MaterialApp(
///     home: SecondaryWindowHost(
///       initialArgs: {'type': type.name, 'data': data},
///       builder: (context, args, isInitialized) {
///         if (!isInitialized) return const SizedBox();
///         return _buildScreen(args!['type'], args['data']);
///       },
///     ),
///   ),
/// );
/// ```
///
/// [args] has the same structure on **both** the initial launch and every reuse,
/// so the builder does not need to distinguish between the two cases.
class SecondaryWindowHost extends StatefulWidget {
  const SecondaryWindowHost({
    required this.builder,
    this.loadingBuilder,
    this.initialArgs,
    this.windowOptions = const WindowOptions(
      center: true,
      size: Size(1440, 940),
      minimumSize: Size(1440, 940),
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.hidden,
    ),
    super.key,
  });

  /// Args passed to the window on first launch.
  ///
  /// Must match the structure that arrives via [kWindowEventShowWindow] on reuse,
  /// so that [builder] receives a consistent map on both paths.
  /// Typically: `{'type': type.name, 'data': {...}}`.
  final dynamic initialArgs;

  /// Window position / size configuration applied on every (re)show.
  final WindowOptions windowOptions;

  final Widget Function(BuildContext context)? loadingBuilder;

  /// Called to build the content of the window.
  ///
  /// Parameters:
  /// - [context]       - current build context.
  /// - [args]          - current raw args (updated on every reuse).
  /// - [isInitialized] - `false` while [waitUntilReadyToShow] is in progress
  ///   or while the window is hidden for reuse; use this to show a placeholder.
  final Widget Function(BuildContext context, dynamic args) builder;

  @override
  State<SecondaryWindowHost> createState() => SecondaryWindowHostState();
}

class SecondaryWindowHostState extends State<SecondaryWindowHost> {
  dynamic _currentArgs;
  bool _isInitialized = false;

  // Separate internal listener.
  // Using a dedicated private listener object means this host widget does NOT
  // implement WindowListener itself.  Inner widgets added via
  // MultiWindowManager.current.addListener() are unaffected: their
  // onWindowClose callbacks and setPreventClose state are never touched.
  late final _SecondaryReuseListener _listener;

  @override
  void initState() {
    super.initState();
    _listener = _SecondaryReuseListener(
      onReuseClose: _onReuseClose,
      onShowWindow: _onShowWindow,
    );
    MultiWindowManager.current.addListener(_listener);
    _currentArgs = widget.initialArgs;
    _showWindow();
  }

  /// Positions and shows the window, then marks [_isInitialized] = true.
  /// Called both on first launch and on every [kWindowEventShowWindow] reuse.
  Future<void> _showWindow() async {
    if (mounted && _isInitialized) setState(() => _isInitialized = false);

    await MultiWindowManager.current.waitUntilReadyToShow(widget.windowOptions,
        () async {
      await MultiWindowManager.current.show();
      await MultiWindowManager.current.focus();
    });

    if (mounted) setState(() => _isInitialized = true);

    // On Windows the Flutter child-view size can fall out of sync with the
    // native window after waitUntilReadyToShow (especially when the loading
    // widget has zero or minimal size).  A 1-pixel resize-and-restore forces
    // WM_SIZE on the FlutterView, re-synchronising the compositing layer.
    // The same pattern is used inside setFullScreen() (see issue #311).
    if (Platform.isWindows) {
      _forceWindowsRepaint();
    }

    log('SecondaryWindowHost: window ${MultiWindowManager.current.id} shown',
        name: 'SecondaryWindowHost');
  }

  /// Schedules a 1-pixel resize round-trip on Windows to force the Flutter
  /// render surface to repaint after the window transitions to visible content.
  void _forceWindowsRepaint() {
    if (!Platform.isWindows) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final size = await MultiWindowManager.current.getSize();
      await MultiWindowManager.current.setSize(size + const Offset(0, 1));
      await MultiWindowManager.current.setSize(size);
    });
  }

  // Callbacks forwarded from [_SecondaryReuseListener]

  /// Called when the native [kWindowEventReuseClose] event is received.
  ///
  /// Resets [_isInitialized] so the placeholder is shown until the next reuse.
  void _onReuseClose() {
    if (mounted) setState(() => _isInitialized = false);
    log('SecondaryWindowHost: window ${MultiWindowManager.current.id} closed for reuse',
        name: 'SecondaryWindowHost');
  }

  /// Called when the main window sends [kWindowEventShowWindow] to reuse this
  /// window with new [args].
  Future<void> _onShowWindow(dynamic args) async {
    _currentArgs = args;
    await _showWindow();
  }

  // Widget

  @override
  void dispose() {
    MultiWindowManager.current.removeListener(_listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _isInitialized
      ? widget.builder(context, _currentArgs)
      : widget.loadingBuilder?.call(context) ??
          const Center(
            child: SizedBox(
              height: 60,
              width: 60,
              child: CircularProgressIndicator(),
            ),
          );
}

// Private listener

/// Internal [WindowListener] used exclusively by [SecondaryWindowHostState].
///
/// Handles only two events:
/// - [kWindowEventReuseClose] (via [onWindowEvent]) - the native WM_CLOSE was
///   intercepted by the reuse mechanism; the window is now hidden.
/// - [kWindowEventShowWindow] (via [onEventFromWindow]) - any window is asking
///   this window to reinitialize and show with new args.
///
/// Deliberately does **not** override [onWindowClose], so inner widgets that
/// call [setPreventClose] and implement their own close-confirmation dialogs
/// are not affected.
class _SecondaryReuseListener with WindowListener {
  _SecondaryReuseListener({
    required this.onReuseClose,
    required this.onShowWindow,
  });

  final void Function() onReuseClose;
  final Future<void> Function(dynamic args) onShowWindow;

  @override
  void onWindowEvent(String eventName, [int? windowId]) {
    // Only handle events targeted at THIS window (windowId == null means the
    // event was emitted via _EmitEvent, i.e. for the current window itself).
    if (windowId != null) return;
    if (eventName == kWindowEventReuseClose) {
      onReuseClose();
    }
  }

  @override
  Future<dynamic> onEventFromWindow(
      String eventName, int fromWindowId, dynamic arguments) async {
    if (eventName == kWindowEventShowWindow) {
      debugPrint('dfbfd');
      await onShowWindow(arguments);
      return null;
    }
    return null;
  }
}
