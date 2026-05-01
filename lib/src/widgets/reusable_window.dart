import 'dart:developer';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:multi_window_manager/src/reuse_window_listener.dart';
import 'package:multi_window_manager/src/title_bar_style.dart';
import 'package:multi_window_manager/src/window_manager.dart';
import 'package:multi_window_manager/src/window_options.dart';

/// Root widget for windows that participate in the reuse cache.
///
/// Must be used as the `home` of a window launched with
/// `isEnabledReuse: true` in [MultiWindowManager.ensureInitializedSecondary].
///
/// Responsibilities:
/// - **Initial display**: calls [waitUntilReadyToShow] with [windowOptions].
/// - **Hide instead of close**: relies on the native [kWindowEventReuseClose]
///   mechanism. The native WM_CLOSE handler hides the window and emits
///   [kWindowEventReuseClose] globally so the registry is updated automatically
///   without touching [setPreventClose]. Inner widgets remain free to use
///   [setPreventClose] for their own "are you sure?" dialogs.
/// - **Reuse**: on [kWindowEventShowWindow] (sent by any window via
///   [MultiWindowManager.createWindowOrReuse]) repositions/shows itself and
///   rebuilds via [builder] with the new args.
///
/// ### Usage
/// ```dart
/// await MultiWindowManager.ensureInitializedSecondary(windowId, isEnabledReuse: true);
///
/// runApp(MaterialApp(
///   home: ReusableWindow(
///     initialArgs: args,
///     builder: (context, args) => MyPage(args: args),
///   ),
/// ));
/// ```
///
/// [args] has the same structure on both the initial launch and every reuse,
/// so [builder] does not need to distinguish between the two cases.
class ReusableWindow extends StatefulWidget {
  const ReusableWindow({
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
  /// Must match the structure that arrives via [kWindowEventShowWindow] on
  /// reuse, so [builder] receives a consistent value on both paths.
  final dynamic initialArgs;

  /// Window position / size configuration applied on every (re)show.
  final WindowOptions windowOptions;

  /// Optional placeholder shown while [waitUntilReadyToShow] is in progress
  /// or while the window is hidden between reuses.
  final Widget Function(BuildContext context)? loadingBuilder;

  /// Builds the window content.
  ///
  /// Called on first show and on every reuse with the latest [args].
  final Widget Function(BuildContext context, dynamic args) builder;

  @override
  State<ReusableWindow> createState() => ReusableWindowState();
}

class ReusableWindowState extends State<ReusableWindow>
    implements ReusableWindowListener {
  dynamic _currentArgs;
  final GlobalKey _windowSecondaryKey = GlobalKey();
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    MultiWindowManager.current.addReuseListener(this);
    _currentArgs = widget.initialArgs;
    _showWindow();
  }

  @override
  void dispose() {
    MultiWindowManager.current.removeReuseListener(this);
    super.dispose();
  }

  /// Positions and shows the window, then marks [_isInitialized] = true.
  /// Called on first launch and on every [kWindowEventShowWindow] reuse.
  Future<void> _showWindow() async {
    if (mounted && _isInitialized) setState(() => _isInitialized = false);

    await MultiWindowManager.current.waitUntilReadyToShow(widget.windowOptions,
        () async {
      Navigator.of(
        _windowSecondaryKey.currentContext ?? context,
        rootNavigator: true,
      ).popUntil((route) => route.isFirst);
      // Some time to close all dialogs
      await Future.delayed(const Duration(milliseconds: 150));

      await MultiWindowManager.current.show();
      await MultiWindowManager.current.focus();
    });

    if (mounted) setState(() => _isInitialized = true);

    // On Windows the Flutter child-view size can fall out of sync with the
    // native window after waitUntilReadyToShow. A 1-pixel resize-and-restore
    // forces WM_SIZE on the FlutterView, re-synchronising the compositing layer.
    if (Platform.isWindows) {
      _forceWindowsRepaint();
    }

    log(
      'ReusableWindow ${MultiWindowManager.current.id} shown',
      name: 'ReusableWindow',
    );
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

  // ReusableWindowListener

  @override
  Future<void> onReuseClose() async {
    if (mounted) setState(() => _isInitialized = false);
    log(
      'ReusableWindow ${MultiWindowManager.current.id} hidden for reuse',
      name: 'ReusableWindow',
    );
  }

  @override
  Future<void> onShowWindow(dynamic args) async {
    _currentArgs = args;
    await _showWindow();
  }

  @override
  Widget build(BuildContext context) => _isInitialized
      ? KeyedSubtree(
          key: _windowSecondaryKey,
          child: widget.builder(context, _currentArgs))
      : widget.loadingBuilder?.call(context) ??
          const Center(
            child: SizedBox(
              height: 60,
              width: 60,
              child: CircularProgressIndicator(),
            ),
          );
}
