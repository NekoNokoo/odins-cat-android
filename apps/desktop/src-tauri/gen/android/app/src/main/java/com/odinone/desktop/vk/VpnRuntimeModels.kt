package com.odinone.desktop.vk

import android.app.ActivityManager
import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import app.tauri.plugin.JSArray
import app.tauri.plugin.JSObject
import java.io.File
import java.net.InetSocketAddress
import java.net.Socket
import org.json.JSONObject

private const val PREFS_NAME = "odin_one_vpn_runtime"
private const val SNAPSHOT_KEY = "snapshot"
private const val LAST_REQUEST_KEY = "last_request"
private const val LAST_ATTEMPTED_REQUEST_KEY = "last_attempted_request"
private const val RELAY_AUTOSELECT_REQUEST_KEY = "relay_autoselect_request"
private const val RESUME_ELIGIBLE_KEY = "resume_eligible"
private const val BOOT_RESTORE_ENABLED_KEY = "boot_restore_enabled"
private const val PRESERVE_HIDDEN_REALITY_OVERRIDES_KEY = "preserveHiddenRealityOverrides"
private const val DEBUG_REALITY_PRESET_KEY = "debugRealityPreset"
private const val DEFAULT_TEST_URL = "https://example.com"
private const val DEFAULT_LOG_TAIL_LINES = 80
private const val SNAPSHOT_STALE_SOCKS_TIMEOUT_MS = 250

data class TunnelTestSnapshot(
    val ok: Boolean = false,
    val status: String = "idle",
    val url: String = DEFAULT_TEST_URL,
    val output: String? = null,
    val error: String? = null,
    val checkedAt: String? = null,
)

