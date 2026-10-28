# R8 rules of the app, added to the release build by the Flutter Gradle plugin (with
# proguard-android-optimize.txt and Flutter's own flutter_proguard_rules.pro).

# Flutter's embedding references the Play Core split-install classes for deferred components
# (FlutterPlayStoreSplitApplication, PlayStoreDeferredComponentManager). Eventide uses no
# deferred component and does not ship that library: never-loaded code, not an error.
# The Play Integrity library (com.google.android.play.core.integrity, .common) is unaffected.
-dontwarn com.google.android.play.core.splitcompat.**
-dontwarn com.google.android.play.core.splitinstall.**
-dontwarn com.google.android.play.core.tasks.**
