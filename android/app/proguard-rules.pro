# Keep SWIG-generated PJSUA2 JNI classes, director callbacks, and native pointer fields.
-keep class org.pjsip.pjsua2.** { *; }
-dontwarn org.pjsip.pjsua2.**

# Keep Android app services, Telecom ConnectionService, activities, and PJSIP bridge classes.
-keep class local.simhub.phone.** { *; }
