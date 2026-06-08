plugins {
    id("com.android.library")
}

android {
    namespace = "com.example.gimal.overlayutils"
    compileSdk = 36

    defaultConfig {
        minSdk = 23
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
