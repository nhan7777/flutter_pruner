import 'package:flutter/material.dart';

import 'gen/assets.gen.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final iconName = DateTime.now().year.toString();
    return MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            // This references assets/used.png
            Image.asset('assets/used.png'),

            // This references assets/generated.png through FlutterGen.
            Image.asset(Assets.generated.path),

            // Dynamic reference that should create a blocker
            Image.asset('assets/icons/$iconName.png'),
          ],
        ),
      ),
    );
  }
}

class Repository {
  void loadProducts(String value) {}
}

void unrelatedLoad(Repository repository, String value) {
  repository.loadProducts(value);
}