data class TunnelSnapshot(
    val status: String = "idle",
    val socksAddress: String? = null,
    val bridgeAddress: String? = null,
    val pendingCaptchaUrl: String? = null,
    val vkLink: String? = null,
    val serverHost: String? = null,
    val transport: String? = null,
    val engine: String? = null,
    val protocol: String? = null,
    val runtimeFamily: String? = null,
    val activationState: String? = null,
    val frontHost: String? = null,
    val frontConnectHost: String? = null,
    val frontConnectPort: Int? = null,
    val frontPath: String? = null,
    val frontProvider: String? = null,
    val frontTag: String? = null,
    val relayAutoselectEnabled: Boolean? = null,
    val relayAutoselectStatus: String? = null,
    val relayAutoselectBestHost: String? = null,
    val relayAutoselectBestPort: Int? = null,
    val relayAutoselectBestSni: String? = null,
    val relayAutoselectBestTag: String? = null,
    val relayAutoselectBestLatencyMs: Int? = null,
    val relayAutoselectSourceLabel: String? = null,
    val relayAutoselectCandidateCount: Int? = null,
    val relayAutoselectLastRefreshAt: String? = null,
    val relayAutoselectRefreshIntervalHours: Int? = null,
    val relayAutoselectLastError: String? = null,
    val cdnRoutingDnsQueryStrategy: String? = null,
    val cdnRoutingDomainStrategy: String? = null,
    val cdnRoutingDomainMatcher: String? = null,
    val cdnRoutingDirectRuleCount: Int? = null,
    val cdnRoutingBlockRuleCount: Int? = null,
    val cdnRoutingBlockSelectedFrontHost: Boolean? = null,
    val cdnDnsLocalResolverEnabled: Boolean? = null,
    val selectedSniHint: String? = null,
    val selectedCidrHint: String? = null,
    val whitelistHintSource: String? = null,
    val whitelistHintTag: String? = null,
    val startSource: String? = null,
    val profileHash: String? = null,
    val excludePackages: List<String> = emptyList(),
    val configMode: String? = null,
    val activeFeatures: List<String> = emptyList(),
    val alwaysOnEnabled: Boolean? = null,
    val lockdownEnabled: Boolean? = null,
    val resumeEligible: Boolean? = null,
    val lastNetworkEvent: String? = null,
    val lastStartupDurationMs: Long? = null,
    val lastStartupStage: String? = null,
    val sessionId: String? = null,
    val sessionStartedAt: String? = null,
    val lastFailureStage: String? = null,
    val lastFailureCode: String? = null,
    val networkChangeCount: Int = 0,
    val sessionNetworkChangeCount: Int = 0,
    val reloadCount: Int = 0,
    val sessionReloadCount: Int = 0,
    val restoreCount: Int = 0,
    val lastRecoveryAction: String? = null,
    val error: String? = null,
    val logTail: List<String> = emptyList(),
    val lastTest: TunnelTestSnapshot? = null,
) {
    fun toJsObject(): JSObject {
        val obj = JSObject()
        obj.put("status", status)
        obj.put("socksAddress", socksAddress)
        obj.put("bridgeAddress", bridgeAddress)
        obj.put("pendingCaptchaUrl", pendingCaptchaUrl)
        obj.put("vkLink", vkLink)
        obj.put("serverHost", serverHost)
        obj.put("transport", transport)
        obj.put("engine", engine)
        obj.put("protocol", protocol)
        obj.put("runtimeFamily", runtimeFamily)
        obj.put("activationState", activationState)
        obj.put("frontHost", frontHost)
        obj.put("frontConnectHost", frontConnectHost)
        obj.put("frontConnectPort", frontConnectPort)
        obj.put("frontPath", frontPath)
        obj.put("frontProvider", frontProvider)
        obj.put("frontTag", frontTag)
        obj.put("relayAutoselectEnabled", relayAutoselectEnabled)
        obj.put("relayAutoselectStatus", relayAutoselectStatus)
        obj.put("relayAutoselectBestHost", relayAutoselectBestHost)
        obj.put("relayAutoselectBestPort", relayAutoselectBestPort)
        obj.put("relayAutoselectBestSni", relayAutoselectBestSni)
        obj.put("relayAutoselectBestTag", relayAutoselectBestTag)
        obj.put("relayAutoselectBestLatencyMs", relayAutoselectBestLatencyMs)
        obj.put("relayAutoselectSourceLabel", relayAutoselectSourceLabel)
        obj.put("relayAutoselectCandidateCount", relayAutoselectCandidateCount)
        obj.put("relayAutoselectLastRefreshAt", relayAutoselectLastRefreshAt)
        obj.put("relayAutoselectRefreshIntervalHours", relayAutoselectRefreshIntervalHours)
        obj.put("relayAutoselectLastError", relayAutoselectLastError)
        obj.put("cdnRoutingDnsQueryStrategy", cdnRoutingDnsQueryStrategy)
        obj.put("cdnRoutingDomainStrategy", cdnRoutingDomainStrategy)
        obj.put("cdnRoutingDomainMatcher", cdnRoutingDomainMatcher)
        obj.put("cdnRoutingDirectRuleCount", cdnRoutingDirectRuleCount)
        obj.put("cdnRoutingBlockRuleCount", cdnRoutingBlockRuleCount)
        obj.put("cdnRoutingBlockSelectedFrontHost", cdnRoutingBlockSelectedFrontHost)
        obj.put("cdnDnsLocalResolverEnabled", cdnDnsLocalResolverEnabled)
        obj.put("selectedSniHint", selectedSniHint)
        obj.put("selectedCidrHint", selectedCidrHint)
        obj.put("whitelistHintSource", whitelistHintSource)
        obj.put("whitelistHintTag", whitelistHintTag)
        obj.put("startSource", startSource)
        obj.put("profileHash", profileHash)
        obj.put("excludePackages", JSArray(excludePackages))
        obj.put("configMode", configMode)
        obj.put("activeFeatures", JSArray(activeFeatures))
        obj.put("alwaysOnEnabled", alwaysOnEnabled)
        obj.put("lockdownEnabled", lockdownEnabled)
        obj.put("resumeEligible", resumeEligible)
        obj.put("lastNetworkEvent", lastNetworkEvent)
        obj.put("lastStartupDurationMs", lastStartupDurationMs)
        obj.put("lastStartupStage", lastStartupStage)
        obj.put("sessionId", sessionId)
        obj.put("sessionStartedAt", sessionStartedAt)
        obj.put("lastFailureStage", lastFailureStage)
        obj.put("lastFailureCode", lastFailureCode)
        obj.put("networkChangeCount", networkChangeCount)
        obj.put("sessionNetworkChangeCount", sessionNetworkChangeCount)
        obj.put("reloadCount", reloadCount)
        obj.put("sessionReloadCount", sessionReloadCount)
        obj.put("restoreCount", restoreCount)
        obj.put("lastRecoveryAction", lastRecoveryAction)
        obj.put("error", error)
        obj.put("logTail", JSArray(logTail))
        lastTest?.let {
            val testObj = JSObject()
            testObj.put("ok", it.ok)
            testObj.put("status", it.status)
            testObj.put("url", it.url)
            testObj.put("output", it.output)
            testObj.put("error", it.error)
            testObj.put("checkedAt", it.checkedAt)
            obj.put("lastTest", testObj)
        }
        return obj
    }

    fun toPersistedObject(): JSObject {
        val obj = toJsObject()
        if (lastTest == null) {
            obj.put("lastTest", null)
        }
        return obj
    }

    companion object {
        fun fromJson(raw: String?): TunnelSnapshot {
            if (raw.isNullOrBlank()) {
                return TunnelSnapshot()
            }

            return try {
                fromObject(JSObject(raw))
            } catch (_: Exception) {
                TunnelSnapshot()
            }
        }

        fun fromObject(obj: JSObject): TunnelSnapshot {
            val lastTestObject = obj.getJSObject("lastTest")
            return TunnelSnapshot(
                status = obj.getString("status", "idle") ?: "idle",
                socksAddress = obj.getString("socksAddress", null),
                bridgeAddress = obj.getString("bridgeAddress", null),
                pendingCaptchaUrl = obj.getString("pendingCaptchaUrl", null),
                vkLink = obj.getString("vkLink", null),
                serverHost = obj.getString("serverHost", null),
                transport = obj.getString("transport", null),
                engine = obj.getString("engine", null),
                protocol = obj.getString("protocol", null),
                runtimeFamily = obj.getString("runtimeFamily", null),
                activationState = obj.getString("activationState", null),
                frontHost = obj.getString("frontHost", null),
                frontConnectHost = obj.getString("frontConnectHost", null),
                frontConnectPort = optIntOrNull(obj, "frontConnectPort"),
                frontPath = obj.getString("frontPath", null),
                frontProvider = obj.getString("frontProvider", null),
                frontTag = obj.getString("frontTag", null),
                relayAutoselectEnabled = optBooleanOrNull(obj, "relayAutoselectEnabled"),
                relayAutoselectStatus = obj.getString("relayAutoselectStatus", null),
                relayAutoselectBestHost = obj.getString("relayAutoselectBestHost", null),
                relayAutoselectBestPort = optIntOrNull(obj, "relayAutoselectBestPort"),
                relayAutoselectBestSni = obj.getString("relayAutoselectBestSni", null),
                relayAutoselectBestTag = obj.getString("relayAutoselectBestTag", null),
                relayAutoselectBestLatencyMs = optIntOrNull(obj, "relayAutoselectBestLatencyMs"),
                relayAutoselectSourceLabel = obj.getString("relayAutoselectSourceLabel", null),
                relayAutoselectCandidateCount = optIntOrNull(obj, "relayAutoselectCandidateCount"),
                relayAutoselectLastRefreshAt = obj.getString("relayAutoselectLastRefreshAt", null),
                relayAutoselectRefreshIntervalHours = optIntOrNull(obj, "relayAutoselectRefreshIntervalHours"),
                relayAutoselectLastError = obj.getString("relayAutoselectLastError", null),
                cdnRoutingDnsQueryStrategy = obj.getString("cdnRoutingDnsQueryStrategy", null),
                cdnRoutingDomainStrategy = obj.getString("cdnRoutingDomainStrategy", null),
                cdnRoutingDomainMatcher = obj.getString("cdnRoutingDomainMatcher", null),
                cdnRoutingDirectRuleCount = optIntOrNull(obj, "cdnRoutingDirectRuleCount"),
                cdnRoutingBlockRuleCount = optIntOrNull(obj, "cdnRoutingBlockRuleCount"),
                cdnRoutingBlockSelectedFrontHost = optBooleanOrNull(obj, "cdnRoutingBlockSelectedFrontHost"),
                cdnDnsLocalResolverEnabled = optBooleanOrNull(obj, "cdnDnsLocalResolverEnabled"),
                selectedSniHint = obj.getString("selectedSniHint", null),
                selectedCidrHint = obj.getString("selectedCidrHint", null),
                whitelistHintSource = obj.getString("whitelistHintSource", null),
                whitelistHintTag = obj.getString("whitelistHintTag", null),
                startSource = obj.getString("startSource", null),
                profileHash = obj.getString("profileHash", null),
                excludePackages = normalizeSplitTunnelPackages(parseStringArray(obj, "excludePackages")),
                configMode = obj.getString("configMode", null),
                activeFeatures = parseStringArray(obj, "activeFeatures"),
                alwaysOnEnabled = optBooleanOrNull(obj, "alwaysOnEnabled"),
                lockdownEnabled = optBooleanOrNull(obj, "lockdownEnabled"),
                resumeEligible = optBooleanOrNull(obj, "resumeEligible"),
                lastNetworkEvent = obj.getString("lastNetworkEvent", null),
                lastStartupDurationMs = optLongOrNull(obj, "lastStartupDurationMs"),
                lastStartupStage = obj.getString("lastStartupStage", null),
                sessionId = obj.getString("sessionId", null),
                sessionStartedAt = obj.getString("sessionStartedAt", null),
                lastFailureStage = obj.getString("lastFailureStage", null),
                lastFailureCode = obj.getString("lastFailureCode", null),
                networkChangeCount = obj.optInt("networkChangeCount", 0),
                sessionNetworkChangeCount = obj.optInt("sessionNetworkChangeCount", 0),
                reloadCount = obj.optInt("reloadCount", 0),
                sessionReloadCount = obj.optInt("sessionReloadCount", 0),
                restoreCount = obj.optInt("restoreCount", 0),
                lastRecoveryAction = obj.getString("lastRecoveryAction", null),
                error = obj.getString("error", null),
                logTail = parseLogTail(obj),
                lastTest = lastTestObject?.let {
                    TunnelTestSnapshot(
                        ok = it.getBoolean("ok", false),
                        status = it.getString("status", "idle") ?: "idle",
                        url = it.getString("url", DEFAULT_TEST_URL) ?: DEFAULT_TEST_URL,
                        output = it.getString("output", null),
                        error = it.getString("error", null),
                        checkedAt = it.getString("checkedAt", null),
                    )
                },
            )
        }

        private fun parseLogTail(obj: JSObject): List<String> {
            val array = obj.optJSONArray("logTail") ?: return emptyList()
            return parseStringArray(array)
        }

        private fun parseStringArray(
            obj: JSObject,
            key: String,
        ): List<String> {
            val array = obj.optJSONArray(key) ?: return emptyList()
            return parseStringArray(array)
        }

        private fun parseStringArray(array: org.json.JSONArray): List<String> {
            val lines = ArrayList<String>(array.length())
            for (index in 0 until array.length()) {
                val line = array.optString(index, "")
                if (line.isNotBlank()) {
                    lines.add(line)
                }
            }
            return lines
        }

        private fun optBooleanOrNull(
            obj: JSObject,
            key: String,
        ): Boolean? {
            if (!obj.has(key) || obj.isNull(key)) {
                return null
            }
            return obj.optBoolean(key)
        }

        private fun optLongOrNull(
            obj: JSObject,
            key: String,
        ): Long? {
            if (!obj.has(key) || obj.isNull(key)) {
                return null
            }
            return obj.optLong(key)
        }

        private fun optIntOrNull(
            obj: JSObject,
            key: String,
        ): Int? {
            if (!obj.has(key) || obj.isNull(key)) {
                return null
            }
            return obj.optInt(key)
        }
    }
}

