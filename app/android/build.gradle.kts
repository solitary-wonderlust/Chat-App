allprojects {
    repositories {
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/central") }
        maven { url = uri("https://maven.aliyun.com/repository/gradle-plugin") }
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
subprojects {
    project.evaluationDependsOn(":app")
}

// Flutter 3.47 要求 compileSdk >= 36，但部分插件（如 file_picker 8.3.7）硬编码了 34。
// 在插件求值后、AGP 读取（锁定）compileSdk 之前，统一强制为 36。:app 已用 flutter.compileSdkVersion=36，跳过。
subprojects {
    if (name == "app") return@subprojects
    afterEvaluate {
        val android = extensions.findByName("android") ?: return@afterEvaluate
        android.javaClass.methods
            .firstOrNull { it.name == "setCompileSdk" && it.parameterCount == 1 }
            ?.invoke(android, 36)
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
