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
subprojects {
    project.evaluationDependsOn(":app")
}

// Several third-party plugins (tflite_flutter 0.12.1, flutter_tts, and
// likely others pulled in this session — speech_to_text, firebase_auth,
// firebase_core all print the same "applies Kotlin Gradle Plugin" warning)
// ship an Android module whose own build.gradle sets a Java compileOptions
// target the Kotlin Gradle Plugin (2.4.0, pinned in settings.gradle.kts)
// doesn't automatically match on `compileDebugKotlin`, which Gradle then
// rejects outright ("Inconsistent JVM Target Compatibility Between Java
// and Kotlin Tasks") rather than just warning.
//
// Four escalating attempts before this one, in task.md's Round history if
// the full story is ever needed again — the short version of what didn't
// work:
//   1/2. Forcing *Java's* side up to 17 project-wide, two different ways
//        (plain `subprojects`, then `subprojects { afterEvaluate {} }`) —
//        both do fix the JVM mismatch, but confirmed live to also corrupt
//        `geolocator_android`'s Android SDK classpath ("package
//        android.content does not exist" x100). geolocator_android was
//        never one of the plugins with a mismatch to begin with, so
//        blanket-touching every subproject's `JavaCompile` task broke an
//        unrelated, previously-working module as collateral damage.
//   3. Forcing *Kotlin's* side down to a single hardcoded value (11) for
//      every subproject except `:app` — fixes the plugins whose Java side
//      is 11, but confirmed live to break `audioplayers_android`, whose
//      Java side is *already* 17 (so forcing Kotlin down to 11 introduces
//      the exact same mismatch in reverse). Different plugins in this
//      dependency set genuinely disagree on their own Java target — no
//      single hardcoded value is correct for all of them.
// The fix that's actually safe: per subproject, read whatever that
// specific subproject's own Java target already is (never overwritten —
// side-steps the classpath-corruption risk entirely) and set Kotlin's
// jvmTarget to match *that*, whatever it happens to be. Self-adapting, so
// it can't clash with a plugin this project doesn't even know about yet.
gradle.projectsEvaluated {
    subprojects {
        // `:app` excluded — already internally consistent at 17/17 via
        // its own build.gradle.kts, nothing to reconcile.
        if (project.path == ":app") return@subprojects
        val javaTarget =
            tasks.withType<JavaCompile>().firstOrNull()?.targetCompatibility ?: return@subprojects
        val kotlinTarget =
            org.jetbrains.kotlin.gradle.dsl.JvmTarget.values().firstOrNull { it.target == javaTarget }
                ?: return@subprojects
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            compilerOptions {
                jvmTarget.set(kotlinTarget)
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
