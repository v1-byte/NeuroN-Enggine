import 'package:flutter_test/flutter_test.dart';
import 'package:neuron_engine/flow_stepper.dart';

void main() {
  test('belum ada model → langkah 1', () {
    expect(flowStepFor(downloading: false, hasModel: false, loaded: false), 0);
  });
  test('sedang unduh → langkah 2, walau ada model lain', () {
    expect(flowStepFor(downloading: true, hasModel: false, loaded: false), 1);
    expect(flowStepFor(downloading: true, hasModel: true, loaded: true), 1);
  });
  test('model aktif belum dimuat → langkah 3', () {
    expect(flowStepFor(downloading: false, hasModel: true, loaded: false), 2);
  });
  test('model dimuat → langkah 4', () {
    expect(flowStepFor(downloading: false, hasModel: true, loaded: true), 3);
  });
  test('jumlah langkah dan petunjuk sama', () {
    expect(kFlowHints.length, kFlowSteps.length);
  });
}