object VpnRuntimeStore {
    @Volatile
    private var cachedSnapshot: TunnelSnapshot? = null
    private val snapshotLock = Any()

    fun snapshot(context: Context): TunnelSnapshot {
        val persisted =
            synchronized(snapshotLock) {
                cachedSnapshot ?: readPersistedSnapshot(context).also { cachedSnapshot = it }
            }
        val withFlags = withPersistedTunnelFlags(context, persisted)
        val repaired = repairRuntimeSnapshotOnRead(context, withFlags)
        if (repaired != persisted) {
            val shouldPersist =
                synchronized(snapshotLock) {
                    if (cachedSnapshot == persisted) {
                        cachedSnapshot = repaired
                        true
                    } else {
                        false
                    }
                }
            if (shouldPersist) {
                persistSnapshot(context, repaired, sync = true)
                return repaired
            }
            return synchronized(snapshotLock) { cachedSnapshot ?: repaired }
        }
        return repaired
    }

    fun write(
        context: Context,
        snapshot: TunnelSnapshot,
        sync: Boolean = false,
    ): TunnelSnapshot {
        cachedSnapshot = snapshot
        persistSnapshot(context, snapshot, sync = sync)
        return snapshot
    }

    fun update(
        context: Context,
        sync: Boolean = false,
        transform: (TunnelSnapshot) -> TunnelSnapshot,
    ): TunnelSnapshot {
        val next =
            synchronized(snapshotLock) {
                val current = cachedSnapshot ?: readPersistedSnapshot(context).also { cachedSnapshot = it }
                transform(current).also { cachedSnapshot = it }
            }
        persistSnapshot(context, next, sync = sync)
        return next
    }

    private fun readPersistedSnapshot(context: Context): TunnelSnapshot {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return TunnelSnapshot.fromJson(prefs.getString(SNAPSHOT_KEY, null))
    }

    private fun persistSnapshot(
        context: Context,
        snapshot: TunnelSnapshot,
        sync: Boolean,
    ) {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val editor = prefs.edit().putString(SNAPSHOT_KEY, snapshot.toPersistedObject().toString())
        if (sync) {
            editor.commit()
        } else {
            editor.apply()
        }
    }
}

internal fun repairRuntimeSnapshotOnRead(
    context: Context,
    snapshot: TunnelSnapshot,
): TunnelSnapshot {
    val recoveredSocksAddress = resolvePersistedSocksAddress(context, snapshot)
    val serviceRunning = isVpnRuntimeServiceRunning(context)
    val socksReachable =
        recoveredSocksAddress
            ?.let { isLocalSocksReachable(it, SNAPSHOT_STALE_SOCKS_TIMEOUT_MS) }
            ?: false
    return repairRuntimeSnapshotStateForTest(snapshot, serviceRunning, recoveredSocksAddress, socksReachable)
}

internal fun repairRuntimeSnapshotStateForTest(
    snapshot: TunnelSnapshot,
    serviceRunning: Boolean,
    recoveredSocksAddress: String?,
    socksReachable: Boolean,
): TunnelSnapshot {
    if (snapshot.status != "running") {
        return snapshot
    }
    if (serviceRunning) {
        return if (snapshot.socksAddress.isNullOrBlank() && !recoveredSocksAddress.isNullOrBlank()) {
            snapshot.copy(socksAddress = recoveredSocksAddress)
        } else {
            snapshot
        }
    }
    if (socksReachable) {
        return if (snapshot.socksAddress.isNullOrBlank() && !recoveredSocksAddress.isNullOrBlank()) {
            snapshot.copy(socksAddress = recoveredSocksAddress)
        } else {
            snapshot
        }
    }
    return snapshot.copy(
        status = "stopped",
        socksAddress = null,
        bridgeAddress = null,
        error = null,
        lastNetworkEvent = "stale:service-missing",
        lastStartupStage = "stopped",
        logTail = trimLogTail(snapshot.logTail + "Persisted Android VPN runtime state was stale; VpnRuntimeService and local SOCKS were no longer available."),
    )
}

