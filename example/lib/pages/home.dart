// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:preference_list/preference_list.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:multi_window_manager/multi_window_manager.dart';
import 'package:multi_window_manager_example/utils/config.dart';

// ---------------------------------------------------------------------------
// IPC demo notifiers
// ---------------------------------------------------------------------------

/// Source notifier. Uses [IpcNotifierSender] to broadcast field-level deltas.
/// Simultaneous changes to name AND age are batched into one IPC message.
class _PersonNotifier extends ChangeNotifier with IpcNotifierSender {
  String _name = 'Alice';
  int _age = 30;

  String get name => _name;

  set name(String v) {
    _name = v;
    notifyListeners();
    ipcMark('name', v);
  }

  int get age => _age;

  set age(int v) {
    _age = v;
    notifyListeners();
    ipcMark('age', v);
  }
}

/// Receiver notifier. Uses [IpcNotifierReceiver] to apply incoming deltas.
/// [notifyListeners] is called once per batch regardless of field count.
class _PersonReceiverNotifier extends ChangeNotifier with IpcNotifierReceiver {
  String name = 'not connected';
  int age = 0;

  @override
  void ipcApplyField(String field, Object? value) {
    switch (field) {
      case 'name':
        name = value as String;
      case 'age':
        age = value as int;
    }
  }

