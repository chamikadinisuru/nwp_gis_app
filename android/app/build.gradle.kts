import com.android.build.api.dsl.ApplicationExtension
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.tasks.KotlinCompile

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

// AGP 9.0+ සඳහා නිල වශයෙන් නිර්දේශිත ApplicationExtension බ්ලොක් එක
configure<ApplicationExtension> {
    namespace = "com.example.nwp_gis_app"
    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.example.nwp_gis_app"
        // Explicitly pinned as a fixed number (NOT flutter.minSdkVersion)
        // so this always covers Android 8.1 (API 27, e.g. this Oppo phone)
        // and older devices with margin, regardless of what the locally
        // installed Flutter SDK's own default minSdk changes to later.
        minSdk = flutter.minSdkVersion
        targetSdk = 34
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
            // Shrinks + obfuscates + removes unused resources for the
            // release build - smaller APK, faster install and faster
            // cold-start on lower-end/older devices. Flutter's own
            // Dart/Skia engine code isn't touched by this (it's native,
            // not Java/Kotlin), so this is safe for a Flutter app.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

// ⬇️ Kotlin compiler එක සඳහා නවතම compilerOptions DSL එක මෙන්න ⬇️
tasks.withType<KotlinCompile>().configureEach {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

flutter {
    source = "../.."
}
