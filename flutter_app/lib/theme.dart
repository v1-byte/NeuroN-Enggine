import 'package:flutter/material.dart';

const ink = Color(0xFF101321);
const panel = Color(0xFF181C2D);
const panel2 = Color(0xFF20253A);
const purple = Color(0xFF9A72FF);
const blue = Color(0xFF468EFF);
const muted = Color(0xFF9098B1);
const green = Color(0xFF53D69A);
const line = Color(0xFF30364E);
const rail = Color(0xFF141827);
const errorRed = Color(0xFFFF6B6B);

ThemeData neuronTheme() {
  OutlineInputBorder border(Color c) =>
      OutlineInputBorder(borderRadius: BorderRadius.circular(9), borderSide: BorderSide(color: c));

  return ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: ink,
    colorScheme: const ColorScheme.dark(primary: purple, secondary: blue, surface: panel),
    useMaterial3: true,
    fontFamily: 'Roboto',
    dividerColor: line,
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: ink,
      hintStyle: const TextStyle(color: muted, fontSize: 12),
      contentPadding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
      border: border(line),
      enabledBorder: border(line),
      focusedBorder: border(purple),
    ),
  );
}
