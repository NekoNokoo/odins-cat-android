package com.odinone.desktop.vk

import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

class VpnRuntimeTileService : TileService() {
    override fun onTileAdded() {
        super.onTileAdded()
        updateTile(VpnRuntimeStore.snapshot(this))
    }

    override fun onStartListening() {
        super.onStartListening()
        updateTile(VpnRuntimeStore.snapshot(this))
    }

    override fun onClick() {
        super.onClick()
        val snapshot = VpnRuntimeStore.snapshot(this)
        val active = isActiveTunnelStatus(snapshot.status)
        val intent =
            Intent(this, VpnRuntimeService::class.java).apply {
                action = VpnRuntimeService.ACTION_TOGGLE
            }

        updateTile(snapshot, pending = true, nextActive = !active)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun updateTile(
        snapshot: TunnelSnapshot,
        pending: Boolean = false,
        nextActive: Boolean = isActiveTunnelStatus(snapshot.status),
    ) {
        val tile = qsTile ?: return
        tile.label = "Odin's Cat"
        tile.contentDescription = "Odin's Cat VPN"
        tile.state =
            if (nextActive) {
                Tile.STATE_ACTIVE
            } else {
                Tile.STATE_INACTIVE
            }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle =
                when {
                    pending && nextActive -> "Запуск VPN"
                    pending -> "Остановка VPN"
                    snapshot.status == "starting" -> "Подключение"
                    nextActive -> "VPN включён"
                    else -> "VPN выключен"
                }
        }
        tile.updateTile()
    }
}
