allprojects {
    repositories {
        google()
        mavenCentral()
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

// Flutter plugin (e.g. file_picker) modules set their own compileSdk from
// flutter.compileSdkVersion, which can lag behind what newer plugin
// dependencies (e.g. flutter_plugin_android_lifecycle) require. Force every
// Android module in the project to compile against API 36 so this stays
// consistent regardless of the installed Flutter SDK's default.
// NOTE: this must be registered before evaluationDependsOn(":app") below,
// otherwise :app gets evaluated early and this afterEvaluate hook throws
// "Cannot run Project.afterEvaluate(Action) when the project is already evaluated."
subprojects {
    afterEvaluate {
        extensions.findByName("android")?.let { ext ->
            if (ext is com.android.build.api.dsl.CommonExtension) {
                ext.compileSdk = 36
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
