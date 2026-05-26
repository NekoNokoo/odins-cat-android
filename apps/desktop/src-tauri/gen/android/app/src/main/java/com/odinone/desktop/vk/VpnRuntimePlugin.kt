package com.odinone.desktop.vk

import android.app.Activity
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.net.VpnService
import android.util.Log
import androidx.activity.result.ActivityResult
import androidx.core.content.FileProvider
import app.tauri.annotation.ActivityCallback
import app.tauri.annotation.Command
import app.tauri.annotation.InvokeArg
import app.tauri.annotation.TauriPlugin
import app.tauri.plugin.Invoke
import app.tauri.plugin.JSArray
import app.tauri.plugin.JSObject
import app.tauri.plugin.Plugin
import java.io.File
import java.io.IOException
import kotlin.concurrent.thread
import org.json.JSONArray

@InvokeArg
class StartTunnelArgs {
    lateinit var serverHost: String
    lateinit var transport: String
    lateinit var engine: String
    lateinit var protocol: String
    var vkLink: String? = null
    var excludePackages: Array<String>? = null
    var profileJson: String? = null
    var profileSource: String? = null
    var useRealityStartEndpoint: Boolean = false
    var runtimeFamily: String? = null
    var activationState: String? = null
}

@InvokeArg
class ConnectivityTestArgs {
    var url: String = "https://example.com"
}

@InvokeArg
class SpeedTestArgs {
    var latencyUrl: String = "https://www.gstatic.com/generate_204"
    var downloadUrl: String = "https://speed.cloudflare.com/__down"
    var downloadBytes: Long = 250_000_000
    var warmupDurationMs: Long = 2_000
    var measureDurationMs: Long = 8_000
    var streamCount: Int = 8
}

@InvokeArg
class NetworkLensArgs {
    var originHost: String = ""
    var tunnelHost: String? = null
    var cellularOnly: Boolean = true
}

@InvokeArg
class SplitTunnelSelectionArgs {
    var excludePackages: Array<String> = emptyArray()
}

@InvokeArg
class NextSessionLogArgs {
    var enabled: Boolean = false
}

@InvokeArg
class ShareInviteFileArgs {
    var fileName: String = "odin-one-access.odinone-access.json"
    var contents: String = ""
    var mimeType: String = "application/json"
}

@InvokeArg
class ExportDebugLogArgs {
    var fileName: String = "whitelist-probe.log.txt"
    var contents: String = ""
    var mimeType: String = "text/plain"
}

@InvokeArg
class OpenExternalUrlArgs {
    var url: String = ""
}

@TauriPlugin
class VpnRuntimePlugin(private val activity: Activity) : Plugin(activity) {
    private var pendingStartPayload: String? = null

    @Command
    fun startTunnel(invoke: Invoke) {
        val args = invoke.parseArgs(StartTunnelArgs::class.java)
        val argsJson = JSObject()
        argsJson.put("serverHost", args.serverHost)
        argsJson.put("transport", args.transport)
        argsJson.put("engine", args.engine)
        argsJson.put("protocol", args.protocol)
        argsJson.put("vkLink", args.vkLink)
        args.excludePackages?.let { argsJson.put("excludePackages", JSArray(normalizeSplitTunnelPackages(it.toList()))) }
        argsJson.put("profileJson", args.profileJson)
        argsJson.put("profileSource", args.profileSource)
        argsJson.put("useRealityStartEndpoint", args.useRealityStartEndpoint)
        args.runtimeFamily?.trim()?.takeIf { it.isNotEmpty() }?.let { argsJson.put("runtimeFamily", it) }
        args.activationState?.trim()?.takeIf { it.isNotEmpty() }?.let { argsJson.put("activationState", it) }
        val normalizedArgs =
            VpnRuntimeLibbox.normalizeRuntimeArgs(
                activity,
                mergePersistedSplitTunnelSelection(
                    mergePersistedHiddenRuntimeOverrides(
                        previousRequest = VpnRuntimeRestoreStore.readStartRequest(activity),
                        incomingRequest = argsJson,
                    ),
                ),
            )
        normalizedArgs.put("startSource", "app")

        val current = VpnRuntimeStore.snapshot(activity)
        if (isActiveTunnelStatus(current.status) && matchesTunnelRequest(current, normalizedArgs)) {
            val reused =
                VpnRuntimeStore.write(
                    activity,
                    current.copy(
                        logTail = trimLogTail(current.logTail + "Reusing identical Android VPN runtime request from plugin."),
                    ),
                )
            invoke.resolve(reused.toJsObject())
            return
        }

        val prepareIntent = VpnService.prepare(activity)
        if (prepareIntent != null) {
            pendingStartPayload = normalizedArgs.toString()
            startActivityForResult(invoke, prepareIntent, "onVpnPrepared")
            return
        }

        val snapshot = launchTunnelService(normalizedArgs)
        invoke.resolve(snapshot.toJsObject())
    }

