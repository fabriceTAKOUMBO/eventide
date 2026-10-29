import 'package:flutter/widgets.dart';

import 'app/bootstrap.dart';
import 'services/diagnostics.dart';
import 'ui/app.dart';

Future<void> main() async {
  // Problem report: the app's errors go to its log on the phone, and are still printed.
  WidgetsFlutterBinding.ensureInitialized();
  installErrorHooks(Breadcrumbs.log);
  final started = await startEventide();
  runApp(EventideApp(model: started.model));
}
