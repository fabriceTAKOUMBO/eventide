import 'package:flutter/widgets.dart';

import 'app/bootstrap.dart';
import 'services/native_bridge.dart';
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final native = MethodChannelNativeBridge();
  // First: a scheduled start may have booted this engine without any activity.
  final handler = await initPlayback(native);
  final controller = await createAppModel(handler: handler, native: native);
  AppLifecycleListener(onStateChange: controller.handleLifecycle);
  final initial = WidgetsBinding.instance.lifecycleState;
  if (initial != null) controller.handleLifecycle(initial);
  runApp(EventideApp(model: controller));
}