  @override
  void dispose() {
    ipcCancelListeners();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------

const _kSizes = [
  Size(400, 400),
  Size(600, 600),
  Size(800, 800),
];

const _kMinSizes = [
  Size(400, 400),
  Size(600, 600),
];

const _kMaxSizes = [
  Size(600, 600),
  Size(800, 800),
];

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

const _kIconTypeDefault = 'default';
const _kIconTypeOriginal = 'original';

class _HomePageState extends State<HomePage> with TrayListener, WindowListener {
  // Mixin approach
  final _PersonNotifier _personSender = _PersonNotifier();
  final _PersonReceiverNotifier _personReceiver = _PersonReceiverNotifier();

  // Raw approach
  final Map<int, StreamSubscription<List<Object?>>> _rawSubs = {};
  List<Object?> _lastRawPayload = [];
  int _rawSendCounter = 0;

  // invokeMethodToWindow demo
  String _invokeLastReceived = '';
  String _invokeLastResponse = '';

  // Benchmarks
  bool _benchRunning = false;

  // IPC bench — sender side
  String _ipcBenchSendResult = '';

  // IPC bench — receiver side
  int _ipcBenchRecvCount = 0;
  String _ipcBenchRecvResult = '';
  Stopwatch? _ipcBenchRecvWatch;
  Timer? _ipcBenchRecvTimer;

  // Invoke bench — sender side
  String _invokeBenchSendResult = '';

  // Invoke bench — receiver side
  int _invokeBenchRecvCount = 0;
  String _invokeBenchRecvResult = '';
  Stopwatch? _invokeBenchRecvWatch;
  Timer? _invokeBenchRecvTimer;

  // ---------------------------------------------------------------------------

  bool _isPreventClose = false;
  Size _size = _kSizes.first;
  Size? _minSize;
  Size? _maxSize;
  bool _isFullScreen = false;
  bool _isResizable = true;
  bool _isMovable = true;
  bool _isMinimizable = true;
  bool _isMaximizable = true;
  bool _isClosable = true;
  bool _isAlwaysOnTop = false;
  bool _isAlwaysOnBottom = false;
  bool _isSkipTaskbar = false;
  double _progress = 0;
  bool _hasShadow = true;
  double _opacity = 1;
  bool _isIgnoreMouseEvents = false;
  String _iconType = _kIconTypeOriginal;
  bool _isVisibleOnAllWorkspaces = false;

  final TextEditingController _methodNameController =
      TextEditingController(text: 'testMethodName');
  final TextEditingController _firstArgController = TextEditingController();

  @override
  void initState() {
    trayManager.addListener(this);
    MultiWindowManager.current.addListener(this);
    // MultiWindowManager.addGlobalListener(this);
    final ipc = MultiWindowManager.current.ipc;
    _personSender.ipcSetup(ipc, 'person');
    _personReceiver.addListener(() {
      if (mounted) setState(() {});
    });

    // When another window connects TO us, reactively set up our receiver
    // and raw listener for that window.
    ipc.onConnected = (int fromId) {
      debugPrint(
          '[Demo:${MultiWindowManager.current.id}] onConnected from $fromId -> setting up listeners');
      _personReceiver.ipcListen(ipc, fromId, 'person');
      _rawSubs[fromId] = ipc.listenWindow(fromId).listen((payload) {
        // Route bench messages to the bench counter, everything else to lastRaw.
        if (payload.isNotEmpty && payload[0] == 'bench_ipc') {
          _onIpcBenchMessage(payload);
        } else {
          final nowMs = DateTime.now().microsecondsSinceEpoch;
          int? ts;
          int? diff;
          if (payload.contains('ts')) {
            final tsIndex = payload.indexOf('ts');
            ts = payload[tsIndex + 1] as int;
          }
          if (ts != null) {
            diff = nowMs - ts;
          }
          setState(
              () => _lastRawPayload = [...payload, 'diff', diff, 'now', nowMs]);
        }
      });
      if (mounted) setState(() {});
    };

    ipc.onDisconnected = (int fromId) {
      debugPrint(
          '[Demo:${MultiWindowManager.current.id}] onDisconnected from $fromId');
      _rawSubs.remove(fromId)?.cancel();
      if (mounted) setState(() {});
    };
    _init();
    super.initState();
  }

  @override
  void dispose() {
    _ipcBenchRecvTimer?.cancel();
    _invokeBenchRecvTimer?.cancel();
    _personSender.dispose();
    _personReceiver.dispose();
    for (final sub in _rawSubs.values) {
      sub.cancel();
    }
    // ipc lifetime is managed by MultiWindowManager — no dispose needed here.
    _methodNameController.dispose();
    _firstArgController.dispose();
    trayManager.removeListener(this);
    MultiWindowManager.current.removeListener(this);
    // MultiWindowManager.removeGlobalListener(this);
    super.dispose();
  }

  Future<void> _init() async {
    await trayManager.setIcon(
      Platform.isWindows
          ? 'images/tray_icon_original.ico'
          : 'images/tray_icon_original.png',
    );
    Menu menu = Menu(
      items: [
        MenuItem(
          key: 'show_window',
          label: 'Show Window',
        ),
        MenuItem(
          key: 'set_ignore_mouse_events',
          label: 'setIgnoreMouseEvents(false)',
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'exit_app',
          label: 'Exit App',
        ),
      ],
    );
    await trayManager.setContextMenu(menu);
    setState(() {});
  }

  Future<void> _handleSetIcon(String iconType) async {
    _iconType = iconType;
    String iconPath =
        Platform.isWindows ? 'images/tray_icon.ico' : 'images/tray_icon.png';

    if (_iconType == 'original') {
      iconPath = Platform.isWindows
          ? 'images/tray_icon_original.ico'
          : 'images/tray_icon_original.png';
    }

    await MultiWindowManager.current.setIcon(iconPath);
  }

  /// Connects this window to [targetId].
  ///
  /// After this call this window can send IPC messages to [targetId].
  /// The target window's [onConnected] callback fires on the OTHER side,
  /// setting up its receiver listeners reactively. Idempotent.
  Future<void> _ipcConnect(int targetId) async {
    final ipc = MultiWindowManager.current.ipc;
    if (ipc.connectedWindowIds.contains(targetId)) {
      BotToast.showText(text: 'IPC: already connected to $targetId');
      return;
    }
    final ok = await ipc.connectWindow(targetId);
    if (!ok) {
      BotToast.showText(text: 'IPC: window $targetId not ready');
      return;
    }

    // Set up THIS window's receiver to also listen FROM the target window,
    // so that updates sent by targetId are reflected here as well.
    _personReceiver.ipcListen(ipc, targetId, 'person');
    _rawSubs[targetId] = ipc.listenWindow(targetId).listen((payload) {
      if (payload.isNotEmpty && payload[0] == 'bench_ipc') {
        _onIpcBenchMessage(payload);
      } else {
        setState(() => _lastRawPayload = payload);
      }
    });

    setState(() {});
    BotToast.showText(text: 'IPC: connected to window $targetId');
  }

  // ---------------------------------------------------------------------------
  // Benchmark helpers
  // ---------------------------------------------------------------------------

  static String _fmtRate(int count, int elapsedMs) {
    if (elapsedMs == 0) return '$count msgs in <1ms';
    final rate = (count * 1000 / elapsedMs).round();
    return '$count msgs in ${elapsedMs}ms  ($rate msg/s)';
  }

  /// Called on the RECEIVER side for every IPC bench message.
  void _onIpcBenchMessage(List<Object?> msg) {
    _ipcBenchRecvCount++;
    _ipcBenchRecvWatch ??= Stopwatch()..start();
    // Finalize 300ms after the last message.
    _ipcBenchRecvTimer?.cancel();
    _ipcBenchRecvTimer = Timer(const Duration(milliseconds: 300), () {
      final ms = _ipcBenchRecvWatch!.elapsedMilliseconds;
      if (mounted) {
        setState(() {
          _ipcBenchRecvResult = _fmtRate(_ipcBenchRecvCount, ms);
          _ipcBenchRecvCount = 0;
          _ipcBenchRecvWatch = null;
        });
      }
    });
  }

  /// Called on the RECEIVER side for every invoke bench call.
  void _onInvokeBenchReceived() {
    _invokeBenchRecvCount++;
    _invokeBenchRecvWatch ??= Stopwatch()..start();
    _invokeBenchRecvTimer?.cancel();
    _invokeBenchRecvTimer = Timer(const Duration(milliseconds: 300), () {
      final ms = _invokeBenchRecvWatch!.elapsedMilliseconds;
      if (mounted) {
        setState(() {
          _invokeBenchRecvResult = _fmtRate(_invokeBenchRecvCount, ms);
          _invokeBenchRecvCount = 0;
          _invokeBenchRecvWatch = null;
        });
      }
    });
  }

  /// IPC bench: fire [n] messages without awaiting — measures raw send throughput.
  Future<void> _runIpcBench(int n) async {
    final ipc = MultiWindowManager.current.ipc;
    if (ipc.connectedWindowIds.isEmpty) {
      BotToast.showText(text: 'IPC bench: connect to a window first');
      return;
    }
    setState(() {
      _benchRunning = true;
      _ipcBenchSendResult = 'sending $n...';
    });
    final sw = Stopwatch()..start();
    for (int i = 0; i < n; i++) {
      for (final id in ipc.connectedWindowIds) {
        // fire-and-forget — no await
        ipc.notifyWindow(id, ['bench_ipc', i]);
      }
    }
    sw.stop();
    setState(() {
      _benchRunning = false;
      _ipcBenchSendResult = 'SEND  ${_fmtRate(n, sw.elapsedMilliseconds)}';
    });
  }

  /// Invoke bench: await each call — measures full round-trip throughput.
  Future<void> _runInvokeBench(int n) async {
    final otherIds = (await MultiWindowManager.current.getActiveWindowIds())
        .where((id) => id != MultiWindowManager.current.id)
        .toList()
      ..sort();
    if (otherIds.isEmpty) {
      BotToast.showText(text: 'Invoke bench: open another window first');
      return;
    }
    final targetId = otherIds.first;
    setState(() {
      _benchRunning = true;
      _invokeBenchSendResult = 'sending $n (await each)...';
    });
    final sw = Stopwatch()..start();
    for (int i = 0; i < n; i++) {
      await MultiWindowManager.current
          .invokeMethodToWindow(targetId, 'bench_invoke', i);
    }
    sw.stop();
    setState(() {
      _benchRunning = false;
      _invokeBenchSendResult = 'SEND  ${_fmtRate(n, sw.elapsedMilliseconds)}';
    });
  }

  Widget _buildBody(BuildContext context) {
    return PreferenceList(
      children: <Widget>[
        PreferenceListSection(
          children: [
            PreferenceListItem(
              title: const Text('ThemeMode'),
              detailText: Text('${sharedConfig.themeMode}'),
              onTap: () async {
                ThemeMode newThemeMode =
                    sharedConfig.themeMode == ThemeMode.light
                        ? ThemeMode.dark
                        : ThemeMode.light;

                await sharedConfigManager.setThemeMode(newThemeMode);
                await MultiWindowManager.current.setBrightness(
                  newThemeMode == ThemeMode.light
                      ? Brightness.light
                      : Brightness.dark,
                );
                setState(() {});
              },
            ),
          ],
        ),
        PreferenceListSection(
          title: const Text('METHODS'),
          children: [
            PreferenceListItem(
              title: const Text('createReusableWindow'),
              onTap: () async {
                final newWindow =
                    await MultiWindowManager.createWindowOrReuse(args: [
                  'test args 1',
                  'test args 2',
                  jsonEncode({'isReusable': true})
                ]);
                BotToast.showText(
                    text: 'New Created or Reused Window: $newWindow');
              },
            ),
            PreferenceListItem(
              title: const Text('createWindow'),
              onTap: () async {
                final newWindow = await MultiWindowManager.createWindow(
                    ['test args 1', 'test args 2']);
                BotToast.showText(text: 'New Created Window: $newWindow');
              },
            ),
            PreferenceListItem(
              title: const Text('getAllWindowManagerIds'),
              onTap: () async {
                final windowManagerIds =
                    await MultiWindowManager.getAllWindowManagerIds();
                BotToast.showText(
                    text: 'WindowManager ID List: $windowManagerIds');
              },
            ),
            PreferenceListItem(
              title: const Text('invokeMethodToWindow'),
              onTap: () async {
                final sortedWindowManagerIds =
                    (await MultiWindowManager.getAllWindowManagerIds())
                        .where((wId) => wId != MultiWindowManager.current.id)
                        .toList();
                sortedWindowManagerIds.sort();
                int? selectedWindowTargetId = await showDialog(
                  context: context,
                  builder: (_) {
                    return AlertDialog(
                      title: const Text(
                          'Select the Target Window to invoke the method'),
                      content: SizedBox(
                        width: 300,
                        height: 300,
                        child: ListView(
                          children: [
                            TextField(
                              controller: _methodNameController,
                              decoration: const InputDecoration(
                                labelText: 'Method name to be invoked',
                              ),
                            ),
                            TextField(
                              controller: _firstArgController,
                              decoration: const InputDecoration(
                                labelText: 'First argument to be passed',
                              ),
                            ),
                            for (var id in sortedWindowManagerIds)
                              ListTile(
                                title: Text('WindowManager ID: $id'),
                                onTap: () {
                                  Navigator.of(context).pop(id);
                                },
                              ),
                          ],
                        ),
                      ),
                      actions: [
                        TextButton(
                          child: const Text('Cancel'),
                          onPressed: () {
                            Navigator.of(context).pop();
                          },
                        ),
                      ],
                    );
                  },
                );

                if (selectedWindowTargetId != null) {
                  final response = await MultiWindowManager.current
                      .invokeMethodToWindow(
                          selectedWindowTargetId,
                          _methodNameController.text,
                          _firstArgController.text.trim().isNotEmpty
                              ? [_firstArgController.text.trim()]
                              : null);
                  BotToast.showText(
                      text: 'Response from $selectedWindowTargetId: $response');
                }
              },
            ),
            PreferenceListItem(
              title: const Text('setAsFrameless'),
              onTap: () async {
                await MultiWindowManager.current.setAsFrameless();
              },
            ),
            PreferenceListItem(
              title: const Text('close'),
              onTap: () async {
                await MultiWindowManager.current.close();
                await Future.delayed(const Duration(seconds: 2));
                await MultiWindowManager.current.show();
              },
            ),
            PreferenceListSwitchItem(
              title: const Text('isPreventClose / setPreventClose'),
              onTap: () async {
                _isPreventClose =
                    await MultiWindowManager.current.isPreventClose();
                BotToast.showText(text: 'isPreventClose: $_isPreventClose');
              },
              value: _isPreventClose,
              onChanged: (newValue) async {
                _isPreventClose = newValue;
                await MultiWindowManager.current
                    .setPreventClose(_isPreventClose);
                setState(() {});
              },
            ),
            PreferenceListItem(
              title: const Text('focus / blur'),
              onTap: () async {
                await MultiWindowManager.current.blur();
                await Future.delayed(const Duration(seconds: 2));
                print(
                    'isFocused: ${await MultiWindowManager.current.isFocused()}');
                await Future.delayed(const Duration(seconds: 2));
                await MultiWindowManager.current.focus();
                await Future.delayed(const Duration(seconds: 2));
                print(
                    'isFocused: ${await MultiWindowManager.current.isFocused()}');
              },
            ),
            PreferenceListItem(
              title: const Text('show / hide'),
              onTap: () async {
                await MultiWindowManager.current.hide();
                await Future.delayed(const Duration(seconds: 2));
                await MultiWindowManager.current.show();
                await MultiWindowManager.current.focus();
              },
            ),
            PreferenceListItem(
              title: const Text('isVisible'),
              onTap: () async {
                bool isVisible = await MultiWindowManager.current.isVisible();
                BotToast.showText(
                  text: 'isVisible: $isVisible',
                );

                await Future.delayed(const Duration(seconds: 2));
                MultiWindowManager.current.hide();
                isVisible = await MultiWindowManager.current.isVisible();
                print('isVisible: $isVisible');
                await Future.delayed(const Duration(seconds: 2));
                MultiWindowManager.current.show();
              },
            ),
            PreferenceListItem(
              title: const Text('isMaximized'),
              onTap: () async {
                bool isMaximized =
                    await MultiWindowManager.current.isMaximized();
                BotToast.showText(
                  text: 'isMaximized: $isMaximized',
                );
              },
            ),
            PreferenceListItem(
              title: const Text('maximize / unmaximize'),
              onTap: () async {
                MultiWindowManager.current.maximize();
                await Future.delayed(const Duration(seconds: 2));
                MultiWindowManager.current.unmaximize();
              },
            ),
            PreferenceListItem(
              title: const Text('isMinimized'),
              onTap: () async {
                bool isMinimized =
                    await MultiWindowManager.current.isMinimized();
                BotToast.showText(
                  text: 'isMinimized: $isMinimized',
                );

                await Future.delayed(const Duration(seconds: 2));
                MultiWindowManager.current.minimize();
                await Future.delayed(const Duration(seconds: 2));
                isMinimized = await MultiWindowManager.current.isMinimized();
                print('isMinimized: $isMinimized');
                MultiWindowManager.current.restore();
              },
            ),
            PreferenceListItem(
              title: const Text('minimize / restore'),
              onTap: () async {
                MultiWindowManager.current.minimize();
                await Future.delayed(const Duration(seconds: 2));
                MultiWindowManager.current.restore();
              },
            ),
            PreferenceListItem(
              title: const Text('dock / undock'),
              onTap: () async {
                DockSide? isDocked =
                    await MultiWindowManager.current.isDocked();
                BotToast.showText(text: 'isDocked: $isDocked');
              },
              accessoryView: Row(
                children: [
                  CupertinoButton(
                    child: const Text('dock left'),
                    onPressed: () async {
                      MultiWindowManager.current
                          .dock(side: DockSide.left, width: 500);
                    },
                  ),
                  CupertinoButton(
                    child: const Text('dock right'),
                    onPressed: () async {
                      MultiWindowManager.current
                          .dock(side: DockSide.right, width: 500);
                    },
                  ),
                  CupertinoButton(
                    child: const Text('undock'),
                    onPressed: () async {
                      MultiWindowManager.current.undock();
                    },
                  ),
                ],
              ),
            ),
            PreferenceListSwitchItem(
              title: const Text('isFullScreen / setFullScreen'),
              onTap: () async {
                bool isFullScreen =
                    await MultiWindowManager.current.isFullScreen();
                BotToast.showText(text: 'isFullScreen: $isFullScreen');
              },
              value: _isFullScreen,
              onChanged: (newValue) {
                _isFullScreen = newValue;
                MultiWindowManager.current.setFullScreen(_isFullScreen);
                setState(() {});
              },
            ),
            PreferenceListItem(
              title: const Text('setAspectRatio'),
              accessoryView: Row(
                children: [
                  CupertinoButton(
                    child: const Text('reset'),
                    onPressed: () async {
                      MultiWindowManager.current.setAspectRatio(0);
                    },
                  ),
                  CupertinoButton(
                    child: const Text('1:1'),
                    onPressed: () async {
                      MultiWindowManager.current.setAspectRatio(1);
                    },
                  ),
                  CupertinoButton(
                    child: const Text('16:9'),
                    onPressed: () async {
                      MultiWindowManager.current.setAspectRatio(16 / 9);
                    },
                  ),
                  CupertinoButton(
                    child: const Text('4:3'),
                    onPressed: () async {
                      MultiWindowManager.current.setAspectRatio(4 / 3);
                    },
                  ),
                ],
              ),
            ),
            PreferenceListItem(
              title: const Text('setBackgroundColor'),
              accessoryView: Row(
                children: [
                  CupertinoButton(
                    child: const Text('transparent'),
                    onPressed: () async {
                      MultiWindowManager.current
                          .setBackgroundColor(Colors.transparent);
                    },
                  ),
                  CupertinoButton(
                    child: const Text('red'),
                    onPressed: () async {
                      MultiWindowManager.current.setBackgroundColor(Colors.red);
                    },
                  ),
                  CupertinoButton(
                    child: const Text('green'),
                    onPressed: () async {
                      MultiWindowManager.current
                          .setBackgroundColor(Colors.green);
                    },
                  ),
                  CupertinoButton(
                    child: const Text('blue'),
                    onPressed: () async {
                      MultiWindowManager.current
                          .setBackgroundColor(Colors.blue);
                    },
                  ),
                ],
              ),
            ),
            PreferenceListItem(
              title: const Text('setBounds / setBounds'),
              accessoryView: ToggleButtons(
                onPressed: (int index) async {
                  _size = _kSizes[index];
                  Offset newPosition = await calcWindowPosition(
                    _size,
                    Alignment.center,
                  );
                  await MultiWindowManager.current.setBounds(
                    // Rect.fromLTWH(
                    //   bounds.left + 10,
                    //   bounds.top + 10,
                    //   _size.width,
                    //   _size.height,
                    // ),
                    null,
                    position: newPosition,
                    size: _size,
                    animate: true,
                  );
                  setState(() {});
                },
                isSelected: _kSizes.map((e) => e == _size).toList(),
                children: <Widget>[
                  for (var size in _kSizes)
                    Text(' ${size.width.toInt()}x${size.height.toInt()} '),
                ],
              ),
              onTap: () async {
                Rect bounds = await MultiWindowManager.current.getBounds();
                Size size = bounds.size;
                Offset origin = bounds.topLeft;
                BotToast.showText(
                  text: '${size.toString()}\n${origin.toString()}',
                );
              },
            ),
            PreferenceListItem(
              title: const Text('setAlignment'),
              accessoryView: SizedBox(
                width: 300,
                child: Wrap(
                  children: [
                    CupertinoButton(
                      child: const Text('topLeft'),
                      onPressed: () async {
                        await MultiWindowManager.current.setAlignment(
                          Alignment.topLeft,
                          animate: true,
                        );
                      },
                    ),
                    CupertinoButton(
                      child: const Text('topCenter'),
                      onPressed: () async {
                        await MultiWindowManager.current.setAlignment(
                          Alignment.topCenter,
                          animate: true,
                        );
                      },
                    ),
                    CupertinoButton(
                      child: const Text('topRight'),
                      onPressed: () async {
                        await MultiWindowManager.current.setAlignment(
                          Alignment.topRight,
                          animate: true,
                        );
                      },
                    ),
                    CupertinoButton(
                      child: const Text('centerLeft'),
                      onPressed: () async {
                        await MultiWindowManager.current.setAlignment(
                          Alignment.centerLeft,
                          animate: true,
                        );
                      },
                    ),
                    CupertinoButton(
                      child: const Text('center'),
                      onPressed: () async {
                        await MultiWindowManager.current.setAlignment(
                          Alignment.center,
                          animate: true,
                        );
                      },
                    ),
                    CupertinoButton(
                      child: const Text('centerRight'),
                      onPressed: () async {
                        await MultiWindowManager.current.setAlignment(
                          Alignment.centerRight,
                          animate: true,
                        );
                      },
                    ),
                    CupertinoButton(
                      child: const Text('bottomLeft'),
                      onPressed: () async {
                        await MultiWindowManager.current.setAlignment(
                          Alignment.bottomLeft,
                          animate: true,
                        );
                      },
                    ),
                    CupertinoButton(
                      child: const Text('bottomCenter'),
                      onPressed: () async {
                        await MultiWindowManager.current.setAlignment(
                          Alignment.bottomCenter,
                          animate: true,
                        );
                      },
                    ),
                    CupertinoButton(
                      child: const Text('bottomRight'),
                      onPressed: () async {
                        await MultiWindowManager.current.setAlignment(
                          Alignment.bottomRight,
                          animate: true,
                        );
                      },
                    ),
                  ],
                ),
              ),
              onTap: () async {},
            ),
            PreferenceListItem(
              title: const Text('center'),
              onTap: () async {
                await MultiWindowManager.current.center();
              },
            ),
            PreferenceListItem(
              title: const Text('getPosition / setPosition'),
              accessoryView: Row(
                children: [
                  CupertinoButton(
                    child: const Text('xy>zero'),
                    onPressed: () async {
                      MultiWindowManager.current
                          .setPosition(const Offset(0, 0));
                      setState(() {});
                    },
                  ),
                  CupertinoButton(
                    child: const Text('x+20'),
                    onPressed: () async {
                      Offset p = await MultiWindowManager.current.getPosition();
                      MultiWindowManager.current
                          .setPosition(Offset(p.dx + 20, p.dy));
                      setState(() {});
                    },
                  ),
                  CupertinoButton(
                    child: const Text('x-20'),
                    onPressed: () async {
                      Offset p = await MultiWindowManager.current.getPosition();
                      MultiWindowManager.current
                          .setPosition(Offset(p.dx - 20, p.dy));
                      setState(() {});
                    },
                  ),
                  CupertinoButton(
                    child: const Text('y+20'),
                    onPressed: () async {
                      Offset p = await MultiWindowManager.current.getPosition();
                      MultiWindowManager.current
                          .setPosition(Offset(p.dx, p.dy + 20));
                      setState(() {});
                    },
                  ),
                  CupertinoButton(
                    child: const Text('y-20'),
                    onPressed: () async {
                      Offset p = await MultiWindowManager.current.getPosition();
                      MultiWindowManager.current
                          .setPosition(Offset(p.dx, p.dy - 20));
                      setState(() {});
                    },
                  ),
                ],
              ),
              onTap: () async {
                Offset position =
                    await MultiWindowManager.current.getPosition();
                BotToast.showText(
                  text: position.toString(),
                );
              },
            ),
            PreferenceListItem(
              title: const Text('getSize / setSize'),
              accessoryView: CupertinoButton(
                child: const Text('Set'),
                onPressed: () async {
                  Size size = await MultiWindowManager.current.getSize();
                  MultiWindowManager.current.setSize(
                    Size(size.width + 100, size.height + 100),
                  );
                  setState(() {});
                },
              ),
              onTap: () async {
                Size size = await MultiWindowManager.current.getSize();
                BotToast.showText(
                  text: size.toString(),
                );
              },
            ),
            PreferenceListItem(
              title: const Text('getMinimumSize / setMinimumSize'),
              accessoryView: ToggleButtons(
                onPressed: (int index) {
                  _minSize = _kMinSizes[index];
                  MultiWindowManager.current.setMinimumSize(_minSize!);
                  setState(() {});
                },
                isSelected: _kMinSizes.map((e) => e == _minSize).toList(),
                children: <Widget>[
                  for (var size in _kMinSizes)
                    Text(' ${size.width.toInt()}x${size.height.toInt()} '),
                ],
              ),
            ),
            PreferenceListItem(
              title: const Text('getMaximumSize / setMaximumSize'),
              accessoryView: ToggleButtons(
                onPressed: (int index) {
                  _maxSize = _kMaxSizes[index];
                  MultiWindowManager.current.setMaximumSize(_maxSize!);
                  setState(() {});
                },
                isSelected: _kMaxSizes.map((e) => e == _maxSize).toList(),
                children: <Widget>[
                  for (var size in _kMaxSizes)
                    Text(' ${size.width.toInt()}x${size.height.toInt()} '),
                ],
              ),
            ),
            PreferenceListSwitchItem(
              title: const Text('isResizable / setResizable'),
              onTap: () async {
                bool isResizable =
                    await MultiWindowManager.current.isResizable();
                BotToast.showText(text: 'isResizable: $isResizable');
              },
              value: _isResizable,
              onChanged: (newValue) {
                _isResizable = newValue;
                MultiWindowManager.current.setResizable(_isResizable);
                setState(() {});
              },
            ),
            PreferenceListSwitchItem(
              title: const Text('isMovable / setMovable'),
              onTap: () async {
                bool isMovable = await MultiWindowManager.current.isMovable();
                BotToast.showText(text: 'isMovable: $isMovable');
              },
              value: _isMovable,
              onChanged: (newValue) {
                _isMovable = newValue;
                MultiWindowManager.current.setMovable(_isMovable);
                setState(() {});
              },
            ),
            PreferenceListSwitchItem(
              title: const Text('isMinimizable / setMinimizable'),
              onTap: () async {
                _isMinimizable =
                    await MultiWindowManager.current.isMinimizable();
                setState(() {});
                BotToast.showText(text: 'isMinimizable: $_isMinimizable');
              },
              value: _isMinimizable,
              onChanged: (newValue) async {
                await MultiWindowManager.current.setMinimizable(newValue);
                _isMinimizable =
                    await MultiWindowManager.current.isMinimizable();
                print('isMinimizable: $_isMinimizable');
                setState(() {});
              },
            ),
            PreferenceListSwitchItem(
              title: const Text('isMaximizable / setMaximizable'),
              onTap: () async {
                _isMaximizable =
                    await MultiWindowManager.current.isMaximizable();
                setState(() {});
                BotToast.showText(text: 'isClosable: $_isMaximizable');
              },
              value: _isMaximizable,
              onChanged: (newValue) async {
                await MultiWindowManager.current.setMaximizable(newValue);
                _isMaximizable =
                    await MultiWindowManager.current.isMaximizable();
                print('isMaximizable: $_isMaximizable');
                setState(() {});
              },
            ),
            PreferenceListSwitchItem(
              title: const Text('isClosable / setClosable'),
              onTap: () async {
                _isClosable = await MultiWindowManager.current.isClosable();
                setState(() {});
                BotToast.showText(text: 'isClosable: $_isClosable');
              },
              value: _isClosable,
              onChanged: (newValue) async {
                await MultiWindowManager.current.setClosable(newValue);
                _isClosable = await MultiWindowManager.current.isClosable();
                print('isClosable: $_isClosable');
                setState(() {});
              },
            ),
            PreferenceListSwitchItem(
              title: const Text('isAlwaysOnTop / setAlwaysOnTop'),
              onTap: () async {
                bool isAlwaysOnTop =
                    await MultiWindowManager.current.isAlwaysOnTop();
                BotToast.showText(text: 'isAlwaysOnTop: $isAlwaysOnTop');
              },
              value: _isAlwaysOnTop,
              onChanged: (newValue) {
                _isAlwaysOnTop = newValue;
                MultiWindowManager.current.setAlwaysOnTop(_isAlwaysOnTop);
                setState(() {});
              },
            ),
            PreferenceListSwitchItem(
              title: const Text('isAlwaysOnBottom / setAlwaysOnBottom'),
              onTap: () async {
                bool isAlwaysOnBottom =
                    await MultiWindowManager.current.isAlwaysOnBottom();
                BotToast.showText(text: 'isAlwaysOnBottom: $isAlwaysOnBottom');
              },
              value: _isAlwaysOnBottom,
              onChanged: (newValue) async {
                _isAlwaysOnBottom = newValue;
                await MultiWindowManager.current
                    .setAlwaysOnBottom(_isAlwaysOnBottom);
                setState(() {});
              },
            ),
            PreferenceListItem(
              title: const Text('getTitle / setTitle'),
              onTap: () async {
                String title = await MultiWindowManager.current.getTitle();
                BotToast.showText(
                  text: title.toString(),
                );
                title =
                    'Window ID ${MultiWindowManager.current.id} - ${DateTime.now().microsecondsSinceEpoch}';
                await MultiWindowManager.current.setTitle(title);
              },
            ),
            PreferenceListItem(
              title: const Text('setTitleBarStyle'),
              accessoryView: Row(
                children: [
                  CupertinoButton(
                    child: const Text('normal'),
                    onPressed: () async {
                      MultiWindowManager.current.setTitleBarStyle(
                        TitleBarStyle.normal,
                        windowButtonVisibility: true,
                      );
                      setState(() {});
                    },
                  ),
                  CupertinoButton(
                    child: const Text('hidden'),
                    onPressed: () async {
                      MultiWindowManager.current.setTitleBarStyle(
                        TitleBarStyle.hidden,
                        windowButtonVisibility: false,
                      );
                      setState(() {});
                    },
                  ),
                ],
              ),
              onTap: () {},
            ),
            PreferenceListItem(
              title: const Text('getTitleBarHeight'),
              onTap: () async {
                int titleBarHeight =
                    await MultiWindowManager.current.getTitleBarHeight();
                BotToast.showText(
                  text: 'titleBarHeight: $titleBarHeight',
                );
              },
            ),
            PreferenceListItem(
              title: const Text('isSkipTaskbar'),
              onTap: () async {
                bool isSkipping =
                    await MultiWindowManager.current.isSkipTaskbar();
                BotToast.showText(
                  text: 'isSkipTaskbar: $isSkipping',
                );
              },
            ),
            PreferenceListItem(
              title: const Text('setSkipTaskbar'),
              onTap: () async {
                setState(() {
                  _isSkipTaskbar = !_isSkipTaskbar;
                });
                await MultiWindowManager.current.setSkipTaskbar(_isSkipTaskbar);
                await Future.delayed(const Duration(seconds: 3));
                MultiWindowManager.current.show();
              },
            ),
            PreferenceListItem(
              title: const Text('setProgressBar'),
              onTap: () async {
                for (var i = 0; i <= 100; i++) {
                  setState(() {
                    _progress = i / 100;
                  });
                  print(_progress);
                  await MultiWindowManager.current.setProgressBar(_progress);
                  await Future.delayed(const Duration(milliseconds: 100));
                }
                await Future.delayed(const Duration(milliseconds: 1000));
                await MultiWindowManager.current.setProgressBar(-1);
              },
            ),
            PreferenceListItem(
              title: const Text('setIcon'),
              accessoryView: Row(
                children: [
                  CupertinoButton(
                    child: const Text('Default'),
                    onPressed: () => _handleSetIcon(_kIconTypeDefault),
                  ),
                  CupertinoButton(
                    child: const Text('Original'),
                    onPressed: () => _handleSetIcon(_kIconTypeOriginal),
                  ),
                ],
              ),
              onTap: () => _handleSetIcon(_kIconTypeDefault),
            ),
            PreferenceListSwitchItem(
              title: const Text(
                'isVisibleOnAllWorkspaces / setVisibleOnAllWorkspaces',
              ),
              onTap: () async {
                bool isVisibleOnAllWorkspaces =
                    await MultiWindowManager.current.isVisibleOnAllWorkspaces();
                BotToast.showText(
                  text: 'isVisibleOnAllWorkspaces: $isVisibleOnAllWorkspaces',
                );
              },
              value: _isVisibleOnAllWorkspaces,
              onChanged: (newValue) {
                _isVisibleOnAllWorkspaces = newValue;
                MultiWindowManager.current.setVisibleOnAllWorkspaces(
                  _isVisibleOnAllWorkspaces,
                  visibleOnFullScreen: _isVisibleOnAllWorkspaces,
                );
                setState(() {});
              },
            ),
            PreferenceListItem(
              title: const Text('setBadgeLabel'),
              accessoryView: Row(
                children: [
                  CupertinoButton(
                    child: const Text('null'),
                    onPressed: () async {
                      await MultiWindowManager.current.setBadgeLabel();
                    },
                  ),
                  CupertinoButton(
                    child: const Text('99+'),
                    onPressed: () async {
                      await MultiWindowManager.current.setBadgeLabel('99+');
                    },
                  ),
                ],
              ),
              onTap: () => _handleSetIcon(_kIconTypeDefault),
            ),
            PreferenceListSwitchItem(
              title: const Text('hasShadow / setHasShadow'),
              onTap: () async {
                bool hasShadow = await MultiWindowManager.current.hasShadow();
                BotToast.showText(
                  text: 'hasShadow: $hasShadow',
                );
              },
              value: _hasShadow,
              onChanged: (newValue) {
                _hasShadow = newValue;
                MultiWindowManager.current.setHasShadow(_hasShadow);
                setState(() {});
              },
            ),
            PreferenceListItem(
              title: const Text('getOpacity / setOpacity'),
              onTap: () async {
                double opacity = await MultiWindowManager.current.getOpacity();
                BotToast.showText(
                  text: 'opacity: $opacity',
                );
              },
              accessoryView: Row(
                children: [
                  CupertinoButton(
                    child: const Text('1'),
                    onPressed: () async {
                      _opacity = 1;
                      MultiWindowManager.current.setOpacity(_opacity);
                      setState(() {});
                    },
                  ),
                  CupertinoButton(
                    child: const Text('0.8'),
                    onPressed: () async {
                      _opacity = 0.8;
                      MultiWindowManager.current.setOpacity(_opacity);
                      setState(() {});
                    },
                  ),
                  CupertinoButton(
                    child: const Text('0.6'),
                    onPressed: () async {
                      _opacity = 0.5;
                      MultiWindowManager.current.setOpacity(_opacity);
                      setState(() {});
                    },
                  ),
                ],
              ),
            ),
            PreferenceListSwitchItem(
              title: const Text('setIgnoreMouseEvents'),
              value: _isIgnoreMouseEvents,
              onChanged: (newValue) async {
                _isIgnoreMouseEvents = newValue;
                await MultiWindowManager.current.setIgnoreMouseEvents(
                  _isIgnoreMouseEvents,
                  forward: false,
                );
                setState(() {});
              },
            ),
            PreferenceListItem(
              title: const Text('popUpWindowMenu'),
              onTap: () async {
                await MultiWindowManager.current.popUpWindowMenu();
              },
            ),
            // PreferenceListItem(
            //   title: const Text('grabKeyboard'),
            //   onTap: () async {
            //     await MultiWindowManager.current.grabKeyboard();
            //   },
            // ),
            // PreferenceListItem(
            //   title: const Text('ungrabKeyboard'),
            //   onTap: () async {
            //     await MultiWindowManager.current.ungrabKeyboard();
            //   },
            // ),
          ],
        ),

        // -----------------------------------------------------------------
        // invokeMethodToWindow section
        // -----------------------------------------------------------------
        PreferenceListSection(
          title: const Text('invokeMethodToWindow'),
          children: [
            // Send
            PreferenceListItem(
              title: const Text('Send: invoke method on another window'),
              detailText: Text(
                _invokeLastResponse.isEmpty
                    ? 'tap to select target and send'
                    : 'last response: $_invokeLastResponse',
              ),
              onTap: () async {
                final otherIds = (await MultiWindowManager.current
                        .getActiveWindowIds())
                    .where((id) => id != MultiWindowManager.current.id)
                    .toList()
                  ..sort();
                if (otherIds.isEmpty) {
                  BotToast.showText(text: 'No other windows open');
                  return;
                }
                final selected = await showDialog<int>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('Select target window'),
                    content: SizedBox(
                      width: 260,
                      height: 200,
                      child: ListView(
                        children: [
                          for (final id in otherIds)
                            ListTile(
                              title: Text('Window $id'),
                              onTap: () => Navigator.of(context).pop(id),
                            ),
                        ],
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Cancel'),
                      ),
                    ],
                  ),
                );
                if (selected == null) return;
                final response = await MultiWindowManager.current
                    .invokeMethodToWindow(selected, 'greet', {
                  'from': MultiWindowManager.current.id,
                  'ts': DateTime.now().microsecondsSinceEpoch,
                });
                setState(() => _invokeLastResponse = '$response');
                BotToast.showText(text: 'Response from $selected: $response');
              },
            ),

            // Received
            PreferenceListItem(
              title: const Text('Received: last invocation on this window'),
              detailText: Text(
                _invokeLastReceived.isEmpty
                    ? 'nothing yet'
                    : _invokeLastReceived,
              ),
              onTap: () {},
            ),
          ],
        ),

        // -----------------------------------------------------------------
        // IPC section
        // -----------------------------------------------------------------
        PreferenceListSection(
          title: const Text('IPC'),
          children: [
            // --- Connection -----------------------------------------------
            PreferenceListItem(
              title: const Text('connectWindow'),
              detailText: Text(
                MultiWindowManager.current.ipc.connectedWindowIds.isEmpty
                    ? 'not connected'
                    : 'connected: ${MultiWindowManager.current.ipc.connectedWindowIds}',
              ),
              onTap: () async {
                final otherIds = (await MultiWindowManager.current
                        .getActiveWindowIds())
                    .where((id) => id != MultiWindowManager.current.id)
                    .toList()
                  ..sort();
                if (otherIds.isEmpty) {
                  BotToast.showText(text: 'No other windows open');
                  return;
                }
                final selected = await showDialog<int>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('Select window to connect IPC'),
                    content: SizedBox(
                      width: 260,
                      height: 200,
                      child: ListView(
                        children: [
                          for (final id in otherIds)
                            ListTile(
                              title: Text('Window $id'),
                              onTap: () => Navigator.of(context).pop(id),
                            ),
                        ],
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Cancel'),
                      ),
                    ],
                  ),
                );
                if (selected != null) await _ipcConnect(selected);
              },
            ),

            // --- Mixin approach -------------------------------------------
            PreferenceListItem(
              title: const Text('[Mixin] Send person update'),
              detailText: Text(
                'sending  name=${_personSender.name}  age=${_personSender.age}',
              ),
              onTap: () {
                if (MultiWindowManager.current.ipc.connectedWindowIds.isEmpty) {
                  BotToast.showText(text: 'IPC: connect to a window first');
                  return;
                }
                // Both fields change synchronously -> one batched IPC message.
                _personSender.name = 'User_${DateTime.now().second}';
                _personSender.age = 20 + DateTime.now().millisecond % 40;
                setState(() {});
              },
            ),
            PreferenceListItem(
              title: const Text('[Mixin] Received person'),
              detailText: Text(
                'name=${_personReceiver.name}  age=${_personReceiver.age}',
              ),
              onTap: () {},
            ),

            // --- Raw approach ---------------------------------------------
            PreferenceListItem(
              title: const Text('[Raw] Send counter + timestamp'),
              detailText: Text('counter: $_rawSendCounter'),
              onTap: () async {
                final ipc = MultiWindowManager.current.ipc;
                if (ipc.connectedWindowIds.isEmpty) {
                  BotToast.showText(text: 'IPC: connect to a window first');
                  return;
                }
                _rawSendCounter++;
                // Wire format: ['raw', field1, val1, field2, val2, ...]
                // 'raw' is the topic; the rest are arbitrary key-value pairs.
                final payload = <Object?>[
                  'raw',
                  'counter',
                  _rawSendCounter,
                  'ts',
                  DateTime.now().microsecondsSinceEpoch,
                ];
                for (final id in ipc.connectedWindowIds) {
                  await ipc.notifyWindow(id, payload);
                }
                setState(() {});
              },
            ),
            PreferenceListItem(
              title: const Text('[Raw] Last received'),
              detailText: Text(
                _lastRawPayload.isEmpty ? 'nothing yet' : '$_lastRawPayload',
              ),
              onTap: () {},
            ),
          ],
        ),

        // -----------------------------------------------------------------
        // Benchmark section — IPC vs invokeMethodToWindow throughput
        // -----------------------------------------------------------------
        PreferenceListSection(
          title: const Text('BENCHMARK: IPC vs invokeMethodToWindow'),
          children: [
            // --- IPC (fire-and-forget) ------------------------------------
            PreferenceListItem(
              title: const Text('[IPC] Send 1 000 messages (fire-and-forget)'),
              detailText: Text(
                _ipcBenchSendResult.isEmpty
                    ? 'tap to run'
                    : _ipcBenchSendResult,
              ),
              accessoryView: _benchRunning
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : null,
              onTap: _benchRunning ? null : () => _runIpcBench(1000),
            ),
            PreferenceListItem(
              title: const Text('[IPC] Received'),
              detailText: Text(
                _ipcBenchRecvResult.isEmpty
                    ? 'nothing yet'
                    : _ipcBenchRecvResult,
              ),
              onTap: () {},
            ),

            // --- invokeMethodToWindow (await each) ------------------------
            PreferenceListItem(
              title: const Text('[Invoke] Send 1000 messages (await each)'),
              detailText: Text(
                _invokeBenchSendResult.isEmpty
                    ? 'tap to run (slower — awaits response per call)'
                    : _invokeBenchSendResult,
              ),
              accessoryView: _benchRunning
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : null,
              onTap: _benchRunning ? null : () => _runInvokeBench(1000),
            ),
            PreferenceListItem(
              title: const Text('[Invoke] Received'),
              detailText: Text(
                _invokeBenchRecvResult.isEmpty
                    ? 'nothing yet'
                    : _invokeBenchRecvResult,
              ),
              onTap: () {},
            ),
          ],
        ),
      ],
    );
  }

  Widget _build(BuildContext context) {
    return Stack(
      children: [
        Container(
          margin: const EdgeInsets.all(0),
          decoration: const BoxDecoration(
            color: Colors.white,
            // border: Border.all(color: Colors.grey.withOpacity(0.4), width: 1),
            // boxShadow: <BoxShadow>[
            //   BoxShadow(
            //     color: Colors.black.withOpacity(0.2),
            //     offset: Offset(1.0, 1.0),
            //     blurRadius: 6.0,
            //   ),
            // ],
          ),
          child: Scaffold(
            appBar: _isFullScreen
                ? null
                : PreferredSize(
                    preferredSize: const Size.fromHeight(kWindowCaptionHeight),
                    child: WindowCaption(
                      brightness: Theme.of(context).brightness,
                      title: Text('Window ID ${MultiWindowManager.current.id}'),
                    ),
                  ),
            body: Column(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onPanStart: (details) {
                    MultiWindowManager.current.startDragging();
                  },
                  onDoubleTap: () async {
                    bool isMaximized =
                        await MultiWindowManager.current.isMaximized();
                    if (!isMaximized) {
                      MultiWindowManager.current.maximize();
                    } else {
                      MultiWindowManager.current.unmaximize();
                    }
                  },
                  child: Container(
                    margin: const EdgeInsets.all(0),
                    width: double.infinity,
                    height: 54,
                    color: Colors.grey.withOpacity(0.3),
                    child: const Center(
                      child: Text('DragToMoveArea'),
                    ),
                  ),
                ),
                if (Platform.isLinux || Platform.isWindows)
                  Container(
                    height: 100,
                    margin: const EdgeInsets.all(20),
                    child: DragToResizeArea(
                      resizeEdgeSize: 6,
                      resizeEdgeColor: Colors.red.withOpacity(0.2),
                      child: Container(
                        width: double.infinity,
                        height: double.infinity,
                        color: Colors.grey.withOpacity(0.3),
                        child: Center(
                          child: GestureDetector(
                            child: const Text('DragToResizeArea'),
                            onTap: () {
                              BotToast.showText(
                                text: 'DragToResizeArea example',
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                Expanded(
                  child: _buildBody(context),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) {
        if (_isIgnoreMouseEvents) {
          MultiWindowManager.current.setOpacity(1.0);
        }
      },
      onExit: (_) {
        if (_isIgnoreMouseEvents) {
          MultiWindowManager.current.setOpacity(0.5);
        }
      },
      child: _build(context),
    );
  }

  @override
  void onTrayIconMouseDown() {
    MultiWindowManager.current.show();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  Future<void> onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'show_window':
        await MultiWindowManager.current.focus();
        break;
      case 'set_ignore_mouse_events':
        _isIgnoreMouseEvents = false;
        await MultiWindowManager.current
            .setIgnoreMouseEvents(_isIgnoreMouseEvents);
        setState(() {});
        break;
    }
  }

  @override
  void onWindowFocus([int? windowId]) {
    if (windowId != null) {
      return;
    }
    setState(() {});
  }

  @override
  void onWindowClose([int? windowId]) {
    debugPrint('close, id: $windowId');
    if (windowId != null) {
      return;
    }
    if (_isPreventClose) {
      showDialog(
        context: context,
        builder: (_) {
          return AlertDialog(
            title: const Text('Are you sure you want to close this window?'),
            actions: [
              TextButton(
                child: const Text('No'),
                onPressed: () {
                  Navigator.of(context).pop();
                },
              ),
              TextButton(
                child: const Text('Yes'),
                onPressed: () async {
                  await MultiWindowManager.current.setPreventClose(false);
                  Navigator.of(context).pop();
                  MultiWindowManager.current.close();
                },
              ),
            ],
          );
        },
      );
    }
  }

  @override
  void onWindowEvent(String eventName, [int? windowId]) {
    print(
        '[${windowId != null ? "Global Event for Window $windowId from ${MultiWindowManager.current}" : MultiWindowManager.current}] onWindowEvent: $eventName');
  }

  @override
  Future<dynamic> onEventFromWindow(
      String eventName, int fromWindowId, dynamic arguments) async {
    if (eventName == 'bench_invoke') {
      // Bench message: count only, no toast or setState to avoid UI overhead.
      _onInvokeBenchReceived();
      return 'ok';
    }
    final msg = 'method=$eventName  from=$fromWindowId  args=$arguments';
    BotToast.showText(text: '[${MultiWindowManager.current}] $msg');
    if (mounted) {
      setState(() => _invokeLastReceived = msg);
    }
    return 'Hello from window ${MultiWindowManager.current.id}';
  }
}
