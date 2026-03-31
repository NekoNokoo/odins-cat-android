package com.odinone.desktop.vk

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import app.tauri.plugin.JSArray
import app.tauri.plugin.JSObject
import org.json.JSONObject

private const val PREFS_NAME = "odin_one_vpn_runtime"
private const val SNAPSHOT_KEY = "snapshot"
private const val LAST_REQUEST_KEY = "last_request"
private const val RESUME_ELIGIBLE_KEY = "resume_eligible"
private const val BOOT_RESTORE_ENABLED_KEY = "boot_restore_enabled"
private const val PRESERVE_HIDDEN_REALITY_OVERRIDES_KEY = "preserveHiddenRealityOverrides"
private const val DEBUG_REALITY_PRESET_KEY = "debugRealityPreset"
private const val DEFAULT_TEST_URL = "https://example.com"
private const val DEFAULT_LOG_TAIL_LINES = 80

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
    val vkLink: String? = null,
    val serverHost: String? = null,
    val transport: String? = null,
    val engine: String? = null,
    val protocol: String? = null,
    val startSource: String? = null,
    val profileHash: String? = null,
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
        obj.put("vkLink", vkLink)
        obj.put("serverHost", serverHost)
        obj.put("transport", transport)
        obj.put("engine", engine)
        obj.put("protocol", protocol)
        obj.put("startSource", startSource)
        obj.put("profileHash", profileHash)
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
                vkLink = obj.getString("vkLink", null),
                serverHost = obj.getString("serverHost", null),
                transport = obj.getString("transport", null),
                engine = obj.getString("engine", null),
                protocol = obj.getString("protocol", null),
                startSource = obj.getString("startSource", null),
                profileHash = obj.getString("profileHash", null),
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
    }
}

object VpnRuntimeStore {
    @Volatile
    private var cachedSnapshot: TunnelSnapshot? = null

    @Synchronized
    fun snapshot(context: Context): TunnelSnapshot {
        val snapshot =
            cachedSnapshot ?: run {
                val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                TunnelSnapshot.fromJson(prefs.getString(SNAPSHOT_KEY, null)).also { cachedSnapshot = it }
            }
        return withPersistedTunnelFlags(context, snapshot)
    }

    fun write(
        context: Context,
        snapshot: TunnelSnapshot,
        sync: Boolean = false,
    ): TunnelSnapshot {
        cachedSnapshot = snapshot
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val editor = prefs.edit().putString(SNAPSHOT_KEY, snapshot.toPersistedObject().toString())
        if (sync) {
            editor.commit()
        } else {
            editor.apply()
        }
        return snapshot
    }

    @Synchronized
    fun update(
        context: Context,
        sync: Boolean = false,
        transform: (TunnelSnapshot) -> TunnelSnapshot,
    ): TunnelSnapshot {
        val current = snapshot(context)
        return write(context, transform(current), sync = sync)
    }
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

    fun readStartRequest(context: Context): JSObject? {
        mirrorCredentialRestoreStateToDeviceProtected(context)
        return readPreferredStartRequest(context)
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

fun mergePersistedRealityOverrides(
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
    val previousReality = parseProfileJson(previous.getString("profileJson", null))
        ?.optJSONObject("androidRuntime")
        ?.optJSONObject("reality")
        ?: return merged
    val incomingProfile = parseProfileJson(merged.getString("profileJson", null)) ?: JSObject()
    val androidRuntime = incomingProfile.optJSONObject("androidRuntime") ?: JSObject().also { incomingProfile.put("androidRuntime", it) }
    val incomingReality = androidRuntime.optJSONObject("reality") ?: JSObject().also { androidRuntime.put("reality", it) }
    mergeMissingJsonKeys(incomingReality, previousReality)
    merged.put("profileJson", incomingProfile.toString())
    merged.put(PRESERVE_HIDDEN_REALITY_OVERRIDES_KEY, true)
    previous.getString(DEBUG_REALITY_PRESET_KEY, null)
        ?.trim()
        ?.takeIf { it.isNotEmpty() }
        ?.let { merged.put(DEBUG_REALITY_PRESET_KEY, it) }
    return merged
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

internal fun stripTransientRestoreRequestFields(request: JSObject): JSObject =
    JSObject(request.toString()).apply {
        remove("startSource")
        remove("socksAddress")
        remove("bridgeAddress")
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
        normalizeTunnelArg(previousRequest.getString("profileHash", null)) == normalizeTunnelArg(incomingRequest.getString("profileHash", null)) &&
        normalizeTunnelArg(previousRequest.getString("configMode", null)) == normalizeTunnelArg(incomingRequest.getString("configMode", null))

private fun matchesBaseRestoreIdentity(
    previousRequest: JSObject,
    incomingRequest: JSObject,
): Boolean =
    normalizeTunnelArg(previousRequest.getString("serverHost", null)) == normalizeTunnelArg(incomingRequest.getString("serverHost", null)) &&
        normalizeTunnelArg(previousRequest.getString("transport", null)) == normalizeTunnelArg(incomingRequest.getString("transport", null)) &&
        normalizeTunnelArg(previousRequest.getString("engine", null)) == normalizeTunnelArg(incomingRequest.getString("engine", null)) &&
        normalizeTunnelArg(previousRequest.getString("protocol", null)) == normalizeTunnelArg(incomingRequest.getString("protocol", null)) &&
        normalizeTunnelArg(previousRequest.getString("profileSource", null)) == normalizeTunnelArg(incomingRequest.getString("profileSource", null))

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
        normalizeTunnelArg(snapshot.profileHash) == normalizeTunnelArg(args.getString("profileHash", null)) &&
        normalizeTunnelArg(snapshot.configMode) == normalizeTunnelArg(args.getString("configMode", null)) &&
        normalizeTunnelArg(snapshot.vkLink) == normalizeTunnelArg(args.getString("vkLink", null))

fun classifySystemRestoreAvailability(
    resumeEligible: Boolean,
    request: JSObject?,
): String =
    when {
        !resumeEligible -> "resume_ineligible"
        request == null -> "missing_request"
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
        startSource = args.getString("startSource", null),
        profileHash = args.getString("profileHash", null),
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
    return base.copy(status = "failed", error = error, logTail = trimLogTail(nextLogs))
}

fun classifyRuntimeFailureCode(
    message: String?,
    stage: String?,
): String {
    val normalizedMessage = message?.trim().orEmpty().lowercase()
    return when {
        normalizedMessage.contains("vless + reality access profile is incomplete") -> "profile_incomplete"
        normalizedMessage.contains("access profile") || normalizedMessage.contains("profile") -> "profile_invalid"
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
