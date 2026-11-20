allprojects {
    repositories {
        google()
        mavenCentral()
        // RTC artifacts are published in Volcengine's own Maven repository.
        maven {
            url = uri("https://artifact.bytedance.com/repository/Volcengine/")
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
    if (name == "volc_engine_rtc") {
        // The locked RTC plugin declares API 33, while its resolved AndroidX
        // dependencies require newer APIs. Keep this override Android-only.
        afterEvaluate {
            extensions.configure<com.android.build.gradle.LibraryExtension> {
                compileSdkVersion(36)
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
