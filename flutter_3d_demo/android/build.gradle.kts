allprojects {
    repositories {
        // 阿里云镜像优先（本机代理下载大文件会被截断），找不到再回落官方源
        maven("https://maven.aliyun.com/repository/google")
        maven("https://maven.aliyun.com/repository/central")
        maven("https://maven.aliyun.com/repository/public")
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

// 本机代理会截断 sdkmanager 的大文件下载，导致 AGP 自动安装 NDK r28c 失败。
// Flutter master 默认钉住 ndkVersion = 28.2.13676358（如 jni 插件模块直接引用
// flutter.ndkVersion），这里在模块评估完成后统一覆盖为本机已装的 27.2.12479018。
// 必须在 afterEvaluate 中执行，才能覆盖插件自身 build 脚本里设置的值。
val localNdkVersion = "27.2.12479018"

fun Project.forceLocalNdkVersion() {
    extensions.findByName("android")?.let { androidExt ->
        runCatching {
            androidExt.javaClass
                .getMethod("setNdkVersion", String::class.java)
                .invoke(androidExt, localNdkVersion)
        }
    }
}

subprojects {
    // 上面的 evaluationDependsOn(":app") 会立即完成 :app 评估，
    // 对已评估的模块只能直接覆盖，未评估的模块注册 afterEvaluate。
    if (state.executed) {
        forceLocalNdkVersion()
    } else {
        afterEvaluate { forceLocalNdkVersion() }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
