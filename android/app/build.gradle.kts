plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Local Firebase configuration is intentionally not committed.
if (file("google-services.json").isFile) {
    apply(plugin = "com.google.gms.google-services")
}

android {
    namespace = "com.caoyuming.lifepages"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.caoyuming.lifepages"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(23, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // The RTC SDK's required ByteNN library is only supplied for ARM.
        // API 36 Google APIs emulators can execute ARM64 via native translation.
        ndk { abiFilters += "arm64-v8a" }
    }

    buildTypes {
        release {
            // The locked RTC SDK uses JNI/reflection and references optional vendor
            // audio and JSON integrations absent from this app. Keep its Java code
            // intact; Flutter's Dart code still uses release AOT compilation.
            isMinifyEnabled = false
            isShrinkResources = false
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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

// ByteNN in the locked RTC SDK requires the NDK's shared C++ runtime.
// Generate it from the installed NDK rather than committing native binaries.
val prepareRtcCppRuntime = tasks.register<Copy>("prepareRtcCppRuntime") {
    from(androidComponents.sdkComponents.ndkDirectory.map { ndk ->
        ndk.asFile.resolve("toolchains/llvm/prebuilt").listFiles()!!.single()
            .resolve("sysroot/usr/lib/aarch64-linux-android/libc++_shared.so")
    })
    into(layout.buildDirectory.dir("generated/rtc-jni/arm64-v8a"))
}
android.sourceSets.getByName("main").jniLibs.srcDir(layout.buildDirectory.dir("generated/rtc-jni").get().asFile)
tasks.named("preBuild") { dependsOn(prepareRtcCppRuntime) }
