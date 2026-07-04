package com.odinone.desktop.vk

import android.Manifest
import android.content.Intent
import android.os.Bundle
import android.os.Build
import androidx.activity.enableEdgeToEdge

class MainActivity : TauriActivity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    enableEdgeToEdge()
    super.onCreate(savedInstanceState)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
      requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7301)
    }
    startService(
      Intent(this, VpnRuntimeService::class.java).apply {
        action = VpnRuntimeService.ACTION_SHOW_STATUS
      },
    )
  }
}
