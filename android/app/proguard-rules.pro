# Firebase
-keepattributes Signature
-keepattributes *Annotation*
-dontwarn com.google.firebase.**

# BurnBarApplication loads DebugAppCheckProviderFactory via Class.forName
# when this APK is built for Firebase App Distribution. R8 has no static
# reference to walk, so keep the factory + its companion storage classes.
-keep class com.google.firebase.appcheck.debug.DebugAppCheckProviderFactory { *; }
-keep class com.google.firebase.appcheck.debug.internal.** { *; }

# Kotlin Serialization
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.AnnotationsKt
-keepclassmembers class kotlinx.serialization.json.** { *** Companion; }
-keepclasseswithmembers class kotlinx.serialization.json.** {
    kotlinx.serialization.KSerializer serializer(...);
}
-keep,includedescriptorclasses class com.openburnbar.**$$serializer { *; }
-keepclassmembers class com.openburnbar.** {
    *** Companion;
}
-keepclasseswithmembers class com.openburnbar.** {
    kotlinx.serialization.KSerializer serializer(...);
}

# OkHttp SSE (Insights LLM streaming)
-keep class okhttp3.internal.sse.** { *; }
-dontwarn okhttp3.internal.sse.**

# Vico charts (Insights renderers)
-keep class com.patrykandpatrick.vico.** { *; }
-dontwarn com.patrykandpatrick.vico.**

# Coil image loading (Insights icons)
-keep class coil.** { *; }
-dontwarn coil.**
