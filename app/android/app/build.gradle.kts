import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    // It also applies the Kotlin Android plugin (android.builtInKotlin=false in gradle.properties).
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing: android/key.properties (never committed, see docs/app/architecture.md).
// When the file is absent (CI, other developers) release builds fall back to the debug key.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

// Host of the share links (App Links). Override with -Peventide.shareHost=example.com
// (must match the SHARE_HOST dart-define).
val shareHost: String = (project.findProperty("eventide.shareHost") as String?) ?: "eventide.app"

// AdMob application id. Defaults to Google's official sample id (test ads only).
val admobAppId: String =
    (project.findProperty("eventide.admobAppId") as String?) ?: "ca-app-pub-3940256099942544~3347511713"

// Demo build (« Eventide Démo », docs/app/architecture.md): -Peventide.demo=true, i.e.
//   flutter build apk --release --dart-define=DEMO_MODE=true --android-project-arg=eventide.demo=true
// Its own package (be.cinaf.eventide.demo) and launcher label, so it can never be uploaded or
// installed in place of the production app, and a manifest flag that the Dart side requires
// (together with its DEMO_MODE dart-define) before unlocking Premium locally.
val demoBuild: Boolean = project.findProperty("eventide.demo")?.toString()?.trim() == "true"

android {
    namespace = "be.cinaf.eventide"
    // 37: required by permission_handler_android. targetSdk stays 36 (Google Play requirement).
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // java.time (scheduled starts, ScheduleStore.kt) on Android 7.x (API 24-25).
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "be.cinaf.eventide"
        if (demoBuild) {
            applicationIdSuffix = ".demo"
        }
        minSdk = 24
        // Google Play requires API 36 for new apps and updates since 31 August 2026.
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["shareHost"] = shareHost
        manifestPlaceholders["admobAppId"] = admobAppId
        manifestPlaceholders["appLabel"] = if (demoBuild) "Eventide D\u00e9mo" else "Eventide"
        manifestPlaceholders["demoBuild"] = demoBuild.toString()
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            // R8 (minify + resource shrinking) is enabled for release by the Flutter Gradle plugin.
            // Without key.properties (CI, demo builds) the release APK is signed with the debug key.
            signingConfig =
                if (hasReleaseKeystore) {
                    signingConfigs.getByName("release")
                } else {
                    signingConfigs.getByName("debug")
                }
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

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // Play Integrity, classic requests (installation bootstrap, POST /installations).
    implementation("com.google.android.play:integrity:1.4.0")
    // Task API used by the integrity request (normally transitive; declared to be explicit).
    implementation("com.google.android.gms:play-services-tasks:18.2.0")
    // NotificationCompat, ContextCompat (fallback notifications, foreground service start).
    implementation("androidx.core:core-ktx:1.13.1")
}
