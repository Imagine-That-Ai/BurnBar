# UniFFI-generated bindings resolve the JNA library and native entry points by
# reflection. Keep the generated package and JNA interfaces through R8.
-keep class uniffi.openburnbar_domain_ffi.** { *; }
-keep class com.sun.jna.** { *; }
-keepclassmembers class * extends com.sun.jna.Library { *; }
-keepattributes Signature
-keepattributes *Annotation*
