# WebRTC Proguard Rules
# These ensure that the native JNI methods and audio callbacks remain intact

-keep class org.webrtc.** { *; }
-keep interface org.webrtc.** { *; }
-dontwarn org.webrtc.**

# Preserve audio management types used by Android AIDL/Legacy bridge
-keep class android.media.AudioTrack { *; }
-keep class android.media.AudioRecord { *; }
-keep class android.media.AudioManager { *; }

# Gibber Audio Effects - used via reflection from flutter_webrtc AudioProcessingAdapter
-keep class com.gibber.desertrobotservices.audio.** { *; }
-keep class org.webrtc.ExternalAudioProcessingFactory$AudioProcessing { *; }
-keep class com.cloudwebrtc.webrtc.audio.AudioProcessingAdapter { *; }
-keep class com.cloudwebrtc.webrtc.audio.AudioProcessingAdapter$ExternalAudioFrameProcessing { *; }
-keep class com.cloudwebrtc.webrtc.audio.AudioProcessingController { *; }
