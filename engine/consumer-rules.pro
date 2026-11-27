# Engine native (llama.cpp via JNI). C++ memanggil method Java/Kotlin lewat nama, jadi nama
# kelas, method, dan callback (TokenCallback) harus dipertahankan apa adanya.
-keep class com.neuron.engine.** { *; }
-keepclasseswithmembernames class * {
    native <methods>;
}
