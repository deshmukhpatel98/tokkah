# Proguard rules for Kin Android release builds

# Bouncy Castle (RFC 7748 / RFC 8032 / Kyber ML-KEM)
-keep class org.bouncycastle.** { *; }
-dontwarn org.bouncycastle.**

# Google ML Kit Face Detection
-keep class com.google.mlkit.** { *; }
-dontwarn com.google.mlkit.**
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.android.gms.**

# Preserve annotations and signatures
-keepattributes *Annotation*,InnerClasses,EnclosingMethod,Signature

# Tokkah Kin network & wire classes
-keep class com.tokkah.kin.net.Wire** { *; }
-keep class com.tokkah.kin.net.Lpc { *; }
-keep class com.tokkah.kin.net.Crypto** { *; }
-keep class com.tokkah.kin.net.Rendezvous** { *; }
-keep class com.tokkah.kin.net.Telemetry** { *; }
-keep class com.tokkah.kin.ui.HomeCard { *; }
-keep class com.tokkah.kin.ui.Person { *; }

# Hardware callbacks
-keepclassmembers class * extends android.media.MediaCodec$Callback { *; }
-keepclassmembers class * extends android.media.AudioDeviceCallback { *; }
-keepclassmembers class * extends android.hardware.camera2.CameraDevice$StateCallback { *; }
-keepclassmembers class * extends android.hardware.camera2.CameraCaptureSession$StateCallback { *; }
