plugins {
    id("org.jetbrains.kotlin.jvm") version "2.1.20"
    application
}
kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }
java { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
sourceSets {
    main {
        kotlin.srcDir("../app/src/main/java/com/tokkah/kin/net")
    }
}
application { mainClass = "com.tokkah.kin.harness.MainKt" }
