pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories { google(); mavenCentral() }
}
rootProject.name = "NeuroNEngine"
include(":model", ":project", ":hf", ":engine", ":rag", ":train", ":server", ":copilot")
// UI Android ada di flutter_app/ (build terpisah: `flutter build apk`). Lihat docs/MIGRASI_FLUTTER.md
