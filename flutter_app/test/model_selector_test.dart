import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neuron_engine/model_selector.dart';
import 'package:neuron_engine/theme.dart';

List<Map<String, dynamic>> models({bool firstActive = true}) => [
      {
        'name': 'alpha-Q4.gguf',
        'path': '/models/alpha-Q4.gguf',
        'size': 512 * 1024 * 1024,
        'active': firstActive,
      },
      {
        'name': 'beta-Q5.gguf',
        'path': '/models/beta-Q5.gguf',
        'size': 1024 * 1024 * 1024,
        'active': !firstActive,
      },
    ];

void main() {
  test('format ukuran model lokal', () {
    expect(ModelSelector.sizeLabel(512 * 1024 * 1024), '512 MB');
    expect(ModelSelector.sizeLabel(1024 * 1024 * 1024), '1.0 GB');
  });

  testWidgets('menampilkan dua model dan menandai model aktif', (tester) async {
    String? selected;
    await tester.pumpWidget(MaterialApp(
      theme: neuronTheme(),
      home: Scaffold(
        body: ModelSelector(
          models: models(),
          busy: false,
          onSelect: (path) => selected = path,
        ),
      ),
    ));

    expect(find.text('alpha-Q4.gguf'), findsOneWidget);
    await tester.tap(find.text('alpha-Q4.gguf'));
    await tester.pumpAndSettle();
    expect(find.text('beta-Q5.gguf'), findsOneWidget);
    expect(
      find.byWidgetPredicate((widget) =>
          widget is Text && widget.data?.contains('Aktif untuk Chat') == true),
      findsOneWidget,
    );
    expect(find.text('Dipakai'), findsOneWidget);
    expect(find.text('Pilih'), findsOneWidget);

    await tester.tap(find.text('Pilih'));
    expect(selected, '/models/beta-Q5.gguf');
  });

  testWidgets('selector terkunci saat streaming atau aktivasi berlangsung', (tester) async {
    var selected = false;
    await tester.pumpWidget(MaterialApp(
      theme: neuronTheme(),
      home: Scaffold(
        body: ModelSelector(
          models: models(),
          busy: false,
          locked: true,
          onSelect: (_) => selected = true,
        ),
      ),
    ));

    final button = tester.widget<OutlinedButton>(
      find.byWidgetPredicate((widget) => widget is OutlinedButton),
    );
    expect(button.onPressed, isNull);
    expect(find.text('Jawaban sedang berjalan…'), findsOneWidget);
    expect(selected, isFalse);
  });
}