private fun isVpnRuntimeServiceRunning(context: Context): Boolean {
    val activityManager = context.getSystemService(ActivityManager::class.java) ?: return false
    return runCatching {
        @Suppress("DEPRECATION")
        activityManager.getRunningServices(Int.MAX_VALUE)
            .any { matchesVpnRuntimeServiceClassName(it.service.className, context.packageName) }
    }.getOrDefault(false)
}

internal fun matchesVpnRuntimeServiceClassName(
    className: String?,
    packageName: String,
): Boolean {
    val normalized = className?.trim().orEmpty()
    if (normalized.isBlank()) {
        return false
    }
    return normalized == VpnRuntimeService::class.java.name
}

private fun resolvePersistedSocksAddress(
    context: Context,
    snapshot: TunnelSnapshot,
): String? {
    snapshot.socksAddress
        ?.trim()
        ?.takeIf { it.isNotEmpty() }
        ?.let { return it }
    val runtimeDir = File(context.filesDir, "vpn-runtime")
    if (!runtimeDir.isDirectory) {
        return null
    }
    val candidates =
        when (snapshot.runtimeFamily?.trim()) {
            "reality-vps-lab" -> listOf("active-vless-reality-vps-lab.json", "active-vless-reality.json")
            "reality-whitelist-assisted" -> listOf("active-vless-reality.json", "active-vless-reality-vps-lab.json")
            "cdn-anti-whitelist" -> listOf("active-cdn-anti-whitelist.json", "active-vless-reality-vps-lab.json", "active-vless-reality.json")
            "vk-relay" -> listOf("active-vk-relay.json")
            else -> listOf("active-vless-reality.json", "active-vless-reality-vps-lab.json", "active-cdn-anti-whitelist.json", "active-vk-relay.json")
        }
    candidates.forEach { name ->
        val file = File(runtimeDir, name)
        if (!file.isFile) {
            return@forEach
        }
        runCatching {
            val root = JSONObject(file.readText())
            val inbounds = root.optJSONArray("inbounds") ?: return@runCatching null
            for (index in 0 until inbounds.length()) {
                val inbound = inbounds.optJSONObject(index) ?: continue
                if (!inbound.optString("type").equals("socks", ignoreCase = true)) {
                    continue
                }
                val listen = inbound.optString("listen", "127.0.0.1").trim().ifBlank { "127.0.0.1" }
                val port = inbound.optInt("listen_port", 0).takeIf { it > 0 } ?: continue
                return@runCatching "$listen:$port"
            }
            null
        }.getOrNull()?.let { return it }
    }
    return null
}

private fun isLocalSocksReachable(
    socksAddress: String,
    timeoutMs: Int,
): Boolean {
    val pieces = socksAddress.trim().split(':')
    if (pieces.size != 2) {
        return false
    }
    val host = pieces[0].trim()
    val port = pieces[1].trim().toIntOrNull() ?: return false
    return runCatching {
        Socket().use { socket ->
            socket.connect(InetSocketAddress(host, port), timeoutMs)
        }
        true
    }.getOrDefault(false)
}

fun withPersistedTunnelFlags(
    context: Context,
    snapshot: TunnelSnapshot,
): TunnelSnapshot =
    snapshot.copy(
        resumeEligible = VpnRuntimeRestoreStore.isResumeEligible(context),
    )

object VpnRuntimeRestoreStore {
    fun persistStartRequest(
        context: Context,
        request: JSObject,
    ) {
        val effectiveRequest =
            normalizePersistedRestoreRequest(
                mergeBootRestoreState(readPreferredStartRequest(context), request),
            )
        updateRestorePrefsSync(context) { editor ->
            editor
                .putString(LAST_REQUEST_KEY, effectiveRequest.toString())
                .putBoolean(BOOT_RESTORE_ENABLED_KEY, effectiveRequest.getBoolean("bootRestoreEnabled", false))
        }
    }

    fun persistAttemptedStartRequest(
        context: Context,
        request: JSObject,
    ) {
        val effectiveRequest = normalizePersistedAttemptRequest(request)
        updateRestorePrefsSync(context) { editor ->
            editor.putString(LAST_ATTEMPTED_REQUEST_KEY, effectiveRequest.toString())
        }
    }

    fun readStartRequest(context: Context): JSObject? {
        mirrorCredentialRestoreStateToDeviceProtected(context)
        return readPreferredStartRequest(context)
    }

    fun readAttemptedStartRequest(context: Context): JSObject? {
        mirrorCredentialRestoreStateToDeviceProtected(context)
        return readPreferredAttemptedStartRequest(context)
    }

    fun persistRelayAutoselectRequest(
        context: Context,
        request: JSObject,
    ) {
        val effectiveRequest = normalizePersistedAttemptRequest(request)
        updateRestorePrefsSync(context) { editor ->
            editor.putString(RELAY_AUTOSELECT_REQUEST_KEY, effectiveRequest.toString())
        }
    }

    fun readRelayAutoselectRequest(context: Context): JSObject? {
        mirrorCredentialRestoreStateToDeviceProtected(context)
        return parseRestoreRequest(readRestoreString(context, RELAY_AUTOSELECT_REQUEST_KEY))
    }

    fun clearRelayAutoselectRequest(context: Context) {
        updateRestorePrefsSync(context) { editor ->
            editor.remove(RELAY_AUTOSELECT_REQUEST_KEY)
        }
    }

    fun markResumeEligible(
        context: Context,
        eligible: Boolean,
    ) {
        updateRestorePrefsSync(context) { editor ->
            editor.putBoolean(RESUME_ELIGIBLE_KEY, eligible)
        }
    }

    fun isResumeEligible(context: Context): Boolean {
        mirrorCredentialRestoreStateToDeviceProtected(context)
        return readRestoreBoolean(context, RESUME_ELIGIBLE_KEY, false)
    }

    fun isBootRestoreEnabled(context: Context): Boolean {
        mirrorCredentialRestoreStateToDeviceProtected(context)
        return restorePrefsTargets(context).any { prefs ->
            prefs.contains(BOOT_RESTORE_ENABLED_KEY) && prefs.getBoolean(BOOT_RESTORE_ENABLED_KEY, false)
        }
    }

    private fun updateRestorePrefs(
        context: Context,
        block: (SharedPreferences) -> Unit,
    ) {
        restorePrefsTargets(context).forEach(block)
    }

    private fun updateRestorePrefsSync(
        context: Context,
        block: (SharedPreferences.Editor) -> SharedPreferences.Editor,
    ) {
        restorePrefsTargets(context).forEach { prefs ->
            block(prefs.edit()).commit()
        }
    }

