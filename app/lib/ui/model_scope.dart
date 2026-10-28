import 'package:flutter/widgets.dart';

import '../app/app_model.dart';

/// Makes the [AppModel] available to every screen and rebuilds dependents when it
/// notifies.
class ModelScope extends InheritedNotifier<AppModel> {
  const ModelScope({super.key, required AppModel model, required super.child})
    : super(notifier: model);

  /// Reads the model and rebuilds the caller when it changes.
  static AppModel of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ModelScope>();
    assert(scope != null, 'No ModelScope above this widget');
    return scope!.notifier!;
  }

  /// Reads the model without listening (for callbacks).
  static AppModel read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<ModelScope>();
    assert(scope != null, 'No ModelScope above this widget');
    return scope!.notifier!;
  }
}

extension ModelContext on BuildContext {
  AppModel get model => ModelScope.of(this);
  AppModel get readModel => ModelScope.read(this);
}
