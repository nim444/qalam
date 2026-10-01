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
        versionCode = 2
        versionName = "0.2.0"
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

// The app uses only the platform SDK. JUnit is for the JVM tests of the crypto (src/test).
dependencies {
    testImplementation("junit:junit:4.13.2")
}