    private fun readRestoreString(
        context: Context,
        key: String,
    ): String? {
        restorePrefsTargets(context).forEach { prefs ->
            if (prefs.contains(key)) {
                return prefs.getString(key, null)
            }
        }
        return null
    }

    private fun readRestoreBoolean(
        context: Context,
        key: String,
        defaultValue: Boolean,
    ): Boolean {
        restorePrefsTargets(context).forEach { prefs ->
            if (prefs.contains(key)) {
                return prefs.getBoolean(key, defaultValue)
            }
        }
        return defaultValue
    }

    private fun mirrorCredentialRestoreStateToDeviceProtected(context: Context) {
        val devicePrefs = deviceProtectedRestorePrefs(context) ?: return
        val credentialPrefs = credentialProtectedRestorePrefs(context)
        val editor = devicePrefs.edit()
        var changed = false
        val preferredRequest = selectPreferredRestoreRequest(
            parseRestoreRequest(credentialPrefs.getString(LAST_REQUEST_KEY, null)),
            parseRestoreRequest(devicePrefs.getString(LAST_REQUEST_KEY, null)),
        )
        if (preferredRequest != null) {
            editor.putString(LAST_REQUEST_KEY, preferredRequest.toString())
            changed = true
        }
        val preferredAttemptedRequest = selectPreferredAttemptedRequest(
            parseRestoreRequest(credentialPrefs.getString(LAST_ATTEMPTED_REQUEST_KEY, null)),
            parseRestoreRequest(devicePrefs.getString(LAST_ATTEMPTED_REQUEST_KEY, null)),
        )
        if (preferredAttemptedRequest != null) {
            editor.putString(LAST_ATTEMPTED_REQUEST_KEY, preferredAttemptedRequest.toString())
            changed = true
        }
        if (credentialPrefs.contains(RESUME_ELIGIBLE_KEY)) {
            editor.putBoolean(RESUME_ELIGIBLE_KEY, credentialPrefs.getBoolean(RESUME_ELIGIBLE_KEY, false))
            changed = true
        }
        val bootRestoreEnabled =
            sequenceOf(credentialPrefs, devicePrefs)
                .filter { it.contains(BOOT_RESTORE_ENABLED_KEY) }
                .any { it.getBoolean(BOOT_RESTORE_ENABLED_KEY, false) } ||
                (preferredRequest?.getBoolean("bootRestoreEnabled", false) == true)
        if (credentialPrefs.contains(BOOT_RESTORE_ENABLED_KEY) || devicePrefs.contains(BOOT_RESTORE_ENABLED_KEY) || preferredRequest != null) {
            editor.putBoolean(BOOT_RESTORE_ENABLED_KEY, bootRestoreEnabled)
            changed = true
        }
        if (changed) {
            editor.commit()
        }
    }

    private fun restorePrefsTargets(context: Context): List<SharedPreferences> =
        buildList {
            add(credentialProtectedRestorePrefs(context))
            deviceProtectedRestorePrefs(context)?.let(::add)
        }.distinctBy { System.identityHashCode(it) }

    private fun credentialProtectedRestorePrefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    private fun deviceProtectedRestorePrefs(context: Context): SharedPreferences? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            context.createDeviceProtectedStorageContext().getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        } else {
            null
        }

    private fun readPreferredStartRequest(context: Context): JSObject? {
        val requests =
            restorePrefsTargets(context).mapNotNull { prefs ->
                parseRestoreRequest(prefs.getString(LAST_REQUEST_KEY, null))
            }
        return requests.reduceOrNull(::selectPreferredRestoreRequest)
    }

    private fun readPreferredAttemptedStartRequest(context: Context): JSObject? {
        val requests =
            restorePrefsTargets(context).mapNotNull { prefs ->
                parseRestoreRequest(prefs.getString(LAST_ATTEMPTED_REQUEST_KEY, null))
            }
        return requests.reduceOrNull(::selectPreferredAttemptedRequest)
    }
}

fun mergeBootRestoreState(
    previousRequest: JSObject?,
    incomingRequest: JSObject,
): JSObject {
    val merged = JSObject(incomingRequest.toString())
    if (merged.getBoolean("bootRestoreEnabled", false)) {
        return merged
    }
    val previous = previousRequest ?: return merged
    if (!previous.getBoolean("bootRestoreEnabled", false)) {
        return merged
    }
    if (!isSameRestoreIdentity(previous, merged)) {
        return merged
    }
    merged.put("bootRestoreEnabled", true)
    patchProfileBootRestoreState(merged, true)
    return merged
}

fun mergePersistedHiddenRuntimeOverrides(
    previousRequest: JSObject?,
    incomingRequest: JSObject,
): JSObject {
    val merged = JSObject(incomingRequest.toString())
    val previous = previousRequest ?: return merged
    if (!previous.getBoolean(PRESERVE_HIDDEN_REALITY_OVERRIDES_KEY, false)) {
        return merged
    }
    if (normalizeTunnelArg(previous.getString("protocol", null)) != "vless-reality" ||
        normalizeTunnelArg(merged.getString("protocol", null)) != "vless-reality"
    ) {
        return merged
    }
    if (!matchesBaseRestoreIdentity(previous, merged)) {
        return merged
    }
    val previousAndroidRuntime = parseProfileJson(previous.getString("profileJson", null))
        ?.optJSONObject("androidRuntime")
        ?: return merged
    val incomingProfile = parseProfileJson(merged.getString("profileJson", null)) ?: JSObject()
    val androidRuntime = incomingProfile.optJSONObject("androidRuntime") ?: JSObject().also { incomingProfile.put("androidRuntime", it) }
    val requestedRuntimeFamily =
        normalizeTunnelArg(merged.getString("runtimeFamily", null))
            .takeUnless { it.isEmpty() }
            ?: "direct-reality"
    mergeMissingAndroidRuntimeBlock(androidRuntime, previousAndroidRuntime, "reality")
    when (requestedRuntimeFamily) {
        "cdn-anti-whitelist" -> {
            mergeMissingAndroidRuntimeBlock(androidRuntime, previousAndroidRuntime, "cdnAntiWhitelist")
            mergeMissingStringField(merged, previous, "frontTag")
            mergeMissingStringField(merged, previous, "cdnFrontTag")
        }
        "reality-vps-lab" -> {
            mergeMissingAndroidRuntimeBlock(androidRuntime, previousAndroidRuntime, "realityVpsLab")
        }
        "reality-whitelist-assisted" -> {
            mergeMissingAndroidRuntimeBlock(androidRuntime, previousAndroidRuntime, "realityWhitelistHints")
        }
    }
    merged.put("profileJson", incomingProfile.toString())
    merged.put(PRESERVE_HIDDEN_REALITY_OVERRIDES_KEY, true)
    previous.getString(DEBUG_REALITY_PRESET_KEY, null)
        ?.trim()
        ?.takeIf { it.isNotEmpty() }
        ?.let { merged.put(DEBUG_REALITY_PRESET_KEY, it) }
    return merged
}

