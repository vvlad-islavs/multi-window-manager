import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:multi_window_manager/src/window_listener.dart';
import 'package:multi_window_manager/src/window_manager.dart';

// IsolateNameServer key prefix to avoid collisions with other plugins.
const _kPortPrefix = 'mwm_ipc_';

/// Wire format: List<Object?> [ fromId (int), payload (T) ]
/// Disconnect signal: payload == null  -> [ fromId, null ]
/// This avoids Map creation / key hashing on every tick.

/// Direct isolate-to-isolate communication channel between windows.
///
/// After the one-time connection handshake (one native method-channel call),
/// all data flows through [SendPort.send] / [ReceivePort] with no native
/// overhead. This makes it suitable for high-frequency payloads such as
/// [ChangeNotifier] updates or stream values.
///
/// Type parameter [T] is the payload type for both [notifyWindow] and
/// [listenWindow]. Every window pair shares the same T, so sender and
/// receiver must agree on the concrete type. Use a plain value type or
/// a flat [List] to keep isolate-transfer latency minimal.
///
/// Connection lifecycle:
/// - [connectWindow] establishes a bidirectional link (one native call total).
/// - When this window fires [close] or [reuse-close], a disconnect signal is
///   sent to all peers, and local state is cleared.
/// - Peers receive the signal in [_handleMessage] and clean up their side.
///
/// Direction of each map:
/// - [_outgoing]: ports this window uses to SEND data to other windows.
///   Populated by [connectWindow] (explicit) or automatically when the
///   remote window connects here first.
/// - [_incoming]: ports of windows that have connected TO this window.
///   Used by [IpcNotifierSender] to know who to broadcast to.
class WindowIpc<T> with WindowListener {
  /// Creates an IPC channel for [wm].
  ///
  /// Prefer [MultiWindowManager.createIpc] which ties the channel lifetime
  /// to the window manager instance. Creating two [WindowIpc] instances for
  /// the same window replaces the previous port registration in
  /// [IsolateNameServer].
  WindowIpc(this._wm) {
    // Remove stale entry from a previous instance (e.g. after hot restart).
    IsolateNameServer.removePortNameMapping('$_kPortPrefix${_wm.id}');
    final registered = IsolateNameServer.registerPortWithName(
      _port.sendPort,
      '$_kPortPrefix${_wm.id}',
    );
    debugPrint(
        '[IPC:${_wm.id}] init  port=$_kPortPrefix${_wm.id}  registered=$registered');
    _subscription = _port.listen(_handleMessage);
    _wm.addListener(this);
  }

  final MultiWindowManager _wm;
  final ReceivePort _port = ReceivePort();
  StreamSubscription<dynamic>? _subscription;
  bool _disposed = false;

  /// SendPorts this window uses to send data TO other windows.
  final Map<int, SendPort> _outgoing = {};

  /// SendPorts belonging to windows that have connected TO this window.
  /// Inspect with [connectedWindowIds].
  final Map<int, SendPort> _incoming = {};

  /// Per-source broadcast stream controllers keyed by source window ID.
  final Map<int, StreamController<T>> _streams = {};

  /// Called when another window establishes a connection to this window.
  ///
  /// Fires after the [ipc-connect] handshake completes on the receiving side,
  /// i.e. when a remote window called [connectWindow] and pointed at this
  /// window. Use this to reactively set up stream listeners or notifiers that
  /// should start receiving data from the connecting window.
  ///
  /// Example:
  /// ```dart
  /// _ipc.onConnected = (int fromId) {
  ///   _personReceiver.ipcListen(_ipc, fromId, 'person');
  /// };
  /// ```
  void Function(int fromWindowId)? onConnected;

  /// Called when a previously connected window disconnects (closes or hides).
  ///
  /// Fires when a disconnect sentinel is received from [fromWindowId], or when
  /// [dispose] / [close] / [reuse-close] events clean up the connection.
  void Function(int fromWindowId)? onDisconnected;

  /// IDs of all windows this channel can currently send data to.
  ///
  /// Includes windows this instance connected to via [connectWindow] AND
  /// windows that connected to this instance first (auto-populated via the
  /// bidirectional handshake). The sender iterates this set to push updates.
  Set<int> get connectedWindowIds => _outgoing.keys.toSet();

