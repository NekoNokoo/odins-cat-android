import java.io.File
import org.apache.tools.ant.taskdefs.condition.Os
import org.gradle.api.DefaultTask
import org.gradle.api.GradleException
import org.gradle.api.logging.LogLevel
import org.gradle.api.tasks.Input
import org.gradle.api.tasks.TaskAction

open class BuildTask : DefaultTask() {
    @Input
    var rootDirRel: String? = null
    @Input
    var target: String? = null
    @Input
    var release: Boolean? = null

    @TaskAction
    fun assemble() {
        val executable = resolveNpmExecutable();
        try {
            runTauriCli(executable)
        } catch (e: Exception) {
            if (Os.isFamily(Os.FAMILY_WINDOWS)) {
                // Try different Windows-specific extensions
                val fallbacks = listOf(
                    "$executable.exe",
                    "$executable.cmd",
                    "$executable.bat",
                )
                
                var lastException: Exception = e
                for (fallback in fallbacks) {
                    try {
                        runTauriCli(fallback)
                        return
                    } catch (fallbackException: Exception) {
                        lastException = fallbackException
                    }
                }
                throw lastException
            } else {
                throw e;
            }
        }
    }

    private fun resolveNpmExecutable(): String {
        val explicit = listOf(
            System.getenv("ODIN_ONE_NPM"),
            System.getenv("NPM_EXECUTABLE"),
        ).firstOrNull { !it.isNullOrBlank() }?.trim()
        if (!explicit.isNullOrBlank()) {
            return explicit
        }
        val pathEntries = (System.getenv("PATH") ?: "")
            .split(File.pathSeparator)
            .filter { it.isNotBlank() }
        val candidates = buildList {
            add("npm")
            for (entry in pathEntries) {
                add(File(entry, "npm").absolutePath)
                if (Os.isFamily(Os.FAMILY_WINDOWS)) {
                    add(File(entry, "npm.cmd").absolutePath)
                    add(File(entry, "npm.exe").absolutePath)
                    add(File(entry, "npm.bat").absolutePath)
                }
            }
        }
        return candidates.firstOrNull { File(it).canExecute() } ?: "npm"
    }

    fun runTauriCli(executable: String) {
        val rootDirRel = rootDirRel ?: throw GradleException("rootDirRel cannot be null")
        val target = target ?: throw GradleException("target cannot be null")
        val release = release ?: throw GradleException("release cannot be null")
        val args = listOf("run", "--", "tauri", "android", "android-studio-script");

        project.exec {
            workingDir(File(project.projectDir, rootDirRel))
            executable(executable)
            args(args)
            if (project.logger.isEnabled(LogLevel.DEBUG)) {
                args("-vv")
            } else if (project.logger.isEnabled(LogLevel.INFO)) {
                args("-v")
            }
            if (release) {
                args("--release")
            }
            args(listOf("--target", target))
        }.assertNormalExitValue()
    }
}
