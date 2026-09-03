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
tasks.register<JavaExec>("call") {
    classpath = sourceSets["main"].runtimeClasspath
    mainClass.set("com.tokkah.kin.harness.CallMain")
}

dependencies { implementation("org.bouncycastle:bcprov-jdk18on:1.79") }
