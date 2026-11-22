allprojects {
    repositories {
        google()
        // Only the checksum-verified native test runtime is supplied locally.
        // Every other dependency keeps its normal remote repository resolution.
        mavenLocal {
            content { includeModule("org.robolectric", "nativeruntime-dist-compat") }
        }
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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
