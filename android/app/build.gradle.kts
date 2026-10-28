plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The document detector runs on the CPU through tflite_flutter's FFI binding.
// The GPU delegate is a transitive dependency of the plugin and costs ~3.9 MB
// of native code that nothing loads, so it is stripped from the graph.
configurations.all {
    exclude(group = "com.google.ai.edge.litert", module = "litert-gpu")
}

android {
    namespace = "com.aniruth.scan"
    // permission_handler_android requires compiling against SDK 37 or later.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    packaging {
        // AAR-provided natives ignore ndk.abiFilters, so prune the emulator
        // ABIs here as well (libtensorflowlite_jni.so alone is 5.8 MB on x86_64).
        jniLibs {
            excludes += listOf("lib/x86/**", "lib/x86_64/**")
        }
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.aniruth.scan"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        // Real phones only: dropping x86/x86_64 emulator ABIs keeps the TFLite
        // runtime from adding a 5.8 MB slice that no device will load.
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a")
        }
        // Target the current Android API level required for new apps.
        targetSdk = 37
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // Keep ML Kit's reflection entry points: see proguard-rules.pro.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