    @ActivityCallback
    fun onVpnPrepared(invoke: Invoke, result: ActivityResult) {
        val argsJson = pendingStartPayload
            ?.let { payload ->
                try {
                    JSObject(payload)
                } catch (_: Exception) {
                    null
                }
        }
        pendingStartPayload = null

        if (result.resultCode != Activity.RESULT_OK || argsJson == null) {
            val base = argsJson?.let { startSnapshotFromArgs(it, "VPN permission request was cancelled.") }
                ?: TunnelSnapshot()
            val snapshot = VpnRuntimeStore.write(
                activity,
                failedSnapshot(base, "VPN permission was denied by the user."),
            )
            invoke.resolve(snapshot.toJsObject())
            return
        }

        val current = VpnRuntimeStore.snapshot(activity)
        if (isActiveTunnelStatus(current.status) && matchesTunnelRequest(current, argsJson)) {
            val reused =
                VpnRuntimeStore.write(
                    activity,
                    current.copy(
                        logTail = trimLogTail(current.logTail + "Reusing identical Android VPN runtime request after permission flow."),
                    ),
                )
            invoke.resolve(reused.toJsObject())
            return
        }

        val snapshot = launchTunnelService(argsJson)
        invoke.resolve(snapshot.toJsObject())
    }

    @Command
    fun stopTunnel(invoke: Invoke) {
        val intent = Intent(activity, VpnRuntimeService::class.java).apply {
            action = VpnRuntimeService.ACTION_STOP
        }
        val previous = VpnRuntimeStore.snapshot(activity)
        val snapshot =
            VpnRuntimeStore.write(
                activity,
                previous.copy(
                    logTail = trimLogTail(previous.logTail + "Android VPN runtime stop requested from plugin."),
                ),
            )
        val dispatchError = dispatchServiceIntent(intent, requireForegroundStart = false)
        val resolved =
            dispatchError?.let { error ->
                VpnRuntimeStore.write(
                    activity,
                    failedSnapshot(
                        snapshot,
                        error.message ?: "Failed to stop the Android VPN runtime.",
                        "Service stop intent failed before the VpnService handled ACTION_STOP.",
                    ),
                )
            } ?: snapshot
        invoke.resolve(resolved.toJsObject())
    }

    @Command
    fun getStatus(invoke: Invoke) {
        invoke.resolve(VpnRuntimeStore.snapshot(activity).toJsObject())
    }

    @Command
    fun runConnectivityTest(invoke: Invoke) {
        val args = invoke.parseArgs(ConnectivityTestArgs::class.java)
        thread(name = "odin-one-connectivity-test", isDaemon = true) {
            Log.i("VpnRuntimeService", "VpnRuntimePlugin received runConnectivityTest for ${args.url}")
            runCatching {
                VpnRuntimeLibbox.runConnectivityTest(activity, args.url)
            }.onSuccess { snapshot ->
                invoke.resolve(snapshot.toJsObject())
            }.onFailure { error ->
                Log.e("VpnRuntimeService", "runConnectivityTest crashed before producing a snapshot", error)
                val current = VpnRuntimeStore.snapshot(activity)
                val failed =
                    VpnRuntimeStore.write(
                        activity,
                        current.copy(
                            lastTest = TunnelTestSnapshot(
                                ok = false,
                                status = "failed",
                                url = args.url.ifBlank { "https://example.com" },
                                error = error.message ?: "Android VPN connectivity test crashed.",
                                checkedAt = currentTimestamp(),
                            ),
                            logTail =
                                trimLogTail(
                                    current.logTail +
                                        "Connectivity test crashed before completion: ${error.message ?: "unknown error"}",
                                ),
                        ),
                        sync = true,
                    )
                invoke.resolve(failed.toJsObject())
            }
        }
    }

