import 'dart:convert';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:multi_window_manager/multi_window_manager.dart';
import 'package:multi_window_manager_example/pages/home.dart';
import 'package:multi_window_manager_example/utils/config.dart';

void main(List<String> args) async {
  if (kDebugMode) {
    print(args);
  }

  WidgetsFlutterBinding.ensureInitialized();

  final windowId = args.isEmpty ? 0 : int.tryParse(args[0]) ?? 0;
  final Map<String, dynamic> argsMap =
      args.isEmpty ? {} : {'arg1': args[1], 'arg2': args[2]};
  final isReusable =
      args.length > 3 ? jsonDecode(args[3])['isReusable'] : false;
  windowId == 0
      ? await MultiWindowManager.ensureInitialized(windowId)
      : await MultiWindowManager.ensureInitializedSecondary(
          windowId,
          isEnabledReuse: isReusable,
        );

  WindowOptions windowOptions = WindowOptions(
    size: const Size(800, 600),
    center: true,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: false,
    title: 'Window ID ${MultiWindowManager.current.id}',
  );
  MultiWindowManager.current.waitUntilReadyToShow(windowOptions, () async {
    await MultiWindowManager.current.show();
    await MultiWindowManager.current.focus();
  });

  runApp(MyApp(
    isSecondary: windowId != 0,
    args: argsMap,
  ));
}

class MyApp extends StatefulWidget {
  const MyApp({super.key, required this.isSecondary, required this.args});

  final Map<String, dynamic> args;
  final bool isSecondary;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  ThemeMode _themeMode = ThemeMode.light;

  @override
  void initState() {
    sharedConfigManager.addListener(_configListen);
    super.initState();
  }

  @override
  void dispose() {
    sharedConfigManager.removeListener(_configListen);
    super.dispose();
  }

  void _configListen() {
    _themeMode = sharedConfig.themeMode;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final virtualWindowFrameBuilder = VirtualWindowFrameInit();
    final botToastBuilder = BotToastInit();

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      builder: (context, child) {
        child = virtualWindowFrameBuilder(context, child);
        child = botToastBuilder(context, child);
        return child;
      },
      navigatorObservers: [BotToastNavigatorObserver()],
      home: widget.isSecondary
          ? ReusableWindow(
              initialArgs: widget.args,
              windowOptions: WindowOptions(
                size: const Size(800, 600),
                center: true,
                backgroundColor: Colors.transparent,
                skipTaskbar: false,
                titleBarStyle: TitleBarStyle.hidden,
                windowButtonVisibility: false,
                title: 'Window ID ${MultiWindowManager.current.id}',
              ),
              loadingBuilder: (context) => const Center(
                child: SizedBox(
                  height: 60,
                  width: 60,
                  child: CircularProgressIndicator(),
                ),
              ),
              builder: (context, args) {
                final Map<String, dynamic> argsMap =
                    args.isEmpty ? {} : {'arg1': args[0], 'arg2': args[1]};
                debugPrint('args: $args');

                return const HomePage();
              },
            )
          : const HomePage(),
    );
  }
}
