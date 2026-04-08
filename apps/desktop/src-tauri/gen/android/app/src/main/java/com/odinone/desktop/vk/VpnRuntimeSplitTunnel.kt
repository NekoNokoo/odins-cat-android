package com.odinone.desktop.vk

import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build
import app.tauri.plugin.JSArray
import app.tauri.plugin.JSObject
import java.util.Locale
import org.json.JSONArray

private const val SPLIT_TUNNEL_PREFS_NAME = "odin_one_split_tunnel"
private const val SPLIT_TUNNEL_SELECTION_KEY = "selection"

data class InstalledAppInfoSnapshot(
    val packageName: String,
    val appName: String,
    val systemApp: Boolean,
) {
    fun toJsObject(): JSObject =
        JSObject().apply {
            put("packageName", packageName)
            put("appName", appName)
            put("systemApp", systemApp)
        }
}

data class SplitTunnelSelectionState(
    val excludePackages: List<String> = emptyList(),
    val updatedAt: String? = null,
) {
    fun toJsObject(): JSObject =
        JSObject().apply {
            put("excludePackages", JSArray(excludePackages))
            put("updatedAt", updatedAt)
        }

    companion object {
        fun fromObject(obj: JSObject): SplitTunnelSelectionState =
            SplitTunnelSelectionState(
                excludePackages = normalizeSplitTunnelPackages(parseStringArray(obj, "excludePackages")),
                updatedAt = obj.getString("updatedAt", null),
            )
    }
}

object SplitTunnelSelectionStore {
    fun read(context: Context): SplitTunnelSelectionState {
        val raw = prefs(context).getString(SPLIT_TUNNEL_SELECTION_KEY, null)
        if (raw.isNullOrBlank()) {
            return SplitTunnelSelectionState()
        }
        return runCatching { SplitTunnelSelectionState.fromObject(JSObject(raw)) }
            .getOrElse { SplitTunnelSelectionState() }
    }

    fun write(
        context: Context,
        excludePackages: Collection<String>,
    ): SplitTunnelSelectionState {
        val next =
            SplitTunnelSelectionState(
                excludePackages = normalizeSplitTunnelPackages(excludePackages),
                updatedAt = currentTimestamp(),
            )
        prefs(context)
            .edit()
            .putString(SPLIT_TUNNEL_SELECTION_KEY, next.toJsObject().toString())
            .apply()
        return next
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(SPLIT_TUNNEL_PREFS_NAME, Context.MODE_PRIVATE)
}

fun normalizeSplitTunnelPackages(packages: Collection<String>): List<String> =
    packages
        .asSequence()
        .map(String::trim)
        .filter(String::isNotEmpty)
        .map(String::lowercase)
        .distinct()
        .sorted()
        .toList()

fun parseStringArray(
    obj: JSObject,
    key: String,
): List<String> = obj.optJSONArray(key)?.let(::parseStringArray).orEmpty()

fun parseStringArray(array: JSONArray): List<String> =
    buildList(array.length()) {
        for (index in 0 until array.length()) {
            val value = array.optString(index, "").trim()
            if (value.isNotEmpty()) {
                add(value)
            }
        }
    }

fun listInstalledApps(context: Context): List<InstalledAppInfoSnapshot> {
    val packageManager = context.packageManager
    val byPackage = linkedMapOf<String, InstalledAppInfoSnapshot>()
    val selectedPackages = SplitTunnelSelectionStore.read(context).excludePackages.toSet()
    val installedApplications =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getInstalledApplications(PackageManager.ApplicationInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            packageManager.getInstalledApplications(0)
        }

    installedApplications.forEach { applicationInfo ->
        val packageName = applicationInfo.packageName?.trim().orEmpty()
        if (packageName.isBlank() || packageName == context.packageName) {
            return@forEach
        }

        val systemApp =
            (applicationInfo.flags and ApplicationInfo.FLAG_SYSTEM) != 0 ||
                (applicationInfo.flags and ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) != 0
        val hasLauncherEntry =
            packageManager.getLaunchIntentForPackage(packageName) != null ||
                packageManager.getLeanbackLaunchIntentForPackage(packageName) != null
        val shouldExpose = !systemApp || hasLauncherEntry || selectedPackages.contains(packageName)
        if (!shouldExpose) {
            return@forEach
        }

        val label =
            applicationInfo.loadLabel(packageManager)?.toString()?.trim().takeUnless { it.isNullOrBlank() }
                ?: packageName

        byPackage.putIfAbsent(
            packageName,
            InstalledAppInfoSnapshot(
                packageName = packageName,
                appName = label,
                systemApp = systemApp,
            ),
        )
    }

    return byPackage.values.sortedWith(
        compareBy<InstalledAppInfoSnapshot>(
            { it.systemApp },
            { it.appName.lowercase(Locale.ROOT) },
            { it.packageName },
        ),
    )
}