private fun mergeMissingStringField(
    target: JSObject,
    source: JSObject,
    key: String,
) {
    val current = target.getString(key, null)?.trim().orEmpty()
    if (current.isNotEmpty()) {
        return
    }
    source.getString(key, null)
        ?.trim()
        ?.takeIf { it.isNotEmpty() }
        ?.let { target.put(key, it) }
}

fun withBootRestoreEnabled(
    request: JSObject,
    enabled: Boolean,
): JSObject =
    JSObject(request.toString()).also { patched ->
        patched.put("bootRestoreEnabled", enabled)
        patchProfileBootRestoreState(patched, enabled)
    }

fun selectPreferredRestoreRequest(
    primaryRequest: JSObject?,
    secondaryRequest: JSObject?,
): JSObject? =
    when {
        primaryRequest == null -> secondaryRequest
        secondaryRequest == null -> primaryRequest
        secondaryRequest.getBoolean("bootRestoreEnabled", false) && !primaryRequest.getBoolean("bootRestoreEnabled", false) -> secondaryRequest
        else -> primaryRequest
    }

fun selectPreferredAttemptedRequest(
    primaryRequest: JSObject?,
    secondaryRequest: JSObject?,
): JSObject? =
    primaryRequest ?: secondaryRequest

private fun parseRestoreRequest(raw: String?): JSObject? =
    raw?.takeIf { it.isNotBlank() }?.let { runCatching { JSObject(it) }.getOrNull() }

private fun parseProfileJson(raw: String?): JSObject? =
    raw?.takeIf { it.isNotBlank() }?.let { runCatching { JSObject(it) }.getOrNull() }

internal fun normalizePersistedRestoreRequest(request: JSObject): JSObject =
    if (normalizeTunnelArg(request.getString("protocol", null)) == "vless-reality") {
        VpnRuntimeLibbox.normalizeRuntimeArgs(stripTransientRestoreRequestFields(request))
    } else {
        stripTransientRestoreRequestFields(request)
    }

internal fun normalizePersistedAttemptRequest(request: JSObject): JSObject =
    if (normalizeTunnelArg(request.getString("protocol", null)) == "vless-reality") {
        VpnRuntimeLibbox.normalizeRuntimeArgs(stripTransientAttemptRequestFields(request))
    } else {
        stripTransientAttemptRequestFields(request)
    }

internal fun stripTransientRestoreRequestFields(request: JSObject): JSObject =
    stripTransientRequestFields(request, preserveStartSource = false)

internal fun stripTransientAttemptRequestFields(request: JSObject): JSObject =
    stripTransientRequestFields(request, preserveStartSource = true)

private fun stripTransientRequestFields(
    request: JSObject,
    preserveStartSource: Boolean,
): JSObject =
    JSObject(request.toString()).apply {
        if (!preserveStartSource) {
            remove("startSource")
        }
        remove("socksAddress")
        remove("bridgeAddress")
        remove("pendingCaptchaUrl")
        remove("relayAutoselectEnabled")
        remove("relayAutoselectStatus")
        remove("relayAutoselectBestHost")
        remove("relayAutoselectBestPort")
        remove("relayAutoselectBestSni")
        remove("relayAutoselectBestTag")
        remove("relayAutoselectBestLatencyMs")
        remove("relayAutoselectSourceLabel")
        remove("relayAutoselectCandidateCount")
        remove("relayAutoselectLastRefreshAt")
        remove("relayAutoselectRefreshIntervalHours")
        remove("relayAutoselectLastError")
        remove("alwaysOnEnabled")
        remove("lockdownEnabled")
        remove("resumeEligible")
        remove("lastNetworkEvent")
        remove("lastStartupDurationMs")
        remove("lastStartupStage")
        remove("sessionId")
        remove("sessionStartedAt")
        remove("lastFailureStage")
        remove("lastFailureCode")
        remove("networkChangeCount")
        remove("sessionNetworkChangeCount")
        remove("reloadCount")
        remove("sessionReloadCount")
        remove("restoreCount")
        remove("lastRecoveryAction")
        remove("error")
        remove("logTail")
        remove("lastTest")
    }

private fun isSameRestoreIdentity(
    previousRequest: JSObject,
    incomingRequest: JSObject,
): Boolean =
    normalizeTunnelArg(previousRequest.getString("serverHost", null)) == normalizeTunnelArg(incomingRequest.getString("serverHost", null)) &&
        normalizeTunnelArg(previousRequest.getString("transport", null)) == normalizeTunnelArg(incomingRequest.getString("transport", null)) &&
        normalizeTunnelArg(previousRequest.getString("engine", null)) == normalizeTunnelArg(incomingRequest.getString("engine", null)) &&
        normalizeTunnelArg(previousRequest.getString("protocol", null)) == normalizeTunnelArg(incomingRequest.getString("protocol", null)) &&
        normalizeRuntimeFamilyIdentity(
            protocol = previousRequest.getString("protocol", null),
            runtimeFamily = previousRequest.getString("runtimeFamily", null),
        ) == normalizeRuntimeFamilyIdentity(
            protocol = incomingRequest.getString("protocol", null),
            runtimeFamily = incomingRequest.getString("runtimeFamily", null),
        ) &&
        normalizeTunnelArg(previousRequest.getString("profileHash", null)) == normalizeTunnelArg(incomingRequest.getString("profileHash", null)) &&
        normalizeTunnelArg(previousRequest.getString("configMode", null)) == normalizeTunnelArg(incomingRequest.getString("configMode", null)) &&
        normalizeActivationStateIdentity(
            protocol = previousRequest.getString("protocol", null),
            activationState = previousRequest.getString("activationState", null),
        ) == normalizeActivationStateIdentity(
            protocol = incomingRequest.getString("protocol", null),
            activationState = incomingRequest.getString("activationState", null),
        )

private fun matchesBaseRestoreIdentity(
    previousRequest: JSObject,
    incomingRequest: JSObject,
): Boolean =
    normalizeTunnelArg(previousRequest.getString("serverHost", null)) == normalizeTunnelArg(incomingRequest.getString("serverHost", null)) &&
        normalizeTunnelArg(previousRequest.getString("transport", null)) == normalizeTunnelArg(incomingRequest.getString("transport", null)) &&
        normalizeTunnelArg(previousRequest.getString("engine", null)) == normalizeTunnelArg(incomingRequest.getString("engine", null)) &&
        normalizeTunnelArg(previousRequest.getString("protocol", null)) == normalizeTunnelArg(incomingRequest.getString("protocol", null)) &&
        normalizeTunnelArg(previousRequest.getString("profileSource", null)) == normalizeTunnelArg(incomingRequest.getString("profileSource", null))

