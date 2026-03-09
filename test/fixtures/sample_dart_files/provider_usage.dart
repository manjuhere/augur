import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class CounterModel extends ChangeNotifier {
  int _count = 0;
  int get count => _count;

  void increment() {
    _count++;
    notifyListeners();
  }
}

class CounterPage extends StatelessWidget {
  const CounterPage({super.key});

  @override
  Widget build(BuildContext context) {
    // Using Provider.of<T>() - would be flagged by AST analysis
    final counter = Provider.of<CounterModel>(context);

    return Scaffold(
      appBar: AppBar(title: Text('Counter: ${counter.count}')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('Count: ${counter.count}'),
            // Also using context.watch
            Text('Watch: ${context.watch<CounterModel>().count}'),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          // Using context.read
          context.read<CounterModel>().increment();
        },
        child: const Icon(Icons.add),
      ),
    );
  }
}

class ProviderSetup extends StatelessWidget {
  const ProviderSetup({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (context) => CounterModel(),
      child: const CounterPage(),
    );
  }
}