    @Command
    fun runSpeedTest(invoke: Invoke) {
        val args = invoke.parseArgs(SpeedTestArgs::class.java)
        thread(name = "odin-one-speed-test", isDaemon = true) {
            Log.i(
                "VpnRuntimeService",
                "VpnRuntimePlugin received runSpeedTest for ${args.downloadUrl} (${args.downloadBytes} bytes, ${args.streamCount} streams, warmup ${args.warmupDurationMs} ms, measure ${args.measureDurationMs} ms)",
            )
            runCatching {
                VpnRuntimeLibbox.runSpeedTest(
                    context = activity,
                    latencyUrl = args.latencyUrl,
                    downloadUrl = args.downloadUrl,
                    requestedDownloadBytes = args.downloadBytes,
                    warmupDurationMs = args.warmupDurationMs,
                    measureDurationMs = args.measureDurationMs,
                    streamCount = args.streamCount,
                )
            }.onSuccess { result ->
                invoke.resolve(result.toJsObject())
            }.onFailure { error ->
                Log.e("VpnRuntimeService", "runSpeedTest crashed before producing a result", error)
                invoke.resolve(
                    TunnelSpeedTestSnapshot(
                        ok = false,
                        status = "failed",
                        latencyUrl = args.latencyUrl,
                        downloadUrl = args.downloadUrl,
                        checkedAt = currentTimestamp(),
                        warmupDurationMs = args.warmupDurationMs,
                        streamCount = args.streamCount,
                        measuredViaTunnel = true,
                        error = error.message ?: "Android VPN speed test crashed.",
                    ).toJsObject(),
                )
            }
        }
    }

    @Command
    fun inspectNetworkLens(invoke: Invoke) {
        val args = invoke.parseArgs(NetworkLensArgs::class.java)
        thread(name = "odin-one-network-lens", isDaemon = true) {
            runCatching {
                VpnRuntimeLibbox.inspectNetworkLens(
                    context = activity,
                    originHost = args.originHost,
                    tunnelHost = args.tunnelHost,
                    cellularOnly = args.cellularOnly,
                )
            }.onSuccess { result ->
                invoke.resolve(result)
            }.onFailure { error ->
                Log.e("VpnRuntimeService", "inspectNetworkLens crashed before producing a result", error)
                invoke.resolve(
                    JSObject().apply {
                        put("available", false)
                        put("checkedAt", currentTimestamp())
                        put("networkType", "unknown")
                        put("isCellular", false)
                        put("whitelistStatus", "unknown")
                        put("error", error.message ?: "Android network lens crashed.")
                    },
                )
            }
        }
    }

    @Command
    fun listInstalledApps(invoke: Invoke) {
        invoke.resolve(
            JSObject().apply {
                put(
                    "apps",
                    JSArray(
                        com.odinone.desktop.vk.listInstalledApps(activity).map { app -> app.toJsObject() },
                    ),
                )
            },
        )
    }

    @Command
    fun getSplitTunnelSelection(invoke: Invoke) {
        invoke.resolve(SplitTunnelSelectionStore.read(activity).toJsObject())
    }

    @Command
    fun setSplitTunnelSelection(invoke: Invoke) {
        val args = invoke.parseArgs(SplitTunnelSelectionArgs::class.java)
        val stored = SplitTunnelSelectionStore.write(activity, args.excludePackages.toList())
        invoke.resolve(stored.toJsObject())
    }

    @Command
    fun getNextVpnSessionLogState(invoke: Invoke) {
        invoke.resolve(
            JSObject().apply {
                put("enabled", VpnSessionLogStore.isArmed(activity))
            },
        )
    }

    @Command
    fun setNextVpnSessionLogState(invoke: Invoke) {
        val args = invoke.parseArgs(NextSessionLogArgs::class.java)
        VpnSessionLogStore.setArmed(activity, args.enabled)
        invoke.resolve(
            JSObject().apply {
                put("enabled", args.enabled)
            },
        )
    }