private fun mergeMissingAndroidRuntimeBlock(
    targetAndroidRuntime: JSONObject,
    sourceAndroidRuntime: JSONObject,
    blockKey: String,
) {
    val sourceBlock = sourceAndroidRuntime.optJSONObject(blockKey) ?: return
    val targetBlock = targetAndroidRuntime.optJSONObject(blockKey) ?: JSObject().also { targetAndroidRuntime.put(blockKey, it) }
    mergeMissingJsonKeys(targetBlock, sourceBlock)
}

private fun mergeMissingJsonKeys(
    target: JSONObject,
    source: JSONObject,
) {
    val keys = source.keys()
    while (keys.hasNext()) {
        val key = keys.next()
        val sourceValue = source.opt(key)
        if (!target.has(key) || target.isNull(key)) {
            target.put(key, sourceValue)
            continue
        }
        val targetObject = target.optJSONObject(key)
        val sourceObject = source.optJSONObject(key)
        if (targetObject != null && sourceObject != null) {
            mergeMissingJsonKeys(targetObject, sourceObject)
        }
    }
}

private fun patchProfileBootRestoreState(
    request: JSObject,
    enabled: Boolean,
) {
    val rawProfile = request.getString("profileJson", null)
    if (rawProfile.isNullOrBlank()) {
        return
    }
    val profile = runCatching { JSObject(rawProfile) }.getOrNull() ?: return
    val androidRuntime = profile.optJSONObject("androidRuntime") ?: JSObject().also { profile.put("androidRuntime", it) }
    val reality = androidRuntime.optJSONObject("reality") ?: JSObject().also { androidRuntime.put("reality", it) }
    reality.put("autoRestoreOnBoot", enabled)
    request.put("profileJson", profile.toString())
}

fun currentTimestamp(): String = java.time.Instant.now().toString()

fun trimLogTail(lines: List<String>): List<String> = lines.takeLast(DEFAULT_LOG_TAIL_LINES)

private fun normalizeTunnelArg(value: String?): String = value?.trim().orEmpty()

private fun normalizeRuntimeFamilyIdentity(
    protocol: String?,
    runtimeFamily: String?,
): String =
    runtimeFamily?.trim().takeUnless { it.isNullOrEmpty() }
        ?: when (normalizeTunnelArg(protocol)) {
            "direct-wireguard" -> "vk-relay"
            "vless-reality" -> "direct-reality"
            else -> ""
        }

private fun normalizeActivationStateIdentity(
    protocol: String?,
    activationState: String?,
): String =
    activationState?.trim().takeUnless { it.isNullOrEmpty() }
        ?: when (normalizeTunnelArg(protocol)) {
            "direct-wireguard", "vless-reality" -> "active"
            else -> ""
        }

fun normalizeRunningStartupStage(
    status: String,
    stage: String?,
): String? =
    if (status == "running" && stage != "running") {
        "running"
    } else {
        stage
    }

fun isActiveTunnelStatus(status: String): Boolean = status == "starting" || status == "running"

fun matchesTunnelRequest(
    snapshot: TunnelSnapshot,
    args: JSObject,
): Boolean =
    normalizeTunnelArg(snapshot.serverHost) == normalizeTunnelArg(args.getString("serverHost", null)) &&
        normalizeTunnelArg(snapshot.transport) == normalizeTunnelArg(args.getString("transport", null)) &&
        normalizeTunnelArg(snapshot.engine) == normalizeTunnelArg(args.getString("engine", null)) &&
        normalizeTunnelArg(snapshot.protocol) == normalizeTunnelArg(args.getString("protocol", null)) &&
        normalizeRuntimeFamilyIdentity(
            protocol = snapshot.protocol,
            runtimeFamily = snapshot.runtimeFamily,
        ) == normalizeRuntimeFamilyIdentity(
            protocol = args.getString("protocol", null),
            runtimeFamily = args.getString("runtimeFamily", null),
        ) &&
        normalizeTunnelArg(snapshot.profileHash) == normalizeTunnelArg(args.getString("profileHash", null)) &&
        normalizeTunnelArg(snapshot.configMode) == normalizeTunnelArg(args.getString("configMode", null)) &&
        normalizeActivationStateIdentity(
            protocol = snapshot.protocol,
            activationState = snapshot.activationState,
        ) == normalizeActivationStateIdentity(
            protocol = args.getString("protocol", null),
            activationState = args.getString("activationState", null),
        ) &&
        normalizeSplitTunnelPackages(snapshot.excludePackages) ==
            normalizeSplitTunnelPackages(parseStringArray(args, "excludePackages")) &&
        normalizeTunnelArg(snapshot.vkLink) == normalizeTunnelArg(args.getString("vkLink", null))

fun classifySystemRestoreAvailability(
    resumeEligible: Boolean,
    request: JSObject?,
): String =
    when {
        !resumeEligible -> "resume_ineligible"
        request == null -> "missing_request"
        normalizeTunnelArg(request.getString("activationState", null)) == "scaffold_only" -> "scaffold_only"
        normalizeTunnelArg(request.getString("runtimeFamily", null)) == "reality-vps-lab" &&
            normalizeTunnelArg(request.getString("configMode", null)) == "lab" -> "lab_only"
        normalizeTunnelArg(request.getString("runtimeFamily", null)) == "reality-whitelist-assisted" &&
            normalizeTunnelArg(request.getString("configMode", null)) == "lab" -> "lab_only"
        normalizeTunnelArg(request.getString("runtimeFamily", null)) == "cdn-anti-whitelist" &&
            normalizeTunnelArg(request.getString("configMode", null)) == "lab" -> "lab_only"
        normalizeTunnelArg(request.getString("protocol", null)) != "vless-reality" -> "protocol_mismatch"
        else -> "available"
    }

fun classifyBootRestoreAvailability(
    resumeEligible: Boolean,
    bootRestoreEnabled: Boolean,
    request: JSObject?,
): String =
    when {
        !resumeEligible -> "resume_ineligible"
        !bootRestoreEnabled -> "boot_restore_disabled"
        else -> classifySystemRestoreAvailability(resumeEligible = true, request = request)
    }

