# Flutter engine / embedding - never strip, plugins reach these via
# reflection during registration.
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }

# Plugins used by this app that have native Android code - keep their
# classes intact so R8 shrink/minify never removes something a plugin
# looks up by name (location, file picking, path access, local storage).
-keep class com.baseflow.geolocator.** { *; }
-keep class com.mr.flutter.plugin.filepicker.** { *; }
-keep class io.flutter.plugins.pathprovider.** { *; }
-keep class io.flutter.plugins.sharedpreferences.** { *; }

# Keep annotations/generic signatures - some plugins rely on them for
# platform-channel (de)serialization.
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes EnclosingMethod
-keepattributes InnerClasses

# Silence warnings for optional platform APIs plugins reference defensively.
-dontwarn io.flutter.embedding.**
