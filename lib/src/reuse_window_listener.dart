import 'package:meta/meta.dart';

/// Internal-only listener for reuse-lifecycle events.
///
/// Implemented by [ReuseWindowState] and registered via
/// [MultiWindowManager.addReuseListener] / [MultiWindowManager.removeReuseListener].
///
/// Not exported from the library barrel - public window events use [WindowListener].
/// Keeps technical reuse events (hide/show cycle) out of the public API surface.
@internal
abstract class ReusableWindowListener {
  /// Called when the native layer intercepted WM_CLOSE and hid this window
  /// instead of destroying it (reuse-close path).
  void onReuseClose() {}

  /// Called when another window reclaimed this hidden window via
  /// [MultiWindowManager.createWindowOrReuse] and wants it to show with new args.
  Future<void> onShowWindow(dynamic args) async {}
}
