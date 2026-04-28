import 'package:flutter/foundation.dart';

/// Dart-level registry for tracking secondary window states.
///
/// Intended for use only in the **main window** process (window id = 0).
///
/// Mirrors the application-level `_WindowRegistry` but lives inside the plugin
/// so it can be used together with [WindowManagerPlus.createWindowOrReuse].
///
/// The registry is maintained automatically by [WindowManagerPlus._methodCallHandler]:
/// - [kWindowEventInitialized] → [register]
/// - [kWindowEventClose]       → [unregister]
/// - [kWindowEventHideWindow]  → [markHidden]
class WindowRegistry {
  final Map<int, bool> _windows = {}; // id → isHidden

  /// Ids of currently active (visible) windows.
  final ValueNotifier<List<int>> activeWindows = ValueNotifier([]);

  /// Ids of hidden windows that are available for reuse.
  final ValueNotifier<List<int>> hiddenWindows = ValueNotifier([]);

  void _notify() {
    activeWindows.value = _windows.entries.where((e) => !e.value).map((e) => e.key).toList();
    hiddenWindows.value = _windows.entries.where((e) => e.value).map((e) => e.key).toList();
  }

  /// Register a newly created window as active.
  void register(int id) {
    _windows[id] = false;
    _notify();
  }

  /// Mark a window as hidden — it becomes available for reuse.
  ///
  /// Intentionally does **not** check [_windows.containsKey]: the native
  /// `kWindowEventClose` can arrive at the main window synchronously and call
  /// [unregister] before the async `kWindowEventHideWindow` IPC from the child
  /// reaches the main window and calls [markHidden].  By unconditionally
  /// writing the entry we survive that race condition.
  void markHidden(int id) {
    _windows[id] = true;
    _notify();
  }

  /// Mark a previously hidden window as active again.
  void markActive(int id) {
    if (_windows.containsKey(id)) {
      _windows[id] = false;
      _notify();
    }
  }

  /// Remove a window from the registry (only when truly closed / destroyed).
  void unregister(int id) {
    _windows.remove(id);
    _notify();
  }

  /// Returns the ids of all hidden windows (available for reuse).
  List<int> getHiddenWindowIds() => List.unmodifiable(hiddenWindows.value);

  /// Returns the ids of all active (visible) windows.
  List<int> getActiveWindowIds() => List.unmodifiable(activeWindows.value);

  /// Whether there is at least one hidden window available for reuse.
  bool get hasHiddenWindows => hiddenWindows.value.isNotEmpty;

  void dispose() {
    activeWindows.dispose();
    hiddenWindows.dispose();
  }
}