  // ---------------------------------------------------------------------------
  // Internal message dispatch
  // ---------------------------------------------------------------------------

  void _handleMessage(dynamic message) {
    if (message is! List || message.length < 2) {
      debugPrint('[IPC:${_wm.id}] _handleMessage: unexpected format: $message');
      return;
    }
    final from = message[0];
    if (from is! int) {
      debugPrint(
          '[IPC:${_wm.id}] _handleMessage: bad fromId type: ${message[0]}');
      return;
    }

    // Disconnect signal: payload == null
    if (message[1] == null) {
      debugPrint(
          '[IPC:${_wm.id}] _handleMessage: disconnect signal from $from');
      _disconnectFrom(from);
      return;
    }

    debugPrint(
        '[IPC:${_wm.id}] _handleMessage: from=$from  payload=${message[1]}');
    _streams
        .putIfAbsent(from, () => StreamController<T>.broadcast())
        .add(message[1] as T);
  }

  // ---------------------------------------------------------------------------
  // Disconnect helpers
  // ---------------------------------------------------------------------------

  void _disconnectFrom(int windowId) {
    _outgoing.remove(windowId);
    _incoming.remove(windowId);
    final sc = _streams.remove(windowId);
    sc?.close();
    debugPrint('[IPC:${_wm.id}] disconnected from window $windowId');
    onDisconnected?.call(windowId);
  }

  /// Sends a disconnect signal to all known peers, then clears local state.
  void _notifyAllDisconnect() {
    debugPrint('[IPC:${_wm.id}] notifying all peers of disconnect');
    final allPeers = {..._outgoing.keys, ..._incoming.keys};
    for (final id in allPeers) {
      final sp = _outgoing[id] ?? _incoming[id];
      if (sp == null) continue;
      try {
        sp.send([_wm.id, null]); // null payload = disconnect sentinel
      } catch (e) {
        debugPrint('[IPC:${_wm.id}] failed to send disconnect to $id: $e');
      }
    }
    _outgoing.clear();
    _incoming.clear();
    for (final sc in _streams.values) {
      sc.close();
    }
    _streams.clear();
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Connects to the window with [targetId] so that [notifyWindow] can
  /// deliver data to it.
  ///
  /// Looks up [targetId]'s [SendPort] from [IsolateNameServer] (registered
  /// when the target calls [MultiWindowManager.createIpc]).
  /// Then sends ONE native event to the target so it can populate its own
  /// [_incoming] map. The connection is automatically bidirectional: the
  /// target can reply to this window without a separate [connectWindow] call.
  ///
  /// Returns `true` on success, `false` if the target has not yet called
  /// [MultiWindowManager.createIpc] (retry after target is ready).
  Future<bool> connectWindow(int targetId) async {
    if (_outgoing.containsKey(targetId)) {
      debugPrint('[IPC:${_wm.id}] connectWindow($targetId): already connected');
      return true;
    }
    final portName = '$_kPortPrefix$targetId';
    final sp = IsolateNameServer.lookupPortByName(portName);
    debugPrint(
        '[IPC:${_wm.id}] connectWindow($targetId): lookup "$portName" -> ${sp != null ? "found" : "NOT FOUND"}');
    if (sp == null) return false;

    _outgoing[targetId] = sp;
    debugPrint(
        '[IPC:${_wm.id}] connectWindow($targetId): outgoing stored, sending ipc-connect via native');
    try {
      await _wm.invokeMethodToWindow(
        targetId,
        'ipc-connect',
        {'portName': '$_kPortPrefix${_wm.id}'},
      );
      debugPrint(
          '[IPC:${_wm.id}] connectWindow($targetId): ipc-connect ack received');
    } catch (e) {
      // Port is ready; native ack is best-effort.
      debugPrint(
          '[IPC:${_wm.id}] connectWindow($targetId): ipc-connect ack error (non-fatal): $e');
    }
    return true;
  }

  /// Sends [data] to the window with [targetId].
  ///
  /// Calls [connectWindow] automatically on first use. After the connection
  /// is established all subsequent calls go directly through [SendPort.send]
  /// with no native layer involvement.
  ///
  /// Returns `true` if the message was dispatched, `false` if the target is
  /// not reachable yet.
  Future<bool> notifyWindow(int targetId, T data) async {
    if (!_outgoing.containsKey(targetId)) {
      if (!await connectWindow(targetId)) {
        debugPrint(
            '[IPC:${_wm.id}] notifyWindow($targetId): connect failed, dropping');
        return false;
      }
    }
    try {
      _outgoing[targetId]!.send([_wm.id, data]);
      debugPrint(
          '[IPC:${_wm.id}] notifyWindow($targetId): sent  payload=$data');
      return true;
    } catch (e) {
      debugPrint(
          '[IPC:${_wm.id}] notifyWindow($targetId): send failed ($e), removing dead port');
      _disconnectFrom(targetId);
      return false;
    }
  }

  /// Returns a broadcast [Stream<T>] of messages arriving from [sourceId].
  ///
  /// The stream is created lazily and lives until [dispose] or until [sourceId]
  /// sends a disconnect signal.
  Stream<T> listenWindow(int sourceId) {
    debugPrint('[IPC:${_wm.id}] listenWindow($sourceId): stream requested');
    return _streams
        .putIfAbsent(sourceId, () => StreamController<T>.broadcast())
        .stream;
  }

  /// Releases all resources held by this IPC channel.
  ///
  /// Sends a disconnect signal to all peers, closes the [ReceivePort], removes
  /// the [IsolateNameServer] registration, and unregisters the [WindowListener].
  ///
  /// Call on permanent window close. Do NOT call during reuse-mode hide
  /// (the port stays alive so the window can reconnect after reuse-show).
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    debugPrint('[IPC:${_wm.id}] dispose: notifying peers and cleaning up');
    _notifyAllDisconnect();
    _subscription?.cancel();
    IsolateNameServer.removePortNameMapping('$_kPortPrefix${_wm.id}');
    _port.close();
    _wm.removeListener(this);
  }

