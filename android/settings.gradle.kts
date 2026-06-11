pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        maven { url = uri("https://build-artifacts.signal.org/libraries/maven/") }
    }
}

rootProject.name = "BurnBar"
include(":app")
include(":openburnbar-iroh-relay")
// Macrobenchmark + baseline-profile producer (on-device only; see module README header).
include(":macrobenchmark")
