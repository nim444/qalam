plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "ro.soluzy.qalam"
    compileSdk = 36

    defaultConfig {
        applicationId = "ro.soluzy.qalam"
        minSdk = 34
        targetSdk = 36
        versionCode = 1
        versionName = "0.0.1-m0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

// M0 uses only the platform SDK. AndroidX (Jetpack Ink, motion prediction) comes with M1.
