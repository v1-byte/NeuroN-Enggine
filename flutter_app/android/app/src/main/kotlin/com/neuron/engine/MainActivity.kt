package com.neuron.engine

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/** Entry point Android. UI ada di Flutter (lib/main.dart); engine Kotlin dihubungkan lewat NeuronBridge. */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        NeuronBridge.register(flutterEngine.dartExecutor.binaryMessenger, applicationContext)
    }
}
