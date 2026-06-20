plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "top.zztweb.astrbot"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    packaging {
        jniLibs {
            // arm64-only: drop any stray native libs a plugin ships for other ABIs
            // so the APK neither bloats nor installs-on-but-crashes on 32-bit/x86.
            excludes += listOf("**/armeabi-v7a/**", "**/x86_64/**", "**/x86/**")
        }
    }

    defaultConfig {
        applicationId = "top.zztweb.astrbot"
        minSdk = flutter.minSdkVersion
        targetSdk = 34
        versionCode = 7
        versionName = "1.1.5"
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
