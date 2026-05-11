# Firebase
-keepattributes Signature
-keepattributes *Annotation*
-dontwarn com.google.firebase.**

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