  // ---------------------------------------------------------------------------
  // WindowListener
  // ---------------------------------------------------------------------------

  /// Handles the incoming [ipc-connect] handshake from another window.
  @override
  Future<dynamic> onEventFromWindow(
    String method,
    int fromWindowId,
    dynamic arguments,
  ) async {
    debugPrint(
        '[IPC:${_wm.id}] onEventFromWindow: method=$method  from=$fromWindowId  args=$arguments');
    if (method != 'ipc-connect') return null;

    final portName = (arguments as Map?)?['portName'] as String?;
    debugPrint('[IPC:${_wm.id}] ipc-connect: portName=$portName');
    if (portName == null) return null;

    final sp = IsolateNameServer.lookupPortByName(portName);
    debugPrint(
        '[IPC:${_wm.id}] ipc-connect: lookup "$portName" -> ${sp != null ? "found" : "NOT FOUND"}');
    if (sp == null) return null;

    _incoming[fromWindowId] = sp;
    // Auto-populate outgoing so this window can reply without a second handshake.
    _outgoing.putIfAbsent(fromWindowId, () => sp);
    debugPrint(
        '[IPC:${_wm.id}] ipc-connect: window $fromWindowId registered in incoming+outgoing');
    // Notify the app so it can set up stream listeners reactively.
    onConnected?.call(fromWindowId);
    return null;
  }

  /// Detects when THIS window closes or hides via reuse mechanism.
  /// Sends disconnect signal to all peers so they can clean up promptly.
  @override
  void onWindowEvent(String eventName, [int? windowId]) {
    if (windowId != null) return; // global event for another window, ignore
    if (eventName == 'close' || eventName == 'reuse-close') {
      _maybeDisconnectAll(eventName);
    }
  }

  @internal
  Future<void> close(String eventName) async {
    if (_outgoing.isEmpty && _incoming.isEmpty) return;

    debugPrint(
        '[IPC:${_wm.id}] onWindowEvent: $eventName -> disconnecting all peers');
    _notifyAllDisconnect();
  }

  Future<void> _maybeDisconnectAll(String eventName) async {
    if (await _wm.isPreventClose()) return;
    await close(eventName);
  }
}
