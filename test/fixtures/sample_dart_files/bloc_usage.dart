import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

// Events
abstract class CounterEvent {}
class IncrementEvent extends CounterEvent {}
class DecrementEvent extends CounterEvent {}

// Bloc
class CounterBloc extends Bloc<CounterEvent, int> {
  CounterBloc() : super(0) {
    on<IncrementEvent>((event, emit) => emit(state + 1));
    on<DecrementEvent>((event, emit) => emit(state - 1));
  }
}

class BlocCounterPage extends StatelessWidget {
  const BlocCounterPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => CounterBloc(),
      child: BlocBuilder<CounterBloc, int>(
        builder: (context, count) {
          return Scaffold(
            appBar: AppBar(title: Text('Bloc Counter')),
            body: Center(child: Text('Count: $count')),
            floatingActionButton: FloatingActionButton(
              onPressed: () {
                context.read<CounterBloc>().add(IncrementEvent());
              },
              child: const Icon(Icons.add),
            ),
          );
        },
      ),
    );
  }
}
