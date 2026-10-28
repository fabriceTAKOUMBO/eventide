// Pumps the whole UI with a FakeAppModel and opens screens directly.
import 'package:eventide/ui/app.dart';
import 'package:eventide/ui/navigation.dart';
import 'package:eventide/ui/screens/home/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_app_model.dart';

const Key kAppBoundary = Key('app-boundary');

Future<void> pumpApp(WidgetTester tester, FakeAppModel model, {bool showHint = false}) async {
  HomeScreen.hintShownThisSession = !showHint;
  await tester.pumpWidget(RepaintBoundary(key: kAppBoundary, child: EventideApp(model: model)));
  await settle(tester);
}

/// Pumps enough frames for routes, fades and async callbacks (reduced motion makes
/// transitions instant, but routes still take their duration).
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

NavigatorState navigatorOf(WidgetTester tester) => tester.state<NavigatorState>(find.byType(Navigator).first);

Future<void> openRoute(WidgetTester tester, String name, WidgetBuilder builder) async {
  navigatorOf(tester).push(VitreRoute<void>(builder: builder, name: name));
  await settle(tester);
}

/// Disposes the tree so pending timers are cancelled before the test ends.
Future<void> tearDownApp(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 3));
}