    @Command
    fun shareInviteFile(invoke: Invoke) {
        val args = invoke.parseArgs(ShareInviteFileArgs::class.java)
        if (args.contents.isBlank()) {
            invoke.reject("Invite file contents are required.")
            return
        }

        runCatching {
            val sanitizedName =
                args.fileName
                    .ifBlank { "odin-one-access.odinone-access.json" }
                    .replace(Regex("[^A-Za-z0-9._-]"), "_")
            val savedInvite = saveInviteToPublicDownloads(sanitizedName, args.contents)

            val shareIntent =
                Intent(Intent.ACTION_SEND).apply {
                    type = args.mimeType.ifBlank { "application/json" }
                    putExtra(Intent.EXTRA_STREAM, savedInvite.uri)
                    putExtra(Intent.EXTRA_SUBJECT, sanitizedName)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
            val chooser = Intent.createChooser(shareIntent, sanitizedName).apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            activity.startActivity(chooser)

            JSObject().apply {
                put("ok", true)
                put("fileName", sanitizedName)
                put("exportPath", savedInvite.exportPath)
                put("contentUri", savedInvite.uri.toString())
            }
        }.onSuccess { payload ->
            invoke.resolve(payload)
        }.onFailure { error ->
            invoke.reject(error.message ?: "Failed to open Android share sheet.")
        }
    }

    @Command
    fun exportDebugLog(invoke: Invoke) {
        val args = invoke.parseArgs(ExportDebugLogArgs::class.java)
        if (args.contents.isBlank()) {
            invoke.reject("Debug log contents are required.")
            return
        }

        runCatching {
            val saved =
                VpnSessionLogStore.saveTextLog(
                    context = activity,
                    fileName = args.fileName,
                    contents = args.contents,
                    mimeType = args.mimeType.ifBlank { "text/plain" },
                )
            JSObject().apply {
                put("ok", true)
                put("fileName", args.fileName)
                put("exportPath", saved.exportPath)
            }
        }.onSuccess { payload ->
            invoke.resolve(payload)
        }.onFailure { error ->
            invoke.reject(error.message ?: "Failed to save debug log.")
        }
    }

    private data class SavedInviteFile(
        val uri: Uri,
        val exportPath: String,
    )

    private fun saveInviteToPublicDownloads(fileName: String, contents: String): SavedInviteFile {
        val folderName = "Odin's Cat"
        val relativePath = "${Environment.DIRECTORY_DOWNLOADS}/$folderName"
        val mimeType = "application/json"
        val bytes = contents.toByteArray(Charsets.UTF_8)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = activity.contentResolver
            val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
            val values =
                ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, fileName)
                    put(MediaStore.Downloads.MIME_TYPE, mimeType)
                    put(MediaStore.Downloads.RELATIVE_PATH, relativePath)
                    put(MediaStore.Downloads.IS_PENDING, 1)
                }
            val uri =
                resolver.insert(collection, values)
                    ?: throw IOException("Failed to create invite file in public Downloads.")
            try {
                resolver.openOutputStream(uri, "wt")?.use { output ->
                    output.write(bytes)
                    output.flush()
                } ?: throw IOException("Failed to open invite file output stream.")
                values.clear()
                values.put(MediaStore.Downloads.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            } catch (error: Exception) {
                resolver.delete(uri, null, null)
                throw error
            }
            return SavedInviteFile(
                uri = uri,
                exportPath = "${Environment.DIRECTORY_DOWNLOADS}/$folderName/$fileName",
            )
        }

