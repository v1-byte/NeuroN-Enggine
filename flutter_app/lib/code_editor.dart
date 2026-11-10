import 'package:flutter/material.dart';

/// Editor kode: nomor baris di kiri, teks di kanan. Keduanya digulir bersama dalam satu scroll.
class CodeEditor extends StatelessWidget {
  const CodeEditor({super.key, required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF111522),
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(top: 10, bottom: 24),
        child: ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (context, value, _) {
            final count = value.text.split('\n').length;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 8, right: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (var i = 1; i <= count; i++)
                        Text(
                          '$i',
                          style: const TextStyle(
                            color: Color(0xFF68718A),
                            fontFamily: 'monospace',
                            fontSize: 12,
                            height: 1.65,
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: controller,
                    onChanged: onChanged,
                    maxLines: null,
                    keyboardType: TextInputType.multiline,
                    style: const TextStyle(
                      color: Color(0xFFDCE4FF),
                      fontFamily: 'monospace',
                      fontSize: 12,
                      height: 1.65,
                    ),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      filled: false,
                      isCollapsed: true,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
