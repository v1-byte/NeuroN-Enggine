import 'package:flutter/material.dart';

const ink = Color(0xFF101321);
const panel = Color(0xFF181C2D);
const panel2 = Color(0xFF20253A);
const purple = Color(0xFF9A72FF);
const blue = Color(0xFF468EFF);
const muted = Color(0xFF9098B1);
const green = Color(0xFF53D69A);
const amber = Color(0xFFFFC857);
const line = Color(0xFF30364E);
const errorRed = Color(0xFFFF6B6B);

enum NeuronThemePreset { midnight, ocean, amethyst, emerald, amber }

String themeLabel(NeuronThemePreset preset) => switch (preset) {
      NeuronThemePreset.midnight => 'Midnight',
      NeuronThemePreset.ocean => 'Ocean',
      NeuronThemePreset.amethyst => 'Amethyst',
      NeuronThemePreset.emerald => 'Emerald',
      NeuronThemePreset.amber => 'Amber',
    };

Color themeAccent(NeuronThemePreset preset) => switch (preset) {
      NeuronThemePreset.midnight => blue,
      NeuronThemePreset.ocean => const Color(0xFF27C6D9),
      NeuronThemePreset.amethyst => const Color(0xFFB77BFF),
      NeuronThemePreset.emerald => const Color(0xFF36D399),
      NeuronThemePreset.amber => const Color(0xFFFFB84D),
    };

ThemeData neuronTheme([NeuronThemePreset preset = NeuronThemePreset.midnight]) {
  OutlineInputBorder border(Color c) =>
      OutlineInputBorder(borderRadius: BorderRadius.circular(9), borderSide: BorderSide(color: c));
  final accent = themeAccent(preset);

  return ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: ink,
    colorScheme: ColorScheme.dark(primary: accent, secondary: purple, surface: panel),
    useMaterial3: true,
    fontFamily: 'Roboto',
    dividerColor: line,
    navigationBarTheme: NavigationBarThemeData(
      indicatorColor: accent.withOpacity(.22),
      iconTheme: WidgetStatePropertyAll(IconThemeData(color: accent)),
      labelTextStyle: WidgetStatePropertyAll(TextStyle(color: accent, fontSize: 11)),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: accent)),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(foregroundColor: accent, side: BorderSide(color: accent))),
    checkboxTheme: CheckboxThemeData(fillColor: WidgetStatePropertyAll(accent)),
    sliderTheme: SliderThemeData(activeTrackColor: accent, thumbColor: accent, overlayColor: accent.withOpacity(.18)),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: accent, linearTrackColor: line),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: ink,
      hintStyle: const TextStyle(color: muted, fontSize: 12),
      contentPadding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
      border: border(line),
      enabledBorder: border(line),
      focusedBorder: border(accent),
    ),
  );
}