        val downloadsDir =
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        val exportsDir = File(downloadsDir, folderName).apply { mkdirs() }
        val inviteFile = File(exportsDir, fileName)
        inviteFile.writeText(contents, Charsets.UTF_8)
        val uri =
            FileProvider.getUriForFile(
                activity,
                "${activity.packageName}.fileprovider",
                inviteFile,
            )
        return SavedInviteFile(
            uri = uri,
            exportPath = inviteFile.absolutePath,
        )
    }

    @Command
    fun openExternalUrl(invoke: Invoke) {
        val args = invoke.parseArgs(OpenExternalUrlArgs::class.java)
        val targetUrl = args.url.trim()
        if (targetUrl.isBlank()) {
            invoke.reject("External URL is required.")
            return
        }
        if (!targetUrl.startsWith("http://") && !targetUrl.startsWith("https://")) {
            invoke.reject("Only http and https URLs are supported.")
            return
        }

        runCatching {
            val viewIntent =
                Intent(Intent.ACTION_VIEW, Uri.parse(targetUrl)).apply {
                    addCategory(Intent.CATEGORY_BROWSABLE)
                }
            val chooser = Intent.createChooser(viewIntent, targetUrl).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            activity.startActivity(chooser)
            JSObject().apply {
                put("ok", true)
                put("url", targetUrl)
            }
        }.onSuccess { payload ->
            invoke.resolve(payload)
        }.onFailure { error ->
            Log.e("VpnRuntimeService", "Failed to open external URL $targetUrl", error)
            invoke.reject(error.message ?: "Failed to open external URL.")
        }
    }

    private fun launchTunnelService(args: JSObject): TunnelSnapshot {
        val normalizedArgs =
            VpnRuntimeLibbox.normalizeRuntimeArgs(
                activity,
                mergePersistedSplitTunnelSelection(
                    mergePersistedHiddenRuntimeOverrides(
                        previousRequest = VpnRuntimeRestoreStore.readStartRequest(activity),
                        incomingRequest = args,
                    ),
                ),
            )
        val current = VpnRuntimeStore.snapshot(activity)
        if (isActiveTunnelStatus(current.status) && matchesTunnelRequest(current, normalizedArgs)) {
            return VpnRuntimeStore.write(
                activity,
                current.copy(
                    logTail = trimLogTail(current.logTail + "Skipping duplicate Android VPN service launch for identical tunnel request."),
                ),
            )
        }

        val starting =
            VpnRuntimeStore.write(
            activity,
            startSnapshotFromArgs(normalizedArgs, "Android VPN permission granted. Starting VpnService..."),
        )

        val intent = Intent(activity, VpnRuntimeService::class.java).apply {
            action = VpnRuntimeService.ACTION_START
            putExtra(VpnRuntimeService.EXTRA_START_ARGS, normalizedArgs.toString())
        }
        val requiresForegroundStart = !isActiveTunnelStatus(current.status)
        val dispatchError = dispatchServiceIntent(intent, requireForegroundStart = requiresForegroundStart)
        return if (dispatchError == null) {
            VpnRuntimeStore.write(
                activity,
                starting.copy(
                    logTail =
                        trimLogTail(
                            starting.logTail +
                                if (requiresForegroundStart) {
                                    "Dispatching Android VPN service with foreground start."
                                } else {
                                    "Dispatching Android VPN service restart against the active VpnService."
                                },
                        ),
                ),
            )
        } else {
            VpnRuntimeStore.write(
                activity,
                failedSnapshot(
                    starting,
                    dispatchError.message ?: "Failed to start the Android VPN runtime.",
                    if (requiresForegroundStart) {
                        "Foreground Android VpnService launch failed before native runtime initialization."
                    } else {
                        "Android VpnService restart request failed before native runtime initialization."
                    },
                ),
            )
        }
    }

    private fun dispatchServiceIntent(
        intent: Intent,
        requireForegroundStart: Boolean,
    ): Throwable? =
        runCatching {
            if (requireForegroundStart && android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                activity.startForegroundService(intent)
            } else {
                activity.startService(intent)
            }
        }.exceptionOrNull()

    private fun mergePersistedSplitTunnelSelection(request: JSObject): JSObject =
        JSObject(request.toString()).apply {
            val incoming = optJSONArray("excludePackages")?.let(::parseRequestedPackages).orEmpty()
            if (incoming.isNotEmpty()) {
                put("excludePackages", JSArray(normalizeSplitTunnelPackages(incoming)))
                return@apply
            }
            val persisted = com.odinone.desktop.vk.SplitTunnelSelectionStore.read(activity).excludePackages
            if (persisted.isNotEmpty()) {
                put("excludePackages", JSArray(ArrayList(persisted)))
            }
        }

    private fun parseRequestedPackages(array: JSONArray): List<String> =
        buildList(array.length()) {
            for (index in 0 until array.length()) {
                val value = array.optString(index, "").trim()
                if (value.isNotEmpty()) {
                    add(value)
                }
            }
        }
}
