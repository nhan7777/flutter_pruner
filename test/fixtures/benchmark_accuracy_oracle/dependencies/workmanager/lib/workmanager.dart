import 'package:benchmark_accuracy_oracle/src/sibling_feature.dart';

class Workmanager {
  static void initialize(void Function() callback) {
    siblingFeature();
    callback();
  }
}
