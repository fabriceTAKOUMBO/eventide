import 'package:flutter/widgets.dart';

import 'app/bootstrap.dart';
import 'ui/app.dart';

Future<void> main() async {
  final started = await startEventide();
  runApp(EventideApp(model: started.model));
}
