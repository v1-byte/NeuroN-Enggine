plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.serialization")
}
android {
    namespace = "com.neuron.engine"
    compileSdk = 35
    defaultConfig { minSdk = 26; consumerProguardFiles("consumer-rules.pro") }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }

    // Native llama.cpp hanya dibuild jika: ./gradlew assembleDebug -PwithNative  (butuh NDK + submodule llama.cpp)
    if (providers.gradleProperty("withNative").isPresent) {
        externalNativeBuild { cmake { path = file("src/main/cpp/CMakeLists.txt") } }
        defaultConfig { externalNativeBuild { cmake { arguments(*listOfNotNull("-DCMAKE_BUILD_TYPE=Release", "-DANDROID_STL=c++_static", if (providers.gradleProperty("withVulkan").isPresent) "-DNEURON_VULKAN=ON" else null).toTypedArray()) } } }
        defaultConfig { ndk { abiFilters += listOf("arm64-v8a") } }
    }
}

// Gagal lebih awal dan jelas bila build native diminta tetapi source llama.cpp belum ada
// (submodule kosong atau zip tanpa .git). Tanpa ini error baru muncul jauh di dalam CMake.
if (providers.gradleProperty("withNative").isPresent) {
    val llamaCmake = file("src/main/cpp/llama.cpp/CMakeLists.txt")
    tasks.matching { it.name == "preBuild" }.configureEach {
        doFirst {
            if (!llamaCmake.exists()) {
                throw GradleException(
                    "Source llama.cpp belum ada (engine/src/main/cpp/llama.cpp kosong). " +
                        "Jalankan ./scripts/setup_native.sh dari root repo, lalu ulangi build. Lihat docs/NATIVE.md."
                )
            }
        }
    }
}
dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation(project(":model"))

    testImplementation("junit:junit:4.13.2")
}