fun startSnapshotFromArgs(args: JSObject, logLine: String): TunnelSnapshot =
    currentTimestamp().let { sessionMarker ->
        TunnelSnapshot(
            status = "starting",
            vkLink = args.getString("vkLink", null),
            serverHost = args.getString("serverHost", null),
            transport = args.getString("transport", null),
            engine = args.getString("engine", null),
            protocol = args.getString("protocol", null),
            runtimeFamily = args.getString("runtimeFamily", null),
            activationState = args.getString("activationState", null),
            frontHost = args.getString("frontHost", null),
            frontConnectHost = args.getString("frontConnectHost", args.getString("cdnConnectHost", null)),
            frontConnectPort =
                when {
                    args.has("frontConnectPort") && !args.isNull("frontConnectPort") -> args.optInt("frontConnectPort")
                    args.has("cdnConnectPort") && !args.isNull("cdnConnectPort") -> args.optInt("cdnConnectPort")
                    else -> null
                },
            frontPath = args.getString("frontPath", null),
            frontProvider = args.getString("frontProvider", null),
            frontTag = args.getString("frontTag", null),
            relayAutoselectEnabled =
                if (args.has("relayAutoselectEnabled") && !args.isNull("relayAutoselectEnabled")) {
                    args.optBoolean("relayAutoselectEnabled")
                } else {
                    null
                },
            relayAutoselectStatus = args.getString("relayAutoselectStatus", null),
            relayAutoselectBestHost = args.getString("relayAutoselectBestHost", null),
            relayAutoselectBestPort =
                if (args.has("relayAutoselectBestPort") && !args.isNull("relayAutoselectBestPort")) {
                    args.optInt("relayAutoselectBestPort")
                } else {
                    null
                },
            relayAutoselectBestSni = args.getString("relayAutoselectBestSni", null),
            relayAutoselectBestTag = args.getString("relayAutoselectBestTag", null),
            relayAutoselectBestLatencyMs =
                if (args.has("relayAutoselectBestLatencyMs") && !args.isNull("relayAutoselectBestLatencyMs")) {
                    args.optInt("relayAutoselectBestLatencyMs")
                } else {
                    null
                },
            relayAutoselectSourceLabel = args.getString("relayAutoselectSourceLabel", null),
            relayAutoselectCandidateCount =
                if (args.has("relayAutoselectCandidateCount") && !args.isNull("relayAutoselectCandidateCount")) {
                    args.optInt("relayAutoselectCandidateCount")
                } else {
                    null
                },
            relayAutoselectLastRefreshAt = args.getString("relayAutoselectLastRefreshAt", null),
            relayAutoselectRefreshIntervalHours =
                if (args.has("relayAutoselectRefreshIntervalHours") && !args.isNull("relayAutoselectRefreshIntervalHours")) {
                    args.optInt("relayAutoselectRefreshIntervalHours")
                } else {
                    null
                },
            relayAutoselectLastError = args.getString("relayAutoselectLastError", null),
            cdnRoutingDnsQueryStrategy = args.getString("cdnRoutingDnsQueryStrategy", null),
            cdnRoutingDomainStrategy = args.getString("cdnRoutingDomainStrategy", null),
            cdnRoutingDomainMatcher = args.getString("cdnRoutingDomainMatcher", null),
            cdnRoutingDirectRuleCount =
                if (args.has("cdnRoutingDirectRuleCount") && !args.isNull("cdnRoutingDirectRuleCount")) {
                    args.optInt("cdnRoutingDirectRuleCount")
                } else {
                    null
                },
            cdnRoutingBlockRuleCount =
                if (args.has("cdnRoutingBlockRuleCount") && !args.isNull("cdnRoutingBlockRuleCount")) {
                    args.optInt("cdnRoutingBlockRuleCount")
                } else {
                    null
                },
            cdnRoutingBlockSelectedFrontHost =
                if (args.has("cdnRoutingBlockSelectedFrontHost") && !args.isNull("cdnRoutingBlockSelectedFrontHost")) {
                    args.optBoolean("cdnRoutingBlockSelectedFrontHost")
                } else {
                    null
                },
            cdnDnsLocalResolverEnabled =
                if (args.has("cdnDnsLocalResolverEnabled") && !args.isNull("cdnDnsLocalResolverEnabled")) {
                    args.optBoolean("cdnDnsLocalResolverEnabled")
                } else {
                    null
                },
            selectedSniHint = args.getString("selectedSniHint", null),
            selectedCidrHint = args.getString("selectedCidrHint", null),
            whitelistHintSource = args.getString("whitelistHintSource", null),
            whitelistHintTag = args.getString("whitelistHintTag", null),
            startSource = args.getString("startSource", null),
            profileHash = args.getString("profileHash", null),
            excludePackages = normalizeSplitTunnelPackages(parseStringArray(args, "excludePackages")),
            configMode = args.getString("configMode", null),
            sessionId = sessionMarker,
            sessionStartedAt = sessionMarker,
            activeFeatures =
                args.optJSONArray("activeFeatures")?.let { features ->
                    buildList(features.length()) {
                        for (index in 0 until features.length()) {
                            val feature = features.optString(index, "").trim()
                            if (feature.isNotEmpty()) {
                                add(feature)
                            }
                        }
                    }
                }.orEmpty(),
            logTail = listOf(logLine),
            lastTest = TunnelTestSnapshot(),
        )
    }

fun failedSnapshot(
    base: TunnelSnapshot,
    error: String,
    extraLogLine: String? = null,
): TunnelSnapshot {
    val nextLogs = ArrayList<String>(base.logTail)
    nextLogs.add(error)
    extraLogLine?.let { nextLogs.add(it) }
    return base.copy(
        status = "failed",
        error = error,
        pendingCaptchaUrl = null,
        logTail = trimLogTail(nextLogs),
    )
}

fun classifyRuntimeFailureCode(
    message: String?,
    stage: String?,
): String {
    val normalizedMessage = message?.trim().orEmpty().lowercase()
    return when {
        normalizedMessage.contains("fatal_captcha_failed_no_streams") -> "vk_captcha_fatal"
        normalizedMessage.contains("captcha_wait_required") -> "vk_captcha_wait"
        normalizedMessage.contains("vless + reality access profile is incomplete") -> "profile_incomplete"
        normalizedMessage.contains("access profile") || normalizedMessage.contains("profile") -> "profile_invalid"
        normalizedMessage.contains("scaffolded only") -> "scaffold_only"
        normalizedMessage.contains("missing vpn permission") -> "vpn_permission_missing"
        normalizedMessage.contains("unsupported android runtime protocol") -> "protocol_unsupported"
        normalizedMessage.contains("vk-turn-proxy") -> "vk_bridge_failed"
        stage == "socks_ready" -> "socks_timeout"
        stage == "service_started" -> "service_start_failed"
        stage == "command_server_ready" -> "command_server_failed"
        stage == "prepare_runtime" || stage == "config_ready" -> "config_prepare_failed"
        else -> "runtime_start_failed"
    }
}
