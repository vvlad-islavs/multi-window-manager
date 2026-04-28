import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:multi_window_manager/multi_window_manager.dart';

Future<void> main(List<String> args) async {
  if (kDebugMode) {
    print(args);
  }
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  await MultiWindowManager.ensureInitialized(args.isEmpty ? 0 : int.parse(args[0]));
  await MultiWindowManager.current.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(640, 480),
      title: 'window_manager_test',
    ),
    () async {
      await MultiWindowManager.current.show();
      await MultiWindowManager.current.focus();
    },
  );

  testWidgets('getBounds', (tester) async {
    expect(
      await MultiWindowManager.current.getBounds(),
      isA<Rect>().having((r) => r.size, 'size', const Size(640, 480)),
    );
  });

  testWidgets(
    'isAlwaysOnBottom',
    (tester) async {
      expect(await MultiWindowManager.current.isAlwaysOnBottom(), isFalse);
    },
    skip: Platform.isMacOS || Platform.isWindows,
  );

  testWidgets('isAlwaysOnTop', (tester) async {
    expect(await MultiWindowManager.current.isAlwaysOnTop(), isFalse);
  });

  testWidgets('isClosable', (tester) async {
    expect(await MultiWindowManager.current.isClosable(), isTrue);
  });

  testWidgets('isFocused', (tester) async {
    expect(await MultiWindowManager.current.isFocused(), isTrue);
  });

  testWidgets('isFullScreen', (tester) async {
    expect(await MultiWindowManager.current.isFullScreen(), isFalse);
  });

  testWidgets(
    'hasShadow',
    (tester) async {
      expect(await MultiWindowManager.current.hasShadow(), isTrue);
    },
    skip: Platform.isLinux,
  );

  testWidgets('isMaximizable', (tester) async {
    expect(await MultiWindowManager.current.isMaximizable(), isTrue);
  });

  testWidgets('isMaximized', (tester) async {
    expect(await MultiWindowManager.current.isMaximized(), isFalse);
  });

  testWidgets(
    'isMinimizable',
    (tester) async {
      expect(await MultiWindowManager.current.isMinimizable(), isTrue);
    },
    skip: Platform.isMacOS,
  );

  testWidgets('isMinimized', (tester) async {
    expect(await MultiWindowManager.current.isMinimized(), isFalse);
  });

  testWidgets(
    'isMovable',
    (tester) async {
      expect(await MultiWindowManager.current.isMovable(), isTrue);
    },
    skip: Platform.isLinux || Platform.isWindows,
  );

  testWidgets('getOpacity', (tester) async {
    expect(await MultiWindowManager.current.getOpacity(), 1.0);
  });

  testWidgets('getPosition', (tester) async {
    expect(await MultiWindowManager.current.getPosition(), isA<Offset>());
  });

  testWidgets('isPreventClose', (tester) async {
    expect(await MultiWindowManager.current.isPreventClose(), isFalse);
  });

  testWidgets('isResizable', (tester) async {
    expect(await MultiWindowManager.current.isResizable(), isTrue);
  });

  testWidgets('getSize', (tester) async {
    expect(await MultiWindowManager.current.getSize(), const Size(640, 480));
  });

  testWidgets(
    'isSkipTaskbar',
    (tester) async {
      expect(await MultiWindowManager.current.isSkipTaskbar(), isFalse);
    },
    skip: Platform.isWindows,
  );

  testWidgets('getTitle', (tester) async {
    expect(await MultiWindowManager.current.getTitle(), 'window_manager_test');
  });

  testWidgets('getTitleBarHeight', (tester) async {
    expect(await MultiWindowManager.current.getTitleBarHeight(), isNonNegative);
  });

  testWidgets('isVisible', (tester) async {
    expect(await MultiWindowManager.current.isVisible(), isTrue);
  });
}
