import 'dart:async';

import 'package:flutter/foundation.dart' show ChangeNotifier, debugPrint;
import 'package:multi_window_manager/src/window_ipc.dart';

/// Mixin for a [ChangeNotifier] that broadcasts field-level delta updates
/// to other windows via [WindowIpc].
///
/// Each notifier is identified by a [topic] string prepended to every message.
/// This allows multiple notifier instances to share a single [WindowIpc] port
/// per window without interfering with each other.
///
/// Wire format (flat [List<Object?>]):
///   index 0       - topic (String) - routing key, must match on sender/receiver
///   index 1,3,5.. - field name (String)
///   index 2,4,6.. - field value (Object?)
///
/// Example: `['person', 'name', 'John', 'age', 25]`
///
/// Changes that happen in the same synchronous execution block are batched into
/// a single IPC message (via [scheduleMicrotask]), so rapid successive
/// assignments produce one message instead of N.
///
/// Usage on the SOURCE window:
/// ```dart
/// class PersonNotifier extends ChangeNotifier with IpcNotifierSender {
///   String _name = '';
///   int _age = 0;
///
///   String get name => _name;
///   set name(String v) {
///     _name = v;
///     notifyListeners();
///     ipcMark('name', v);
///   }
///
///   int get age => _age;
///   set age(int v) {
///     _age = v;
///     notifyListeners();
///     ipcMark('age', v);
///   }
/// }
///
/// // Setup (once per window, after ensureInitialized):
/// final ipc = MultiWindowManager.current.createIpc<List<Object?>>();
/// personNotifier.ipcSetup(ipc, 'person');
/// productNotifier.ipcSetup(ipc, 'product'); // same ipc, different topic
/// ```
mixin IpcNotifierSender on ChangeNotifier {
  WindowIpc<List<Object?>>? _ipcSender;
  String? _ipcTopic;

  /// Changed fields waiting to be flushed in the current microtask cycle.
  final Map<String, Object?> _ipcPending = {};
  bool _ipcFlushScheduled = false;

  /// Attaches [ipc] to this notifier with the given [topic].
  ///
  /// [topic] must be unique per notifier type within the same window and
  /// must match the [topic] used in [IpcNotifierReceiver.ipcListen].
  ///
  /// Multiple notifiers can share the same [ipc] instance as long as they use
  /// different topics.
  void ipcSetup(WindowIpc<List<Object?>> ipc, String topic) {
    _ipcSender = ipc;
    _ipcTopic = topic;
  }

  /// Records that [field] changed to [value] and schedules a microtask flush.
  ///
  /// Call this inside your setters AFTER updating the backing field and
  /// calling [notifyListeners]. If several fields change before the microtask
  /// fires (i.e. within the same synchronous call stack), all changes are
  /// coalesced into one IPC message.
  void ipcMark(String field, Object? value) {
    _ipcPending[field] = value;
    if (_ipcFlushScheduled) return;
    _ipcFlushScheduled = true;
    scheduleMicrotask(_ipcFlush);
  }

  void _ipcFlush() {
    _ipcFlushScheduled = false;
    final ipc = _ipcSender;
    final topic = _ipcTopic;
    if (ipc == null || topic == null || _ipcPending.isEmpty) return;

    // Wire format: [topic, field1, val1, field2, val2, ...]
    // Topic at index 0 is the routing key for the receiver.
    final payload = <Object?>[
      topic,
      for (final e in _ipcPending.entries) ...[e.key, e.value],
    ];
    _ipcPending.clear();

    final targets = ipc.connectedWindowIds;
    debugPrint(
        '[IpcNotifierSender] flush  topic=$topic  targets=$targets  payload=$payload');
    if (targets.isEmpty) {
      debugPrint(
          '[IpcNotifierSender] flush: no connected windows, payload dropped');
      return;
    }
    for (final targetId in targets) {
      ipc.notifyWindow(
          targetId, [...payload, 'ts', DateTime.now().microsecondsSinceEpoch]);
    }
  }
}

/// Mixin for a [ChangeNotifier] that receives and applies delta updates
/// arriving from a source window via [WindowIpc].
///
/// Messages are filtered by [topic] so that a single [WindowIpc] port can
/// carry updates for multiple notifier types simultaneously.
///
/// A single [notifyListeners] is issued after ALL fields in one batch have
/// been applied, avoiding multiple UI rebuilds per IPC message.
///
/// Usage on the RECEIVER window:
/// ```dart
/// class PersonNotifier extends ChangeNotifier with IpcNotifierReceiver {
///   String name = '';
///   int age = 0;
///
///   @override
///   void ipcApplyField(String field, Object? value) {
///     switch (field) {
///       case 'name': name = value as String;
///       case 'age':  age  = value as int;
///     }
///   }
///
///   @override
///   void dispose() {
///     ipcCancelListeners();
///     super.dispose();
///   }
/// }
///
/// // Setup (once per window, after ensureInitialized):
/// final ipc = MultiWindowManager.current.createIpc<List<Object?>>();
/// await ipc.connectWindow(sourceWindowId);
///
/// personNotifier.ipcListen(ipc, sourceWindowId, 'person');
/// productNotifier.ipcListen(ipc, sourceWindowId, 'product'); // same ipc, different topic
/// ```
///
/// Multiple source windows are supported: call [ipcListen] for each one.
mixin IpcNotifierReceiver on ChangeNotifier {
  final List<StreamSubscription<dynamic>> _ipcSubscriptions = [];

  /// Subscribes to delta updates tagged with [topic] from [sourceId].
  ///
  /// [topic] must match the [topic] supplied to [IpcNotifierSender.ipcSetup]
  /// on the sending side.
  ///
  /// May be called more than once to receive from multiple source windows.
  void ipcListen(
    WindowIpc<List<Object?>> ipc,
    int sourceId,
    String topic,
  ) {
    debugPrint(
        '[IpcNotifierReceiver] ipcListen: sourceId=$sourceId  topic=$topic');
    final sub = ipc
        .listenWindow(sourceId)
        // Filter by topic at index 0 before touching any other index.
        .where((msg) {
      final match = msg.isNotEmpty && msg[0] == topic;
      if (!match && msg.isNotEmpty) {
        debugPrint(
            '[IpcNotifierReceiver] filtered out topic="${msg[0]}" (expected "$topic")');
      }
      return match;
    }).listen(_ipcApplyDelta);
    _ipcSubscriptions.add(sub);
  }

  void _ipcApplyDelta(List<Object?> delta) {
    debugPrint('[IpcNotifierReceiver] applyDelta: $delta');
    // Index 0 is the topic (already filtered). Fields start at index 1.
    for (int i = 1; i + 1 < delta.length; i += 2) {
      debugPrint(
          '[IpcNotifierReceiver] applyField: ${delta[i]} = ${delta[i + 1]}');
      ipcApplyField(delta[i] as String, delta[i + 1]);
    }
    // One rebuild for the whole batch, regardless of field count.
    notifyListeners();
  }

  /// Override to map an incoming field name to the corresponding property.
  ///
  /// Called once per changed field within the batch. [notifyListeners] is
  /// called by the framework after all fields in the batch have been applied.
  void ipcApplyField(String field, Object? value);

  /// Cancels all IPC stream subscriptions started by [ipcListen].
  ///
  /// Call before [dispose] to avoid delivering events to a dead notifier.
  void ipcCancelListeners() {
    for (final sub in _ipcSubscriptions) {
      sub.cancel();
    }
    _ipcSubscriptions.clear();
  }
}
