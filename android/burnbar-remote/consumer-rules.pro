# UniFFI-generated bindings rely on JNA reflection and com.sun.jna.Native
# class loading. Keep the generated package and JNA hot paths.
-keep class uniffi.burnbar_remote.** { *; }
-keep class com.sun.jna.** { *; }
