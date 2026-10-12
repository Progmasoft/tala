/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

import org.gradle.api.JavaVersion
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    kotlin("jvm") version "2.4.0"
    jacoco
    id("com.diffplug.spotless") version "8.9.0"
    application
}

group = "com.progmasoft.talafmt"
version = "0.1.1"

repositories { mavenCentral() }

dependencies {
    // Kotlin 2.4 publishes the scripting host with an intentionally lean POM.
    // Keep the scripting API layers explicit so the evaluator has the compiler,
    // host and script-definition contracts in both development and distributions.
    implementation(kotlin("scripting-common"))
    implementation(kotlin("scripting-jvm"))
    implementation(kotlin("scripting-jvm-host"))
    implementation(kotlin("compiler-embeddable"))
    testImplementation(kotlin("test"))
}

application {
    mainClass = "com.progmasoft.talafmt.config.MainKt"
    applicationName = "talafmt-config"
}

kotlin {
    jvmToolchain(25)
    compilerOptions {
        jvmTarget = JvmTarget.JVM_25
        allWarningsAsErrors = true
    }
}

java {
    sourceCompatibility = JavaVersion.VERSION_25
    targetCompatibility = JavaVersion.VERSION_25
}

sourceSets {
    main { kotlin.srcDir("sources/main/kotlin") }
    test { kotlin.srcDir("sources/test/kotlin") }
}

spotless {
    kotlin {
        target("sources/**/*.kt")
        ktfmt().googleStyle()
        trimTrailingWhitespace()
        endWithNewline()
    }
    kotlinGradle {
        target("*.gradle.kts")
        ktlint()
        trimTrailingWhitespace()
        endWithNewline()
    }
}

tasks.test { useJUnitPlatform() }

jacoco { toolVersion = "0.8.15" }

tasks.jacocoTestReport {
    dependsOn(tasks.test)
    reports {
        xml.required = true
        html.required = false
    }
}
