package com.odinone.desktop.vk

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Base64
import android.util.Log
import app.tauri.plugin.JSObject

class VpnRuntimeDebugReceiver : BroadcastReceiver() {
    override fun onReceive(
        context: Context,
        intent: Intent?,
    ) {
        if (!BuildConfig.DEBUG) {
            return
        }

        when (intent?.action) {
            ACTION_DEBUG_START -> startFromIntent(context, intent)
            ACTION_DEBUG_STOP -> stopFromIntent(context)
            ACTION_DEBUG_RUN_TEST -> runConnectivityTestFromIntent(context, intent)
            ACTION_DEBUG_REFRESH_RELAY_AUTOSELECT -> refreshRelayAutoselectFromIntent(context, intent)
        }
    }

    private fun startFromIntent(
        context: Context,
        intent: Intent,
    ) {
        val startArgs =
            decodeStartArgs(intent)
                ?: VpnRuntimeRestoreStore.readStartRequest(context)?.toString()

        if (startArgs.isNullOrBlank()) {
            recordDebugBridgeFailure(
                context = context,
                code = "missing_request",
                message = "Debug bridge could not find a persisted Android VPN start request.",
            )
            return
        }

        val request =
            runCatching { JSObject(startArgs) }
                .getOrElse { error ->
                    recordDebugBridgeFailure(
                        context = context,
                        code = "invalid_request",
                        message = "Debug bridge received malformed start args: ${error.message ?: error::class.java.simpleName}",
                    )
                    return
                }
        request.put("startSource", "debug_bridge")

        val dispatchIntent =
            Intent(context, VpnRuntimeService::class.java).apply {
                action = VpnRuntimeService.ACTION_START
                putExtra(VpnRuntimeService.EXTRA_START_ARGS, request.toString())
            }
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(dispatchIntent)
            } else {
                context.startService(dispatchIntent)
            }
        }.onSuccess {
            Log.i(
                "VpnRuntimeDebugReceiver",
                "Debug bridge dispatched Android VPN start request for runtimeFamily=${request.getString("runtimeFamily", "<unknown>") ?: "<unknown>"}",
            )
        }.onFailure { error ->
            recordDebugBridgeFailure(
                context = context,
                code = "dispatch_failed",
                message = "Debug bridge failed to dispatch Android VPN service start: ${error.message ?: error::class.java.simpleName}",
            )
        }
    }

    private fun decodeStartArgs(intent: Intent): String? {
        val encoded =
            intent.getStringExtra(VpnRuntimeService.EXTRA_START_ARGS_BASE64)
                ?.takeIf { it.isNotBlank() }
        if (!encoded.isNullOrBlank()) {
            return runCatching {
                String(Base64.decode(encoded, Base64.DEFAULT), Charsets.UTF_8)
            }.getOrNull()?.takeIf { it.isNotBlank() }
        }
        return intent.getStringExtra(VpnRuntimeService.EXTRA_START_ARGS)
            ?.takeIf { it.isNotBlank() }
    }

    private fun stopFromIntent(context: Context) {
        val current = VpnRuntimeStore.snapshot(context)
        val dispatchIntent =
            Intent(context, VpnRuntimeService::class.java).apply {
                action = VpnRuntimeService.ACTION_STOP
            }
        val serviceIntent = Intent(context, VpnRuntimeService::class.java)
        runCatching {
            if (current.status == "running" || current.status == "starting") {
                context.startService(dispatchIntent)
            } else {
                context.stopService(serviceIntent)
            }
        }.onSuccess {
            Log.i("VpnRuntimeDebugReceiver", "Debug bridge dispatched Android VPN stop request.")
        }.onFailure { error ->
            val fallbackStopped =
                runCatching { context.stopService(serviceIntent) }
                    .getOrDefault(false)
            if (fallbackStopped) {
                val latest = VpnRuntimeStore.snapshot(context)
                VpnRuntimeStore.write(
                    context,
                    latest.copy(
                        status = "stopped",
                        socksAddress = null,
                        bridgeAddress = null,
                        error = null,
                        logTail = trimLogTail(latest.logTail + "Debug bridge force-stopped Android VPN service after ACTION_STOP dispatch failed."),
                    ),
                    sync = true,
                )
                Log.i("VpnRuntimeDebugReceiver", "Debug bridge force-stopped Android VPN service after dispatch failure.")
            } else {
                recordDebugBridgeFailure(
                    context = context,
                    code = "stop_failed",
                    message = "Debug bridge failed to dispatch Android VPN service stop: ${error.message ?: error::class.java.simpleName}",
                )
            }
        }
    }

    private fun runConnectivityTestFromIntent(
        context: Context,
        intent: Intent,
    ) {
        val targetUrl =
            intent.getStringExtra(EXTRA_TEST_URL)
                ?.takeIf { it.isNotBlank() }
                ?: "https://example.com"

        Thread(
            {
                runCatching {
                    val snapshot = VpnRuntimeLibbox.runConnectivityTest(context, targetUrl)
                    Log.i(
                        "VpnRuntimeDebugReceiver",
                        "Debug bridge completed Android VPN connectivity test for $targetUrl with status=${snapshot.lastTest?.status ?: "<unknown>"}",
                    )
                }.onFailure { error ->
                    val current = VpnRuntimeStore.snapshot(context)
                    VpnRuntimeStore.write(
                        context,
                        current.copy(
                            lastTest = TunnelTestSnapshot(
                                ok = false,
                                status = "failed",
                                url = targetUrl,
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
                    Log.e("VpnRuntimeDebugReceiver", "Debug bridge connectivity test crashed", error)
                }
            },
            "odin-one-debug-connectivity-test",
        ).apply {
            isDaemon = true
            start()
        }
    }

    private fun refreshRelayAutoselectFromIntent(
        context: Context,
        intent: Intent,
    ) {
        val request =
            decodeStartArgs(intent)
                ?.let { payload -> runCatching { JSObject(payload) }.getOrNull() }
                ?: VpnRuntimeRestoreStore.readAttemptedStartRequest(context)
                ?: VpnRuntimeRestoreStore.readStartRequest(context)

        if (request == null) {
            recordDebugBridgeFailure(
                context = context,
                code = "missing_relay_request",
                message = "Debug bridge could not find a relay autoselect request to refresh.",
            )
            return
        }

        Thread(
            {
                runCatching {
                    val state =
                        RealityRelayAutoselect.refreshNow(
                            context = context,
                            request = request,
                            trigger = "debug_bridge",
                        )
                    Log.i(
                        "VpnRuntimeDebugReceiver",
                        "Debug bridge refreshed relay autoselect with status=${state.status} best=${state.bestCandidate?.sni ?: "<none>"}",
                    )
                }.onFailure { error ->
                    recordDebugBridgeFailure(
                        context = context,
                        code = "relay_refresh_failed",
                        message = "Debug bridge relay autoselect refresh failed: ${error.message ?: error::class.java.simpleName}",
                    )
                    Log.e("VpnRuntimeDebugReceiver", "Debug bridge relay autoselect refresh crashed", error)
                }
            },
            "odin-one-debug-relay-autoselect-refresh",
        ).apply {
            isDaemon = true
            start()
        }
    }

    private fun recordDebugBridgeFailure(
        context: Context,
        code: String,
        message: String,
    ) {
        val current = VpnRuntimeStore.snapshot(context)
        VpnRuntimeStore.write(
            context,
            failedSnapshot(
                current,
                "Android debug bridge request failed.",
                message,
            ).copy(
                lastFailureCode = code,
            ),
        )
    }

    companion object {
        const val ACTION_DEBUG_START = "com.odinone.desktop.vk.action.DEBUG_START_VPN_RUNTIME"
        const val ACTION_DEBUG_STOP = "com.odinone.desktop.vk.action.DEBUG_STOP_VPN_RUNTIME"
        const val ACTION_DEBUG_RUN_TEST = "com.odinone.desktop.vk.action.DEBUG_RUN_VPN_CONNECTIVITY_TEST"
        const val ACTION_DEBUG_REFRESH_RELAY_AUTOSELECT = "com.odinone.desktop.vk.action.DEBUG_REFRESH_REALITY_RELAY_AUTOSELECT"
        const val EXTRA_TEST_URL = "test_url"
    }
}
