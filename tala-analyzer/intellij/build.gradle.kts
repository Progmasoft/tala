/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

plugins {
    kotlin("jvm") version "2.4.0"
    id("org.jetbrains.intellij.platform") version "2.19.0"
    id("org.jetbrains.dokka") version "2.2.0"
}

group = "com.progmasoft.tala.analyzer"
version = "0.1.0"

repositories {
    mavenCentral()
    intellijPlatform { defaultRepositories() }
}

dependencies {
    intellijPlatform { intellijIdea("2026.2.3") }
}

kotlin { jvmToolchain(25) }

sourceSets {
    main {
        kotlin.srcDir("sources/main/kotlin")
        resources.srcDir("sources/main/resources")
    }
    test {
        kotlin.srcDir("sources/test/kotlin")
    }
}

tasks.patchPluginXml {
    pluginVersion = project.version.toString()
}

dokka {
    dokkaPublications.html {
        moduleName.set("Tala Analyzer IntelliJ Host")
        outputDirectory.set(layout.buildDirectory.dir("dokka/html"))
    }
}
