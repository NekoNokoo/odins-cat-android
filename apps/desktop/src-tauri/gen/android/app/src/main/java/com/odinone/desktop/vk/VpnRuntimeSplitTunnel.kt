package com.odinone.desktop.vk

import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import app.tauri.plugin.JSArray
import app.tauri.plugin.JSObject
import java.util.Locale
import org.json.JSONArray

private const val SPLIT_TUNNEL_PREFS_NAME = "odin_one_split_tunnel"
private const val SPLIT_TUNNEL_SELECTION_KEY = "selection"

private val DEFAULT_SPLIT_TUNNEL_EXCLUDE_PACKAGES =
    normalizeSplitTunnelPackages(
        listOf(
            // Confirmed in the current VPN-detection research or already high-risk.
            "com.yandex.browser",
            "ru.yandex.searchplugin",
            "ru.yandex.yandexmaps",
            "com.vkontakte.android",
            "ru.mts",
            "ru.sberbankmobile",
            "com.idamob.tinkoff.android",
            "com.vk.vkvideo",
            "com.wildberries.ru",
            "ru.kinopoisk",
            "ru.ozon.app.android",
            "ru.samokat.app",
            "ru.vk.store",
            "ru.vtb24.mobilebanking.android",
            "ru.yandex.music",
            "com.avito.android",
            "ru.alfabank.mobile.android",
            "ru.dublgis.dgismobile",
            "ru.sbermegamarket",
            "ru.megafon.mlk",
            "ru.megafon.lk",
            "ru.ok.android",
            "ru.oneme.app",
            "com.vk.music",
            "rtb.mobile.android",
            // Best-effort aliases and adjacent apps we also want outside the VPN by default.
            "ru.beru.android",
            "ru.yandex.market",
            "ru.foodfox.client",
            "ru.mail.mailapp",
            "ru.nspk.mirpay",
            "ru.rostel",
            "ru.yandex.taxi",
            "com.dzen",
            "ru.zen.android",
        ),
    )

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
            return defaultSelectionState()
        }
        return runCatching { SplitTunnelSelectionState.fromObject(JSObject(raw)) }
            .getOrElse { defaultSelectionState() }
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

    private fun defaultSelectionState() =
        SplitTunnelSelectionState(excludePackages = DEFAULT_SPLIT_TUNNEL_EXCLUDE_PACKAGES)
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
    fun addApplication(applicationInfo: ApplicationInfo?) {
        if (applicationInfo == null) {
            return
        }
        val packageName = applicationInfo.packageName?.trim().orEmpty()
        if (packageName.isBlank() || packageName == context.packageName) {
            return
        }

        val systemApp =
            (applicationInfo.flags and ApplicationInfo.FLAG_SYSTEM) != 0 ||
                (applicationInfo.flags and ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) != 0
        val hasLauncherEntry =
            packageManager.getLaunchIntentForPackage(packageName) != null ||
                packageManager.getLeanbackLaunchIntentForPackage(packageName) != null
        val shouldExpose = !systemApp || hasLauncherEntry || selectedPackages.contains(packageName)
        if (!shouldExpose) {
            return
        }

        val label =
            applicationInfo.loadLabel(packageManager).toString().trim().takeUnless { it.isBlank() }
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

    runCatching {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getInstalledApplications(PackageManager.ApplicationInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            packageManager.getInstalledApplications(0)
        }
    }.onSuccess { installedApplications ->
        installedApplications.forEach(::addApplication)
    }.onFailure { error ->
        Log.w("VpnRuntimeSplitTunnel", "getInstalledApplications failed", error)
    }

    val launcherIntent =
        Intent(Intent.ACTION_MAIN).apply {
            addCategory(Intent.CATEGORY_LAUNCHER)
        }
    runCatching {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.queryIntentActivities(
                launcherIntent,
                PackageManager.ResolveInfoFlags.of(0),
            )
        } else {
            @Suppress("DEPRECATION")
            packageManager.queryIntentActivities(launcherIntent, 0)
        }
    }.onSuccess { launcherActivities ->
        launcherActivities.forEach { resolveInfo ->
            addApplication(resolveInfo.activityInfo?.applicationInfo)
        }
    }.onFailure { error ->
        Log.w("VpnRuntimeSplitTunnel", "query launcher activities failed", error)
    }

    val apps = byPackage.values.sortedWith(
        compareBy<InstalledAppInfoSnapshot>(
            { it.systemApp },
            { it.appName.lowercase(Locale.ROOT) },
            { it.packageName },
        ),
    )
    Log.i("VpnRuntimeSplitTunnel", "listInstalledApps returned ${apps.size} apps")
    return apps
}
