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
dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation(project(":model"))
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    testImplementation("junit:junit:4.13.2")
}
