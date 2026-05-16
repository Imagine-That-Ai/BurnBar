# UniFFI-generated bindings rely on JNA reflection and com.sun.jna.Native
# class loading. Keep the generated package and JNA hot paths.
-keep class uniffi.** { *; }
-keep class com.sun.jna.** { *; }
-keepclassmembers class * extends com.sun.jna.Library { *; }
-keepattributes Signature
-keepattributes *Annotation*
