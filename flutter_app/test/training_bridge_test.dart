import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neuron_engine/bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('neuron/project');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'trainingLoadConfig':
          return {
            'config': jsonEncode({'method': 'LORA', 'target': 'REMOTE_SERVER'}),
            'apiKeyConfigured': true,
          };
        case 'trainingInspectDataset':
          return {
            'path': '/private/datasets/train.jsonl',
            'format': 'jsonl',
            'totalRecords': 2,
            'validRecords': 2,
            'errorCount': 0,
            'ok': true,
            'errors': <String>[],
            'preview': <String>['hello → hi'],
          };
        case 'trainingStart':
          return {'jobId': 'job-123', 'status': 'running'};
        case 'trainingReconnect':
          return {'jobId': 'job-123', 'status': 'connecting'};
        case 'trainingState':
          return {'jobId': 'job-123', 'status': 'done', 'step': 10, 'total': 10};
        case 'trainingCancel':
        case 'trainingSaveConfig':
          return {'ok': true};
        case 'trainingDownloadAdapter':
          return {'path': '/private/adapters/job-123.zip', 'gguf': false};
        default:
          throw MissingPluginException('Unexpected method ${call.method}');
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('loads config without exposing a key value', () async {
    final config = await Bridge.trainingLoadConfig();
    expect(config['apiKeyConfigured'], isTrue);
    expect(jsonDecode(config['config'])['target'], 'REMOTE_SERVER');
    expect(calls.single.method, 'trainingLoadConfig');
  });

  test('saves training config as JSON', () async {
    await Bridge.trainingSaveConfig({'method': 'LORA', 'remoteTrainerUrl': 'https://trainer'});
    expect(calls.single.method, 'trainingSaveConfig');
    final args = Map<String, dynamic>.from(calls.single.arguments as Map);
    expect(jsonDecode(args['config'])['remoteTrainerUrl'], 'https://trainer');
  });

  test('inspects dataset and starts/resumes/cancels/downloads a job', () async {
    final report = await Bridge.trainingInspectDataset('/tmp/train.jsonl', 'LORA');
    expect(report['validRecords'], 2);
    expect((calls.last.arguments as Map)['method'], 'LORA');

    expect((await Bridge.trainingStart())['jobId'], 'job-123');
    expect((await Bridge.trainingReconnect('job-123'))['status'], 'connecting');
    expect((await Bridge.trainingState())['total'], 10);
    await Bridge.trainingCancel('job-123');
    expect((await Bridge.trainingDownloadAdapter('job-123', gguf: false))['gguf'], isFalse);

    expect(calls.map((call) => call.method), [
      'trainingInspectDataset',
      'trainingStart',
      'trainingReconnect',
      'trainingState',
      'trainingCancel',
      'trainingDownloadAdapter',
    ]);
  });
}
