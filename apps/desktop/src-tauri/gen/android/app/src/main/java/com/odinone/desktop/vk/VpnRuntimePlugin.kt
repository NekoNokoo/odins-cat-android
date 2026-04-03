package com.odinone.desktop.vk

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import android.util.Log
import androidx.activity.result.ActivityResult
import app.tauri.annotation.ActivityCallback
import app.tauri.annotation.Command
import app.tauri.annotation.InvokeArg
import app.tauri.annotation.TauriPlugin
import app.tauri.plugin.Invoke
import app.tauri.plugin.JSObject
import app.tauri.plugin.Plugin
import kotlin.concurrent.thread

@InvokeArg
class StartTunnelArgs {
    lateinit var serverHost: String
    lateinit var transport: String
    lateinit var engine: String
    lateinit var protocol: String
    var vkLink: String? = null
    var profileJson: String? = null
    var profileSource: String? = null
    var useRealityStartEndpoint: Boolean = false
}

@InvokeArg
class ConnectivityTestArgs {
    var url: String = "https://example.com"
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
        argsJson.put("profileJson", args.profileJson)
        argsJson.put("profileSource", args.profileSource)
        argsJson.put("useRealityStartEndpoint", args.useRealityStartEndpoint)
        val normalizedArgs =
            VpnRuntimeLibbox.normalizeRuntimeArgs(
                activity,
                mergePersistedHiddenRuntimeOverrides(
                    previousRequest = VpnRuntimeRestoreStore.readStartRequest(activity),
                    incomingRequest = argsJson,
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

    private fun launchTunnelService(args: JSObject): TunnelSnapshot {
        val normalizedArgs =
            VpnRuntimeLibbox.normalizeRuntimeArgs(
                activity,
                mergePersistedHiddenRuntimeOverrides(
                    previousRequest = VpnRuntimeRestoreStore.readStartRequest(activity),
                    incomingRequest = args,
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
}
