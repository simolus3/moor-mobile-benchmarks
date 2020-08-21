import 'package:flutter/material.dart';

import 'benchmark.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await runBenchmarks();

  runApp(const SizedBox.expand());
}
