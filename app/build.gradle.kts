plugins {
    alias(libs.plugins.android.application)
}

android {
    namespace = "com.kooo.evcam"
    compileSdk = 36
    buildToolsVersion = "36.0.0"
    ndkVersion = "28.2.13676358"

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    // 签名配置 (使用 AOSP 公共测试签名)
    signingConfigs {
        create("release") {
            storeFile = file("../keystore/release.jks")
            storePassword = "android"
            keyAlias = "apkeasytool"
            keyPassword = "android"
        }
    }

    defaultConfig {
        applicationId = "com.kooo.evcam.v2"
        minSdk = 28
        targetSdk = 36
        versionCode = 80
        versionName = "2.0.0-test-05151352"

        ndk {
            abiFilters += listOf("arm64-v8a")
        }

        externalNativeBuild {
            cmake {
                arguments += listOf("-DANDROID_STL=c++_shared")
            }
        }

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            // 使用签名配置
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    buildFeatures {
        viewBinding = true
        aidl = true
    }

}

dependencies {
    implementation(project(":core:model"))

    implementation(libs.appcompat)
    implementation(libs.material)
    implementation(libs.activity)
    implementation(libs.constraintlayout)
    implementation(libs.recyclerview)
    implementation(libs.cardview)
    implementation("androidx.swiperefreshlayout:swiperefreshlayout:1.1.0")
    // WorkManager 定时任务（用于保活）
    implementation("androidx.work:work-runtime:2.9.0")

    // gRPC (VHAL 信号监听)
    implementation("io.grpc:grpc-okhttp:1.62.2")
    implementation("io.grpc:grpc-stub:1.62.2")

    testImplementation(libs.junit)
    androidTestImplementation(libs.ext.junit)
    androidTestImplementation(libs.espresso.core)
}
