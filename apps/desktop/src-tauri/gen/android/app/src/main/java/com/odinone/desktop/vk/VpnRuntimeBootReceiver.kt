package com.odinone.desktop.vk

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import app.tauri.plugin.JSObject

class VpnRuntimeBootReceiver : BroadcastReceiver() {
    override fun onReceive(
        context: Context,
        intent: Intent?,
    ) {
        val broadcastAction = intent?.action ?: return
        if (broadcastAction != Intent.ACTION_BOOT_COMPLETED && broadcastAction != Intent.ACTION_MY_PACKAGE_REPLACED) {
            return
        }

        val restoreDecision =
            classifyBootRestoreAvailability(
                resumeEligible = VpnRuntimeRestoreStore.isResumeEligible(context),
                bootRestoreEnabled = VpnRuntimeRestoreStore.isBootRestoreEnabled(context),
                request = VpnRuntimeRestoreStore.readStartRequest(context),
            )
        if (restoreDecision != "available") {
            persistRestoreDecision(
                context = context,
                action = "skip",
                detail = restoreDecision,
                message = "Skipping Android REALITY boot restore for broadcast=$broadcastAction. reason=$restoreDecision",
            )
            return
        }

        val restoredArgs = VpnRuntimeRestoreStore.readStartRequest(context) ?: return
        val request =
            runCatching { JSObject(restoredArgs.toString()) }
                .getOrElse { restoredArgs }
        request.put("startSource", "boot_restore")
        persistRestoreDecision(
            context = context,
            action = "attempt",
            detail = "available",
            message = "Starting Android REALITY boot restore for broadcast=$broadcastAction.",
        )

        val serviceIntent =
            Intent(context, VpnRuntimeService::class.java).apply {
                action = VpnRuntimeService.ACTION_START
                putExtra(VpnRuntimeService.EXTRA_START_ARGS, request.toString())
            }
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
            } else {
                context.startService(serviceIntent)
            }
        }.onFailure { error ->
            persistRestoreDecision(
                context = context,
                action = "failed",
                detail = "start_service",
                message = "Android REALITY boot restore failed to start the foreground service: ${error.message ?: error::class.java.simpleName}",
            )
        }
    }

    private fun persistRestoreDecision(
        context: Context,
        action: String,
        detail: String,
        message: String,
    ) {
        val current = VpnRuntimeStore.snapshot(context)
        VpnRuntimeStore.write(
            context,
            withPersistedTunnelFlags(
                context,
                current.copy(
                    lastRecoveryAction = "restore:$action:boot:$detail",
                    lastNetworkEvent = "restore:boot:$detail",
                    logTail = trimLogTail(current.logTail + message),
                ),
            ),
        )
    }
}
