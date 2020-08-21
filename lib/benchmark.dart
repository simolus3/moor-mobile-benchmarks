import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:moor/ffi.dart';
import 'package:moor/isolate.dart';
import 'package:moor/moor.dart';
import 'package:moor_flutter/moor_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class _CreateIsolateArgs {
  final SendPort outDb;
  final String path;

  _CreateIsolateArgs(this.outDb, this.path);
}

void _backgroundIsolateEntrypoint(_CreateIsolateArgs args) {
  final isolate = MoorIsolate.inCurrent(() {
    final db = VmDatabase(File(args.path));
    return DatabaseConnection.fromExecutor(db);
  });

  args.outDb.send(isolate);
}

Future<void> runBenchmarks() async {
  final tempDir = await getTemporaryDirectory();

  final pathForSqflite = p.join(tempDir.path, 'sqflite.db');
  final pathForFfi = p.join(tempDir.path, 'ffi.db');

  final sqflite = DatabaseConnection.fromExecutor(
      FlutterQueryExecutor(path: pathForSqflite));

  final receiveIsolate = ReceivePort();
  final moorIsolateCompleter = Completer<MoorIsolate>()
    ..complete(receiveIsolate.first.then((i) => i as MoorIsolate));
  final isolate = await Isolate.spawn(_backgroundIsolateEntrypoint,
      _CreateIsolateArgs(receiveIsolate.sendPort, pathForFfi));

  final moorIsolate = await moorIsolateCompleter.future;
  final ffi = await (moorIsolate).connect();

  final sqfliteResults = await BenchmarkRunner(sqflite).run();
  final ffiResults = await BenchmarkRunner(ffi).run();

  _printResults('Sqflite', sqfliteResults);
  _printResults('FFI + Isolate', ffiResults);

  isolate.kill();
}

void _printResults(String name, BenchmarkResults results) {
  print(' === $name ===');
  print('time for inserts: ${results.timeForInserts} us');
  print('time for selects: ${results.timeForSelect} us');
  print(' ============ ');
}

class BenchmarkRunner implements QueryExecutorUser {
  final DatabaseConnection connection;
  final BenchmarkResults results = BenchmarkResults();

  QueryExecutor get _executor => connection.executor;

  BenchmarkRunner(this.connection);

  @override
  int get schemaVersion => 1;

  @override
  Future<void> beforeOpen(
      QueryExecutor executor, OpeningDetails details) async {
    await executor.ensureOpen(this);
    await executor.runCustom('DROP TABLE IF EXISTS key_value;');
    await executor.runCustom('VACUUM');
    await executor.runCustom('''
      CREATE TABLE key_value (
        "key" INTEGER NOT NULL PRIMARY KEY,
        "value" TEXT NOT NULL
      );
      ''');
  }

  Future<BenchmarkResults> run() async {
    await _executor.ensureOpen(this);

    await _runInsertBenchmarks();
    await _runSelectBenchmarks();

    await _executor.close();
    return results;
  }

  Future<void> _runInsertBenchmarks() async {
    // We care about the performance to send queries through an isolate or
    // platform channel. Use a transaction to amortize IO costs.
    final stopwatch = Stopwatch()..start();

    final transaction = _executor.beginTransaction();
    await transaction.ensureOpen(this);

    for (var i = 0; i < 10000; i++) {
      transaction.runInsert(
        'INSERT INTO key_value ("value") VALUES (?)',
        ['some string to insert'],
      );
    }

    await transaction.send();
    stopwatch.stop();
    results.timeForInserts = stopwatch.elapsedMicroseconds;
  }

  Future<void> _runSelectBenchmarks() async {
    final stopwatch = Stopwatch()..start();

    for (var i = 1; i < 10001; i++) {
      await _executor
          .runSelect('SELECT "value" FROM key_value WHERE "key" = ?', [i]);
    }

    stopwatch.stop();
    results.timeForSelect = stopwatch.elapsedMicroseconds;
  }
}

class BenchmarkResults {
  /// Time for the small insert benchmark, in microseconds.
  int timeForInserts;

  /// Time for the small select benchmark, in microseconds.
  int timeForSelect;
}
