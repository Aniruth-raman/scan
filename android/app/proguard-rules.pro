# ML Kit finds its component registrars by reflection: Manifests holds a list of
# class names, ComponentDiscovery instantiates them through a no-arg constructor
# it looks up at runtime, and the document scanner's client is built by the
# registrar that comes out of that. Shrinking rewrites that constructor, which
# shows up as
#   W ComponentDiscovery: Could not instantiate ...CommonComponentRegistrar
#   Caused by: java.lang.NoSuchMethodException: ...CommonComponentRegistrar.<init> []
# and then as a NullPointerException the moment the scanner is started.
-keep class com.google.mlkit.** { *; }
-dontwarn com.google.mlkit.**

# The scanner itself lives in a Play services module fetched on demand; its
# entry points are resolved by reflection from the client.
-keep class com.google.android.gms.internal.mlkit_vision_document_scanner.** { *; }
