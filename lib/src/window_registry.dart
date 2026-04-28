import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Process-wide registry for tracking secondary window states.
///
/// Unlike a traditional Dart singleton, the authoritative state lives entirely
/// in the **native layer** (the shared `windowManagers_` C++ map, which is
/// `static` and therefore common to every Flutter engine in the process).
/// Every [WindowRegistry] instance delegates reads to the native layer, so
/// querying from any window - main or secondary - always returns consistent,
/// up-to-date data.
///
/// ### Reactive notifiers
///
/// [activeWindows] and [hiddenWindows] are [ValueNotifier]s that are refreshed
/// automatically by [MultiWindowManager._methodCallHandler] via [refresh]
/// whenever a lifecycle event arrives:
/// - [kWindowEventInitialized] - a new window registered itself
/// - [kWindowEventClose] - a window was truly destroyed
/// - [kWindowEventReuseClose] - a reuse-enabled window hid itself
/// - [kWindowEventReuseShow] - a hidden window became active again
///
/// These notifiers are per-isolate (Dart objects cannot be shared across
/// Flutter engines), but because every engine receives the same global events
/// and each then calls [refresh], all notifiers converge to the same values
/// within one event-loop tick.
///
/// ### Direct queries
///
/// [getActiveWindowIds] and [getHiddenWindowIds] always query the native layer
/// on the spot and bypass the notifier cache.  Use them when you need a
/// guaranteed-fresh value (e.g. before opening a window).
///
/// [MultiWindowManager.createWindowOrReuse] uses these direct queries internally
/// and therefore never depends on the per-isolate cache.
class WindowRegistry {
  static const _channel = MethodChannel('multi_window_manager_static');

  /// Ids of currently active (visible or claimed-for-show) windows.
  ///
  /// Updated automatically on every relevant lifecycle event.
  /// For a guaranteed-fresh value use [getActiveWindowIds].
  final ValueNotifier<List<int>> activeWindows = ValueNotifier([]);

  /// Ids of hidden reuse-cached windows that are available for reuse.
  ///
  /// Updated automatically on every relevant lifecycle event.
  /// For a guaranteed-fresh value use [getHiddenWindowIds].
  final ValueNotifier<List<int>> hiddenWindows = ValueNotifier([]);

  /// Whether there is at least one hidden window available for reuse.
  ///
  /// Reflects the last [refresh] result.  For a guaranteed-fresh check use
  /// `(await getHiddenWindowIds()).isNotEmpty`.
  bool get hasHiddenWindows => hiddenWindows.value.isNotEmpty;

  // -- Native queries --

  /// Queries the native layer for IDs of currently active windows.
  ///
  /// A window is active when it is registered **and** NOT hidden for reuse
  /// (i.e. it is visible, not reuse-enabled, or in the process of being shown
  /// after a claim).
  Future<List<int>> getActiveWindowIds() async {
    return (await _channel.invokeMethod<List<dynamic>>('getActiveWindowIds'))
            ?.cast<int>() ??
        [];
  }

  /// Queries the native layer for IDs of hidden reuse-cached windows.
  ///
  /// Only includes windows that are reuse-enabled, currently invisible, and
  /// not already claimed by a concurrent [MultiWindowManager.createWindowOrReuse]
  /// call.
  Future<List<int>> getHiddenWindowIds() async {
    return (await _channel.invokeMethod<List<dynamic>>('getHiddenWindowIds'))
            ?.cast<int>() ??
        [];
  }

  // -- Internal --

  /// Queries the native layer and updates [activeWindows] and [hiddenWindows].
  ///
  /// Called automatically by [MultiWindowManager._methodCallHandler] on every
  /// window lifecycle event so all windows stay in sync without any manual
  /// state bookkeeping.
  Future<void> refresh() async {
    final results = await Future.wait([
      getActiveWindowIds(),
      getHiddenWindowIds(),
    ]);
    activeWindows.value = results[0];
    hiddenWindows.value = results[1];
  }

  void dispose() {
    activeWindows.dispose();
    hiddenWindows.dispose();
  }
}
