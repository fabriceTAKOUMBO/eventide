# R8 rules of the app, added to the release build by the Flutter Gradle plugin (with
# proguard-android-optimize.txt and Flutter's own flutter_proguard_rules.pro).

# Flutter's embedding references the Play Core split-install classes for deferred components
# (FlutterPlayStoreSplitApplication, PlayStoreDeferredComponentManager). Eventide uses no
# deferred component and does not ship that library: never-loaded code, not an error.
# The Play Integrity library (com.google.android.play.core.integrity, .common) is unaffected.
-dontwarn com.google.android.play.core.splitcompat.**
-dontwarn com.google.android.play.core.splitinstall.**
-dontwarn com.google.android.play.core.tasks.**

# WorkManager (pulled in by plugins, e.g. Google Mobile Ads) builds its Room database by
# reflection: Room looks up "<database class name>_Impl" and calls its no-arg constructor.
# R8 renamed or stripped them, and the release build crashed at launch with
# "Failed to create an instance of androidx.work.impl.WorkDatabase" (CI emulator, 28 Oct 2026).
-keep class androidx.work.impl.WorkDatabase { *; }
-keep class androidx.work.impl.WorkDatabase_Impl { *; }
-keep class * extends androidx.room.RoomDatabase { <init>(); }

# Media card (MediaSessionLaunch.kt): our launch intent is put on audio_service's media session
# and in its static content intent by reflection (audio_service 0.18.19 exposes neither). Keep
# these three fields under their names, or the lock screen card would not open the app again.
-keepclassmembers class com.ryanheise.audioservice.AudioService {
    static com.ryanheise.audioservice.AudioService instance;
    private static android.app.PendingIntent contentIntent;
    private android.support.v4.media.session.MediaSessionCompat mediaSession;
}

# « Imaginaire » (3D scenes in a WebView, webview_flutter_android): the JavaScript channel
# EventideScene is a @JavascriptInterface method called by name from the page. Already kept by
# proguard-android-optimize.txt; stated here so that the scenes never go silent in a release.
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}
