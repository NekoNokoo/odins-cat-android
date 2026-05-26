package com.odinone.desktop.vk

import android.content.Context
import android.os.SystemClock
import android.util.Base64
import android.util.Log
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.Worker
import androidx.work.WorkerParameters
import androidx.work.WorkManager
import app.tauri.plugin.JSObject
import java.net.HttpURLConnection
import java.net.Socket
import java.net.URI
import java.net.URL
import java.net.URLDecoder
import java.util.Locale
import java.util.concurrent.TimeUnit
import kotlin.math.max
import kotlin.math.min
import org.json.JSONArray
import org.json.JSONObject

private const val RELAY_AUTOSELECT_PREFS_NAME = "odin_one_vpn_runtime"
private const val RELAY_AUTOSELECT_STATE_KEY = "reality_relay_autoselect_state"
private const val RELAY_AUTOSELECT_HISTORY_KEY = "reality_relay_autoselect_history"
private const val RELAY_AUTOSELECT_WORK_NAME = "odin_one_reality_relay_autoselect_hourly"
private const val RELAY_AUTOSELECT_DEFAULT_INTERVAL_HOURS = 1L
private const val RELAY_AUTOSELECT_DEFAULT_THRESHOLD_MS = 300
private const val RELAY_AUTOSELECT_DEFAULT_TIMEOUT_MS = 1200
private const val RELAY_AUTOSELECT_DEFAULT_CANDIDATE_LIMIT = 8
private const val RELAY_AUTOSELECT_DEFAULT_MAX_PER_SNI = 2
private const val RELAY_AUTOSELECT_HTTP_TIMEOUT_MS = 8000
private const val RELAY_AUTOSELECT_STATUS_DISABLED = "disabled"
private const val RELAY_AUTOSELECT_STATUS_IDLE = "idle"
private const val RELAY_AUTOSELECT_STATUS_READY = "ready"
private const val RELAY_AUTOSELECT_STATUS_REFRESHING = "refreshing"
private const val RELAY_AUTOSELECT_STATUS_FAILED = "failed"
private const val RELAY_AUTOSELECT_STATUS_NO_CANDIDATE = "no_candidate"
private const val RELAY_AUTOSELECT_TAG = "RealityRelayAutoselect"
private const val RELAY_PROBE_OWNER = "owner"
private const val RELAY_PROBE_GOOGLEVIDEO = "googlevideo"
private const val RELAY_PROBE_GSTATIC = "gstatic"
private const val RELAY_PROBE_YOUTUBE = "youtube"
private const val RELAY_EMBEDDED_SOURCE_SUFFIX = "-embedded-fallback"
private val OWNER_EGRESS_STICKY_CANDIDATE_URIS =
    listOf(
        "vless://aae59c28-a4e7-46bd-8fa5-a239e8cfe0b1@51.250.45.194:443/?type=tcp&encryption=none&flow=xtls-rprx-vision&sni=ads.x5.ru&fp=random&security=reality&pbk=Py03aPnCma9Ip4xCvtBsK77NScUYphSw46RmdjFSvls&sid=5aea2cffba100557&packetEncoding=xudp#%F0%9F%87%A9%F0%9F%87%AA%20Germany%20%7C%20%F0%9F%8C%90%20%5B%2ACIDR%5D%20YA",
        "vless://a96f18f0-4a56-4c4f-be6e-434835f5523c@158.160.71.158:443?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&fp=chrome&sni=ads.x5.ru&pbk=0j-QVy2pFdCuKAkppUYr0diUSjjKse9CtM5AMhHzqD4&sid=8ac77e6bab737698&spx=%2F#%F0%9F%87%B1%F0%9F%87%B9%20Lithuania%20%5B%2ACIDR%5D%20YA",
        "vless://30a3d65b-2963-48ef-ac5c-9f354fadc85c@212.233.121.168:5443?encryption=none&type=tcp&security=reality&fp=chrome&sni=ads.x5.ru&pbk=nxnDt_F4R6QK9mKQ7dUpvCcJPtwYNPdlNWWjeiDyYj0&sid=e0d4ee#%F0%9F%87%B5%F0%9F%87%B1%20Poland%20%5B%2ACIDR%5D%20VK",
        "vless://e0e062be-e77b-4568-9477-512388d65bc8@51.250.23.54:443?type=tcp&encryption=none&security=reality&pbk=-tpEyDuFARd0Lvo6l6g25xCNK9tBiVMhpymAJY_gO2I&fp=qq&sni=max.ru&spx=%2F&sid=7405645f#%F0%9F%87%B3%F0%9F%87%B1%20The%20Netherlands%20%5B%2ACIDR%5D%20YA",
        "vless://19ef3d02-1c55-4fec-9794-6def8cbac396@185.130.113.39:5443?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&fp=chrome&sni=i.oneme.ru&pbk=-nZqMxt7meVxfnQeK46MAYh5scb0M6La82axD8KHJXk&sid=91e2a4c7#%F0%9F%87%AB%F0%9F%87%AE%20Finland%20%5B%2ACIDR%5D%20VK",
    )
private val EMBEDDED_RELAY_SUBSCRIPTION_BODY = OWNER_EGRESS_STICKY_CANDIDATE_URIS.joinToString("\n")
private val OWNER_EGRESS_PROVEN_SECOND_HOP_FAMILY_PRIORITY =
    listOf(
        "api.vk.com",
        "5post-gate.x5.ru",
    )
private val OWNER_EGRESS_RELAY_FAMILY_PRIORITY =
    listOf(
        "ads.x5.ru",
        "5post-gate.x5.ru",
        "id.x5.ru",
        "api.vk.com",
        "max.ru",
        "eh.vk.com",
    )
private val DIRECT_RELAY_FAMILY_PRIORITY =
    listOf(
        "ads.x5.ru",
        "max.ru",
        "5post-gate.x5.ru",
        "id.x5.ru",
        "api.vk.com",
        "www.vk.ru",
        "www.vk.com",
        "i.oneme.ru",
    )

internal data class RealityRelayAutoselectOptions(
    val enabled: Boolean,
    val subscriptionUrl: String,
    val sourceLabel: String,
    val refreshIntervalHours: Long,
    val russianLatencyThresholdMs: Int,
    val latencyTimeoutMs: Int,
    val candidateLimit: Int,
    val maxPerSni: Int,
    val preferOwnerRelayStability: Boolean,
)

internal data class RealityRelayCandidate(
    val uri: String,
    val host: String,
    val port: Int,
    val uuid: String,
    val transport: String,
    val security: String,
    val sni: String,
    val tag: String?,
    val flow: String?,
    val fingerprint: String?,
    val publicKey: String,
    val shortId: String,
    val grpcServiceName: String?,
    val grpcAuthority: String?,
    val regionBucket: String,
    val preScore: Int,
    val tcpLatencyMs: Int? = null,
    val selectionScore: Int? = null,
) {
    fun exactKey(): String =
        listOf(
            host,
            port.toString(),
            sni,
            transport,
            security,
            flow.orEmpty(),
            publicKey,
            shortId,
        ).joinToString("|")

    fun familyKey(): String = sni

    fun toJson(): JSONObject =
        JSONObject()
            .put("uri", uri)
            .put("host", host)
            .put("port", port)
            .put("uuid", uuid)
            .put("transport", transport)
            .put("security", security)
            .put("sni", sni)
            .put("tag", tag)
            .put("flow", flow)
            .put("fingerprint", fingerprint)
            .put("publicKey", publicKey)
            .put("shortId", shortId)
            .put("grpcServiceName", grpcServiceName)
            .put("grpcAuthority", grpcAuthority)
            .put("regionBucket", regionBucket)
            .put("preScore", preScore)
            .put("tcpLatencyMs", tcpLatencyMs)
            .put("selectionScore", selectionScore)

    companion object {
        fun fromJson(obj: JSONObject): RealityRelayCandidate =
            RealityRelayCandidate(
                uri = obj.optString("uri", "").trim(),
                host = obj.optString("host", "").trim(),
                port = obj.optInt("port", 443).coerceAtLeast(1),
                uuid = obj.optString("uuid", "").trim(),
                transport = obj.optString("transport", "tcp").trim().ifBlank { "tcp" },
                security = obj.optString("security", "reality").trim().ifBlank { "reality" },
                sni = normalizeRelayHostname(obj.optString("sni", "")),
                tag = obj.optString("tag").trim().takeUnless { it.isBlank() },
                flow = obj.optString("flow").trim().takeUnless { it.isBlank() },
                fingerprint = obj.optString("fingerprint").trim().takeUnless { it.isBlank() },
                publicKey = obj.optString("publicKey", "").trim(),
                shortId = obj.optString("shortId", "").trim(),
                grpcServiceName = obj.optString("grpcServiceName").trim().takeUnless { it.isBlank() },
                grpcAuthority = obj.optString("grpcAuthority").trim().takeUnless { it.isBlank() },
                regionBucket = obj.optString("regionBucket", "other").trim().ifBlank { "other" },
                preScore = obj.optInt("preScore", 0),
                tcpLatencyMs = if (obj.has("tcpLatencyMs") && !obj.isNull("tcpLatencyMs")) obj.optInt("tcpLatencyMs") else null,
                selectionScore = if (obj.has("selectionScore") && !obj.isNull("selectionScore")) obj.optInt("selectionScore") else null,
            )
    }
}

internal data class RealityRelayAutoselectState(
    val enabled: Boolean = false,
    val status: String = RELAY_AUTOSELECT_STATUS_IDLE,
    val sourceLabel: String? = null,
    val subscriptionUrl: String? = null,
    val refreshIntervalHours: Long? = null,
    val russianLatencyThresholdMs: Int? = null,
    val latencyTimeoutMs: Int? = null,
    val candidateCount: Int = 0,
    val lastRefreshAt: String? = null,
    val lastError: String? = null,
    val bestCandidate: RealityRelayCandidate? = null,
) {
    fun toJson(): JSONObject =
        JSONObject()
            .put("enabled", enabled)
            .put("status", status)
            .put("sourceLabel", sourceLabel)
            .put("subscriptionUrl", subscriptionUrl)
            .put("refreshIntervalHours", refreshIntervalHours)
            .put("russianLatencyThresholdMs", russianLatencyThresholdMs)
            .put("latencyTimeoutMs", latencyTimeoutMs)
            .put("candidateCount", candidateCount)
            .put("lastRefreshAt", lastRefreshAt)
            .put("lastError", lastError)
            .put("bestCandidate", bestCandidate?.toJson())

    companion object {
        fun fromJson(raw: String?): RealityRelayAutoselectState {
            if (raw.isNullOrBlank()) {
                return RealityRelayAutoselectState()
            }
            return runCatching { fromObject(JSONObject(raw)) }.getOrDefault(RealityRelayAutoselectState())
        }

        fun fromObject(obj: JSONObject): RealityRelayAutoselectState =
            RealityRelayAutoselectState(
                enabled = obj.optBoolean("enabled", false),
                status = obj.optString("status", RELAY_AUTOSELECT_STATUS_IDLE).ifBlank { RELAY_AUTOSELECT_STATUS_IDLE },
                sourceLabel = obj.optString("sourceLabel").trim().takeUnless { it.isBlank() },
                subscriptionUrl = obj.optString("subscriptionUrl").trim().takeUnless { it.isBlank() },
                refreshIntervalHours = if (obj.has("refreshIntervalHours") && !obj.isNull("refreshIntervalHours")) obj.optLong("refreshIntervalHours") else null,
                russianLatencyThresholdMs = if (obj.has("russianLatencyThresholdMs") && !obj.isNull("russianLatencyThresholdMs")) obj.optInt("russianLatencyThresholdMs") else null,
                latencyTimeoutMs = if (obj.has("latencyTimeoutMs") && !obj.isNull("latencyTimeoutMs")) obj.optInt("latencyTimeoutMs") else null,
                candidateCount = obj.optInt("candidateCount", 0),
                lastRefreshAt = obj.optString("lastRefreshAt").trim().takeUnless { it.isBlank() },
                lastError = obj.optString("lastError").trim().takeUnless { it.isBlank() },
                bestCandidate = obj.optJSONObject("bestCandidate")?.let(RealityRelayCandidate::fromJson),
            )
    }
}

internal object RealityRelayAutoselectStore {
    fun snapshot(context: Context): RealityRelayAutoselectState =
        RealityRelayAutoselectState.fromJson(
            context.getSharedPreferences(RELAY_AUTOSELECT_PREFS_NAME, Context.MODE_PRIVATE)
                .getString(RELAY_AUTOSELECT_STATE_KEY, null),
        )

    fun write(
        context: Context,
        state: RealityRelayAutoselectState,
    ): RealityRelayAutoselectState {
        context.getSharedPreferences(RELAY_AUTOSELECT_PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(RELAY_AUTOSELECT_STATE_KEY, state.toJson().toString())
            .commit()
        return state
    }

    fun readHistory(context: Context): JSONObject =
        runCatching {
            JSONObject(
                context.getSharedPreferences(RELAY_AUTOSELECT_PREFS_NAME, Context.MODE_PRIVATE)
                    .getString(RELAY_AUTOSELECT_HISTORY_KEY, null)
                    ?: "",
            )
        }.getOrDefault(
            JSONObject()
                .put("entries", JSONObject())
                .put("families", JSONObject())
                .put("runs", JSONArray()),
        )

    fun writeHistory(
        context: Context,
        history: JSONObject,
    ) {
        context.getSharedPreferences(RELAY_AUTOSELECT_PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(RELAY_AUTOSELECT_HISTORY_KEY, history.toString())
            .commit()
    }
}

class RealityRelayAutoselectWorker(
    appContext: Context,
    params: WorkerParameters,
) : Worker(appContext, params) {
    override fun doWork(): Result {
        RealityRelayAutoselect.refreshNow(
            context = applicationContext,
            request = null,
            trigger = "periodic_work",
        )
        return Result.success()
    }
}

internal object RealityRelayAutoselect {
    fun normalizeRuntimeArgs(
        context: Context,
        args: JSObject,
        refreshIfStale: Boolean,
    ): JSObject {
        val request = JSObject(args.toString())
        val options = readOptionsFromRequest(request)
        if (options?.enabled == true) {
            VpnRuntimeRestoreStore.persistRelayAutoselectRequest(context, request)
        }
        syncSchedule(context, request)
        if (options?.enabled != true) {
            return request
        }
        val currentState = RealityRelayAutoselectStore.snapshot(context)
        val state =
            if (shouldRefreshOnStart(currentState, options, refreshIfStale)) {
                refreshNow(
                    context,
                    request = request,
                    trigger = if (options.preferOwnerRelayStability) "owner_start_refresh" else "start_refresh",
                )
            } else {
                currentState
            }
        val candidate = state.bestCandidate ?: return applyTelemetry(request, state)
        return applyTelemetry(
            patchRequestWithCandidate(request, candidate, options),
            state,
        )
    }

    fun appendTelemetry(
        context: Context,
        normalized: JSObject,
    ): JSObject = applyTelemetry(JSObject(normalized.toString()), RealityRelayAutoselectStore.snapshot(context))

    fun refreshNow(
        context: Context,
        request: JSObject? = null,
        trigger: String = "manual",
    ): RealityRelayAutoselectState {
        val effectiveRequest = request ?: resolveRelayRequest(context)
        val options = readOptionsFromRequest(effectiveRequest)
        if (options?.enabled != true || options.subscriptionUrl.isBlank()) {
            val disabledState =
                RealityRelayAutoselectState(
                    enabled = false,
                    status = RELAY_AUTOSELECT_STATUS_DISABLED,
                    lastRefreshAt = currentTimestamp(),
                )
            RealityRelayAutoselectStore.write(context, disabledState)
            updateSnapshotTelemetry(context, disabledState, "Relay autoselect is disabled; trigger=$trigger")
            cancelSchedule(context, clearPersistedRequest = true)
            Log.i(RELAY_AUTOSELECT_TAG, "Disabled relay autoselect and cancelled schedule; trigger=$trigger")
            return disabledState
        }

        val activeRequest = effectiveRequest ?: return RealityRelayAutoselectStore.snapshot(context)
        VpnRuntimeRestoreStore.persistRelayAutoselectRequest(context, activeRequest)
        syncSchedule(context, activeRequest)
        updateSnapshotTelemetry(
            context,
            RealityRelayAutoselectState(
                enabled = true,
                status = RELAY_AUTOSELECT_STATUS_REFRESHING,
                sourceLabel = options.sourceLabel,
                subscriptionUrl = options.subscriptionUrl,
                refreshIntervalHours = options.refreshIntervalHours,
                russianLatencyThresholdMs = options.russianLatencyThresholdMs,
                latencyTimeoutMs = options.latencyTimeoutMs,
                lastRefreshAt = currentTimestamp(),
            ),
            "Refreshing relay autoselect catalog; trigger=$trigger",
        )

        return runCatching {
            val catalog = loadRelayCatalog(options)
            val body = catalog.body
            val decodedBody = decodeSubscriptionBody(body)
            val parsed =
                mergeOwnerEgressStickyCandidates(
                    parseRelayCandidates(decodedBody),
                    options,
                )
            val history = RealityRelayAutoselectStore.readHistory(context)
            val availablePerSni = HashMap<String, Int>()
            parsed.forEach { candidate ->
                availablePerSni[candidate.sni] = (availablePerSni[candidate.sni] ?: 0) + 1
            }
            val ranked =
                parsed.mapNotNull { candidate ->
                    val scored = scoreCandidate(candidate, history, availablePerSni[candidate.sni] ?: 0)
                    scored
                }.sortedWith(
                    compareByDescending<RealityRelayCandidate> { it.preScore }
                        .thenBy { it.sni }
                        .thenBy { it.port }
                        .thenBy { it.host }
                        .thenBy { it.tag.orEmpty() },
                )
            val preselected = preselectCandidates(ranked, options, history)
            val measured =
                preselected.map { candidate ->
                    val latency = measureTcpLatencyMs(candidate.host, candidate.port, options.latencyTimeoutMs)
                    val score = candidate.preScore + (if (latency != null) max(0, 1500 - latency) else -40)
                    candidate.copy(tcpLatencyMs = latency, selectionScore = score)
                }
            val best = chooseBestCandidate(measured, options, history)
            val generatedAt = currentTimestamp()
            val updatedHistory = updateHistory(history, measured, best, generatedAt)
            RealityRelayAutoselectStore.writeHistory(context, updatedHistory)
            val state =
                RealityRelayAutoselectState(
                    enabled = true,
                    status = if (best != null) RELAY_AUTOSELECT_STATUS_READY else RELAY_AUTOSELECT_STATUS_NO_CANDIDATE,
                    sourceLabel = catalog.sourceLabel,
                    subscriptionUrl = options.subscriptionUrl,
                    refreshIntervalHours = options.refreshIntervalHours,
                    russianLatencyThresholdMs = options.russianLatencyThresholdMs,
                    latencyTimeoutMs = options.latencyTimeoutMs,
                    candidateCount = measured.size,
                    lastRefreshAt = generatedAt,
                    lastError = null,
                    bestCandidate = best,
                )
            RealityRelayAutoselectStore.write(context, state)
            updateSnapshotTelemetry(
                context,
                state,
                buildString {
                    append("Relay autoselect refresh completed; trigger=")
                    append(trigger)
                    append(" source=")
                    append(catalog.sourceLabel)
                    append(" status=")
                    append(state.status)
                    best?.let {
                        append(" best=")
                        append(it.sni)
                        append(" -> ")
                        append(it.host)
                        append(':')
                        append(it.port)
                        it.tcpLatencyMs?.let { latency ->
                            append(" latencyMs=")
                            append(latency)
                        }
                    }
                },
            )
            Log.i(
                RELAY_AUTOSELECT_TAG,
                "Relay autoselect refresh completed; trigger=$trigger source=${catalog.sourceLabel} status=${state.status} best=${state.bestCandidate?.sni ?: "<none>"} host=${state.bestCandidate?.host ?: "<none>"} port=${state.bestCandidate?.port ?: 0}",
            )
            state
        }.getOrElse { error ->
            val failed =
                RealityRelayAutoselectState(
                    enabled = true,
                    status = RELAY_AUTOSELECT_STATUS_FAILED,
                    sourceLabel = options.sourceLabel,
                    subscriptionUrl = options.subscriptionUrl,
                    refreshIntervalHours = options.refreshIntervalHours,
                    russianLatencyThresholdMs = options.russianLatencyThresholdMs,
                    latencyTimeoutMs = options.latencyTimeoutMs,
                    candidateCount = 0,
                    lastRefreshAt = currentTimestamp(),
                    lastError = error.message ?: error::class.java.simpleName,
                    bestCandidate = RealityRelayAutoselectStore.snapshot(context).bestCandidate,
                )
            RealityRelayAutoselectStore.write(context, failed)
            updateSnapshotTelemetry(
                context,
                failed,
                "Relay autoselect refresh failed; trigger=$trigger error=${error.message ?: error::class.java.simpleName}",
            )
            Log.e(RELAY_AUTOSELECT_TAG, "Relay autoselect refresh failed; trigger=$trigger", error)
            failed
        }
    }

    fun syncSchedule(
        context: Context,
        request: JSObject? = null,
    ) {
        val effectiveRequest = request ?: resolveRelayRequest(context)
        val options = readOptionsFromRequest(effectiveRequest)
        if (options?.enabled != true || options.subscriptionUrl.isBlank()) {
            cancelSchedule(context)
            return
        }
        effectiveRequest?.let { VpnRuntimeRestoreStore.persistRelayAutoselectRequest(context, it) }
        val constraints =
            Constraints.Builder()
                .setRequiredNetworkType(NetworkType.CONNECTED)
                .build()
        val work =
            PeriodicWorkRequestBuilder<RealityRelayAutoselectWorker>(
                options.refreshIntervalHours,
                TimeUnit.HOURS,
            ).setConstraints(constraints)
                .addTag(RELAY_AUTOSELECT_WORK_NAME)
                .build()
        WorkManager.getInstance(context)
            .enqueueUniquePeriodicWork(
                RELAY_AUTOSELECT_WORK_NAME,
                ExistingPeriodicWorkPolicy.UPDATE,
                work,
            )
        Log.i(
            RELAY_AUTOSELECT_TAG,
            "Scheduled relay autoselect periodic work every ${options.refreshIntervalHours}h source=${options.sourceLabel}",
        )
    }

    fun cancelSchedule(
        context: Context,
        clearPersistedRequest: Boolean = false,
    ) {
        WorkManager.getInstance(context).cancelUniqueWork(RELAY_AUTOSELECT_WORK_NAME)
        if (clearPersistedRequest) {
            VpnRuntimeRestoreStore.clearRelayAutoselectRequest(context)
        }
        Log.i(RELAY_AUTOSELECT_TAG, "Cancelled relay autoselect periodic work.")
    }

    private fun resolveRelayRequest(context: Context): JSObject? {
        val persisted = VpnRuntimeRestoreStore.readRelayAutoselectRequest(context)
        if (readOptionsFromRequest(persisted)?.enabled == true) {
            return persisted
        }
        val attempted = VpnRuntimeRestoreStore.readAttemptedStartRequest(context)
        if (readOptionsFromRequest(attempted)?.enabled == true) {
            return attempted
        }
        val restored = VpnRuntimeRestoreStore.readStartRequest(context)
        if (readOptionsFromRequest(restored)?.enabled == true) {
            return restored
        }
        return attempted ?: restored
    }

    private fun shouldRefresh(
        state: RealityRelayAutoselectState,
        options: RealityRelayAutoselectOptions,
    ): Boolean {
        if (!state.enabled) {
            return true
        }
        if (state.bestCandidate == null) {
            return true
        }
        val refreshedAt = state.lastRefreshAt ?: return true
        val refreshedMillis = runCatching { java.time.Instant.parse(refreshedAt).toEpochMilli() }.getOrNull() ?: return true
        val maxAgeMillis = options.refreshIntervalHours * 60L * 60L * 1000L
        return System.currentTimeMillis() - refreshedMillis >= maxAgeMillis
    }

    internal fun shouldRefreshOnStart(
        state: RealityRelayAutoselectState,
        options: RealityRelayAutoselectOptions,
        refreshIfStale: Boolean,
    ): Boolean =
        when {
            !refreshIfStale -> false
            options.preferOwnerRelayStability -> true
            // Direct public relays are volatile. A cached TCP-reachable candidate can stay
            // selected while no longer carrying real user traffic, so refresh on each start.
            refreshIfStale -> true
            else -> false
        }

    private fun readOptionsFromRequest(request: JSObject?): RealityRelayAutoselectOptions? {
        if (request == null) {
            return null
        }
        if (request.getString("protocol", "vless-reality")?.trim() != "vless-reality") {
            return null
        }
        val rawProfile = request.getString("profileJson", null)?.trim().takeUnless { it.isNullOrBlank() } ?: return null
        val profile = runCatching { JSObject(rawProfile) }.getOrNull() ?: return null
        val optionsBlock =
            profile.optJSONObject("androidRuntime")?.optJSONObject("realityVpsLab")?.optJSONObject("relayAutoselect")
                ?: profile.optJSONObject("runtimeOptions")?.optJSONObject("realityVpsLab")?.optJSONObject("relayAutoselect")
                ?: return null
        val subscriptionUrl =
            optionsBlock.optString("subscriptionUrl")
                .ifBlank { optionsBlock.optString("url") }
                .trim()
        val sourceLabel =
            optionsBlock.optString("sourceLabel")
                .trim()
                .takeUnless { it.isBlank() }
                ?: deriveSourceLabel(subscriptionUrl)
        return RealityRelayAutoselectOptions(
            enabled = optionsBlock.optBoolean("enabled", false),
            subscriptionUrl = subscriptionUrl,
            sourceLabel = sourceLabel,
            refreshIntervalHours =
                optionsBlock.optLong("refreshIntervalHours", RELAY_AUTOSELECT_DEFAULT_INTERVAL_HOURS)
                    .coerceIn(1L, 24L),
            russianLatencyThresholdMs =
                optionsBlock.optInt("russianLatencyThresholdMs", RELAY_AUTOSELECT_DEFAULT_THRESHOLD_MS)
                    .coerceIn(50, 5000),
            latencyTimeoutMs =
                optionsBlock.optInt("latencyTimeoutMs", RELAY_AUTOSELECT_DEFAULT_TIMEOUT_MS)
                    .coerceIn(200, 5000),
            candidateLimit =
                optionsBlock.optInt("candidateLimit", RELAY_AUTOSELECT_DEFAULT_CANDIDATE_LIMIT)
                    .coerceIn(1, 32),
            maxPerSni =
                optionsBlock.optInt("maxPerSni", RELAY_AUTOSELECT_DEFAULT_MAX_PER_SNI)
                    .coerceIn(1, 4),
            preferOwnerRelayStability =
                profile.optJSONObject("androidRuntime")
                    ?.optJSONObject("realityVpsLab")
                    ?.optBoolean("ownerRealityEgress", false)
                    ?: false,
        )
    }

    private fun patchRequestWithCandidate(
        request: JSObject,
        candidate: RealityRelayCandidate,
        options: RealityRelayAutoselectOptions,
    ): JSObject {
        val patched = JSObject(request.toString())
        val profile = JSObject(patched.getString("profileJson", "{}") ?: "{}")
        val runtime = profile.optJSONObject("androidRuntime") ?: JSObject().also { profile.put("androidRuntime", it) }
        val vpsLab = runtime.optJSONObject("realityVpsLab") ?: JSObject().also { runtime.put("realityVpsLab", it) }
        val relayAutoselect = vpsLab.optJSONObject("relayAutoselect") ?: JSObject().also { vpsLab.put("relayAutoselect", it) }
        relayAutoselect.put("enabled", true)
        relayAutoselect.put("subscriptionUrl", options.subscriptionUrl)
        relayAutoselect.put("sourceLabel", options.sourceLabel)
        relayAutoselect.put("refreshIntervalHours", options.refreshIntervalHours)
        relayAutoselect.put("russianLatencyThresholdMs", options.russianLatencyThresholdMs)
        relayAutoselect.put("latencyTimeoutMs", options.latencyTimeoutMs)
        relayAutoselect.put("candidateLimit", options.candidateLimit)
        relayAutoselect.put("maxPerSni", options.maxPerSni)

        val stagedFallbacks = profile.optJSONObject("stagedFallbacks") ?: JSObject().also { profile.put("stagedFallbacks", it) }
        val reality = stagedFallbacks.optJSONObject("vlessReality")
            ?: profile.optJSONObject("vlessReality")
            ?: JSObject().also { stagedFallbacks.put("vlessReality", it) }
        reality.put("port", candidate.port)
        reality.put("uuid", candidate.uuid)
        reality.put("serverName", candidate.sni)
        reality.put("publicKey", candidate.publicKey)
        reality.put("shortId", candidate.shortId)
        candidate.flow?.takeIf { it.isNotBlank() }?.let { reality.put("flow", it) }

        if (!options.preferOwnerRelayStability) {
            val baseReality = profile.optJSONObject("vlessReality") ?: JSObject().also { profile.put("vlessReality", it) }
            baseReality.put("port", candidate.port)
            baseReality.put("uuid", candidate.uuid)
            baseReality.put("serverName", candidate.sni)
            baseReality.put("publicKey", candidate.publicKey)
            baseReality.put("shortId", candidate.shortId)
            candidate.flow?.takeIf { it.isNotBlank() }?.let { baseReality.put("flow", it) }
        }

        vpsLab.put("enabled", true)
        if (vpsLab.optString("mode").isBlank()) {
            vpsLab.put("mode", "lab")
        }
        vpsLab.put("serverName", candidate.sni)
        vpsLab.put("port", candidate.port)
        vpsLab.put("connectHost", candidate.host)
        vpsLab.put("connectPort", candidate.port)
        vpsLab.put("transport", candidate.transport)
        candidate.flow?.takeIf { it.isNotBlank() }?.let { vpsLab.put("flow", it) }
        vpsLab.put("fingerprint", candidate.fingerprint ?: defaultRelayFingerprint(candidate.transport))
        candidate.grpcServiceName?.takeIf { it.isNotBlank() }?.let { vpsLab.put("grpcServiceName", it) }
        candidate.grpcAuthority?.takeIf { it.isNotBlank() }?.let { vpsLab.put("grpcAuthority", it) }
        vpsLab.put("source", "owner-auto:${options.sourceLabel}")
        vpsLab.put("tag", candidate.tag ?: buildDefaultRelayTag(candidate))

        patched.put("profileJson", profile.toString())
        return patched
    }

    private fun applyTelemetry(
        request: JSObject,
        state: RealityRelayAutoselectState,
    ): JSObject =
        JSObject(request.toString()).apply {
            put("relayAutoselectEnabled", state.enabled)
            put("relayAutoselectStatus", state.status)
            put("relayAutoselectSourceLabel", state.sourceLabel)
            put("relayAutoselectCandidateCount", state.candidateCount)
            put("relayAutoselectLastRefreshAt", state.lastRefreshAt)
            put("relayAutoselectRefreshIntervalHours", state.refreshIntervalHours)
            state.lastError?.let { put("relayAutoselectLastError", it) }
            state.bestCandidate?.let { best ->
                put("relayAutoselectBestHost", best.host)
                put("relayAutoselectBestPort", best.port)
                put("relayAutoselectBestSni", best.sni)
                put("relayAutoselectBestTag", best.tag)
                best.tcpLatencyMs?.let { put("relayAutoselectBestLatencyMs", it) }
            }
            val features =
                (optJSONArray("activeFeatures") ?: JSONArray()).let { existing ->
                    val set = LinkedHashSet<String>()
                    for (index in 0 until existing.length()) {
                        existing.optString(index).takeIf { it.isNotBlank() }?.let(set::add)
                    }
                    if (state.enabled) {
                        set.add("relay-autoselect")
                        set.add("relay-autoselect-status:${state.status}")
                        state.bestCandidate?.let { best ->
                            set.add("relay-autoselect-sni:${best.sni}")
                            set.add("relay-autoselect-connect:${best.host}")
                        }
                    }
                    JSONArray(set.toList())
                }
            put("activeFeatures", features)
        }

    private fun updateSnapshotTelemetry(
        context: Context,
        state: RealityRelayAutoselectState,
        message: String,
    ) {
        VpnRuntimeStore.update(context) { current ->
            current.copy(
                relayAutoselectEnabled = state.enabled,
                relayAutoselectStatus = state.status,
                relayAutoselectBestHost = state.bestCandidate?.host,
                relayAutoselectBestPort = state.bestCandidate?.port,
                relayAutoselectBestSni = state.bestCandidate?.sni,
                relayAutoselectBestTag = state.bestCandidate?.tag,
                relayAutoselectBestLatencyMs = state.bestCandidate?.tcpLatencyMs,
                relayAutoselectSourceLabel = state.sourceLabel,
                relayAutoselectCandidateCount = state.candidateCount,
                relayAutoselectLastRefreshAt = state.lastRefreshAt,
                relayAutoselectRefreshIntervalHours = state.refreshIntervalHours?.toInt(),
                relayAutoselectLastError = state.lastError,
                logTail = trimLogTail(current.logTail + message),
            )
        }
    }
}

internal fun parseRelayCandidates(subscriptionBody: String): List<RealityRelayCandidate> =
    subscriptionBody.lineSequence()
        .map { it.trim() }
        .filter { it.startsWith("vless://") }
        .mapNotNull(::parseRelayCandidate)
        .toList()

internal fun parseRelayCandidate(uri: String): RealityRelayCandidate? =
    runCatching {
        val parsed = URI(uri)
        val host = normalizeRelayHostname(parsed.host)
        val port = parsed.port.takeIf { it > 0 } ?: 443
        val uuid = parsed.userInfo?.trim().orEmpty()
        val query = parseRelayQuery(parsed.rawQuery)
        val transport = query["type"]?.lowercase(Locale.ROOT)?.ifBlank { "tcp" } ?: "tcp"
        val security = query["security"]?.lowercase(Locale.ROOT)?.ifBlank { "reality" } ?: "reality"
        val sni = normalizeRelayHostname(query["sni"])
        val publicKey = query["pbk"]?.trim().orEmpty()
        val shortId = query["sid"]?.trim().orEmpty()
        if (host.isBlank() || uuid.isBlank() || sni.isBlank() || publicKey.isBlank() || shortId.isBlank()) {
            return null
        }
        if (security != "reality") {
            return null
        }
        if (transport !in setOf("tcp", "grpc")) {
            return null
        }
        val tag = parsed.fragment?.trim().takeUnless { it.isNullOrBlank() }
        RealityRelayCandidate(
            uri = uri,
            host = host,
            port = port,
            uuid = uuid,
            transport = transport,
            security = security,
            sni = sni,
            tag = tag,
            flow = query["flow"]?.trim().takeUnless { it.isNullOrBlank() } ?: if (transport == "tcp") "xtls-rprx-vision" else null,
            fingerprint = query["fp"]?.trim().takeUnless { it.isNullOrBlank() } ?: defaultRelayFingerprint(transport),
            publicKey = publicKey,
            shortId = shortId,
            grpcServiceName = query["serviceName"]?.trim().takeUnless { it.isNullOrBlank() },
            grpcAuthority = query["authority"]?.trim().takeUnless { it.isNullOrBlank() },
            regionBucket = if (isRussianRelayLabel(tag, uri)) "russia" else "other",
            preScore = 0,
        )
    }.getOrNull()

internal fun scoreCandidate(
    candidate: RealityRelayCandidate,
    history: JSONObject,
    sniCount: Int,
): RealityRelayCandidate {
    var score = 0
    score += 50
    score += if (candidate.transport == "tcp") 25 else 16
    score += when (candidate.port) {
        443 -> 12
        7443, 8443 -> 8
        else -> 0
    }
    if (candidate.flow == "xtls-rprx-vision") {
        score += 8
    }
    score += 8
    score += min(sniCount, 8)
    if (candidate.regionBucket == "russia") {
        score += 60
    }

    val entryHistory = history.optJSONObject("entries")?.optJSONObject(candidate.exactKey())
    val familyHistory = history.optJSONObject("families")?.optJSONObject(candidate.familyKey())
    val exactPass = entryHistory?.optInt("passCount", 0) ?: 0
    val exactFail = entryHistory?.optInt("failCount", 0) ?: 0
    val familyPass = familyHistory?.optInt("passCount", 0) ?: 0
    val familyFail = familyHistory?.optInt("failCount", 0) ?: 0
    score += min(exactPass * 4, 20)
    score -= min(exactFail * 2, 12)
    score += min(familyPass * 2, 12)
    score -= min(familyFail, 8)

    score += probeHistoryScore(entryHistory, RELAY_PROBE_OWNER, exactWeight = 90, familyWeight = 35, failWeight = 45)
    score += probeHistoryScore(entryHistory, RELAY_PROBE_GOOGLEVIDEO, exactWeight = 55, familyWeight = 20, failWeight = 24)
    score += probeHistoryScore(entryHistory, RELAY_PROBE_GSTATIC, exactWeight = 25, familyWeight = 10, failWeight = 12)
    score += probeHistoryScore(entryHistory, RELAY_PROBE_YOUTUBE, exactWeight = 20, familyWeight = 8, failWeight = 10)
    score += probeHistoryScore(familyHistory, RELAY_PROBE_OWNER, exactWeight = 0, familyWeight = 18, failWeight = 12)
    score += probeHistoryScore(familyHistory, RELAY_PROBE_GOOGLEVIDEO, exactWeight = 0, familyWeight = 10, failWeight = 8)
    return candidate.copy(preScore = score)
}

private fun mergeOwnerEgressStickyCandidates(
    parsed: List<RealityRelayCandidate>,
    options: RealityRelayAutoselectOptions,
): List<RealityRelayCandidate> {
    if (!options.preferOwnerRelayStability) {
        return parsed
    }
    val merged = LinkedHashMap<String, RealityRelayCandidate>()
    stickyOwnerEgressCandidates().forEach { candidate ->
        merged[candidate.exactKey()] = candidate
    }
    parsed.forEach { candidate ->
        merged[candidate.exactKey()] = candidate
    }
    return merged.values.toList()
}

private fun stickyOwnerEgressCandidates(): List<RealityRelayCandidate> =
    OWNER_EGRESS_STICKY_CANDIDATE_URIS.mapNotNull(::parseRelayCandidate)

internal fun preselectCandidates(
    ranked: List<RealityRelayCandidate>,
    options: RealityRelayAutoselectOptions,
    history: JSONObject = JSONObject(),
): List<RealityRelayCandidate> {
    val selected = ArrayList<RealityRelayCandidate>(options.candidateLimit)
    val seen = LinkedHashSet<String>()
    val perSni = HashMap<String, Int>()
    val effectiveRanked =
        if (options.preferOwnerRelayStability) {
            ranked.sortedWith(
                compareBy<RealityRelayCandidate> { historySelectionTier(it, history) }
                    .thenBy<RealityRelayCandidate> { ownerEgressSecondHopTier(it, history) }
                    .thenBy<RealityRelayCandidate> { ownerEgressSeedTier(it) }
                    .thenByDescending { it.preScore }
                    .thenBy { it.sni }
                    .thenBy { it.port }
                    .thenBy { it.host },
            )
        } else {
            ranked.sortedWith(
                compareBy<RealityRelayCandidate> { directRelaySeedTier(it) }
                    .thenBy<RealityRelayCandidate> { directRelaySelectionTier(it, history) }
                    .thenByDescending { it.preScore }
                    .thenBy { it.sni }
                    .thenBy { it.port }
                    .thenBy { it.host },
            )
        }
    for (candidate in effectiveRanked) {
        if (selected.size >= options.candidateLimit) {
            break
        }
        if (!seen.add(candidate.exactKey())) {
            continue
        }
        val currentPerSni = perSni[candidate.sni] ?: 0
        if (currentPerSni >= options.maxPerSni) {
            continue
        }
        selected.add(candidate)
        perSni[candidate.sni] = currentPerSni + 1
    }
    return selected
}

private fun directRelaySeedTier(candidate: RealityRelayCandidate): Int {
    val familyIndex = DIRECT_RELAY_FAMILY_PRIORITY.indexOf(candidate.sni)
    val normalizedFamilyRank =
        if (familyIndex >= 0) {
            familyIndex
        } else {
            DIRECT_RELAY_FAMILY_PRIORITY.size + 10
        }
    val transportPenalty =
        when {
            candidate.transport == "tcp" && candidate.port == 443 -> 0
            candidate.transport == "tcp" -> 10
            else -> 20
        }
    return transportPenalty + normalizedFamilyRank
}

internal fun chooseBestCandidate(
    measured: List<RealityRelayCandidate>,
    options: RealityRelayAutoselectOptions,
    history: JSONObject? = null,
): RealityRelayCandidate? {
    val russianFast =
        measured.filter {
            it.regionBucket == "russia" &&
                it.tcpLatencyMs != null &&
                it.tcpLatencyMs <= options.russianLatencyThresholdMs
        }
    val reachable = measured.filter { it.tcpLatencyMs != null }
    val pool = if (russianFast.isNotEmpty()) russianFast else reachable
    val effectiveHistory = history ?: JSONObject()
    val comparator =
        if (options.preferOwnerRelayStability) {
            compareBy<RealityRelayCandidate> { historySelectionTier(it, effectiveHistory) }
                .thenBy<RealityRelayCandidate> { ownerEgressSecondHopTier(it, effectiveHistory) }
                .thenBy<RealityRelayCandidate> { ownerEgressSeedTier(it) }
                .thenByDescending<RealityRelayCandidate> { it.selectionScore ?: it.preScore }
                .thenBy { it.tcpLatencyMs ?: Int.MAX_VALUE }
                .thenBy { it.sni }
                .thenBy { it.host }
        } else {
            compareBy<RealityRelayCandidate> { directRelaySelectionTier(it, effectiveHistory) }
                .thenByDescending { it.selectionScore ?: it.preScore }
                .thenBy<RealityRelayCandidate> { it.tcpLatencyMs ?: Int.MAX_VALUE }
                .thenBy { it.sni }
                .thenBy { it.host }
        }
    return pool.minWithOrNull(
        comparator,
    )
}

private fun updateHistory(
    history: JSONObject,
    measured: List<RealityRelayCandidate>,
    best: RealityRelayCandidate?,
    generatedAt: String,
): JSONObject {
    val next = JSONObject(history.toString())
    val entries = next.optJSONObject("entries") ?: JSONObject().also { next.put("entries", it) }
    val families = next.optJSONObject("families") ?: JSONObject().also { next.put("families", it) }
    val runs = next.optJSONArray("runs") ?: JSONArray().also { next.put("runs", it) }
    measured.forEach { candidate ->
        val success = candidate.tcpLatencyMs != null
        val entry = entries.optJSONObject(candidate.exactKey()) ?: JSONObject().also { entries.put(candidate.exactKey(), it) }
        entry.put("passCount", entry.optInt("passCount", 0) + if (success) 1 else 0)
        entry.put("failCount", entry.optInt("failCount", 0) + if (success) 0 else 1)
        entry.put("lastLatencyMs", candidate.tcpLatencyMs)
        entry.put("lastSeen", generatedAt)
        entry.put("lastTag", candidate.tag)
        entry.put("lastOutcome", if (success) "reachable" else "timeout")

        val family = families.optJSONObject(candidate.familyKey()) ?: JSONObject().also { families.put(candidate.familyKey(), it) }
        family.put("passCount", family.optInt("passCount", 0) + if (success) 1 else 0)
        family.put("failCount", family.optInt("failCount", 0) + if (success) 0 else 1)
        family.put("lastLatencyMs", candidate.tcpLatencyMs)
        family.put("lastSeen", generatedAt)
        family.put("lastHost", candidate.host)
        family.put("lastTag", candidate.tag)
        family.put("lastOutcome", if (success) "reachable" else "timeout")
    }
    runs.put(
        JSONObject()
            .put("generatedAt", generatedAt)
            .put("bestSni", best?.sni)
            .put("bestHost", best?.host)
            .put("bestPort", best?.port)
            .put("bestLatencyMs", best?.tcpLatencyMs)
            .put("measuredCount", measured.size),
    )
    while (runs.length() > 30) {
        runs.remove(0)
    }
    next.put("generatedAt", generatedAt)
    return next
}

internal fun recordConnectivityProbeResult(
    context: Context,
    snapshot: TunnelSnapshot,
): Boolean {
    val test = snapshot.lastTest ?: return false
    val label = classifyRelayProbeLabel(test.url) ?: return false
    if (snapshot.runtimeFamily != "reality-vps-lab") {
        return false
    }
    val state = RealityRelayAutoselectStore.snapshot(context)
    val candidate = resolveRelayCandidateForProbe(context, snapshot, state.bestCandidate) ?: return false
    val checkedAt = test.checkedAt ?: currentTimestamp()
    val passed = test.ok && test.status == "passed"
    val history = RealityRelayAutoselectStore.readHistory(context)
    val updated = updateProbeHistory(history, candidate, label, passed, checkedAt, test.url, test.output, test.error)
    RealityRelayAutoselectStore.writeHistory(context, updated)
    Log.i(
        RELAY_AUTOSELECT_TAG,
        "Recorded relay probe result label=$label passed=$passed sni=${candidate.sni} host=${candidate.host} port=${candidate.port}",
    )
    return true
}

private data class RelayCatalogLoadResult(
    val body: String,
    val sourceLabel: String,
)

private fun loadRelayCatalog(options: RealityRelayAutoselectOptions): RelayCatalogLoadResult {
    val remoteBody =
        runCatching { fetchSubscriptionBody(options.subscriptionUrl) }
            .getOrElse { error ->
                Log.w(
                    RELAY_AUTOSELECT_TAG,
                    "Failed to fetch relay catalog from ${options.subscriptionUrl}; using embedded fallback.",
                    error,
                )
                ""
            }
    val decodedRemoteBody = decodeSubscriptionBody(remoteBody)
    val remoteCandidates =
        runCatching { parseRelayCandidates(decodedRemoteBody) }
            .getOrDefault(emptyList())
    if (remoteCandidates.isNotEmpty()) {
        return RelayCatalogLoadResult(
            body = remoteBody,
            sourceLabel = options.sourceLabel,
        )
    }
    Log.w(
        RELAY_AUTOSELECT_TAG,
        "Relay catalog from ${options.subscriptionUrl} is unavailable or empty; falling back to embedded candidates.",
    )
    return RelayCatalogLoadResult(
        body = EMBEDDED_RELAY_SUBSCRIPTION_BODY,
        sourceLabel = options.sourceLabel + RELAY_EMBEDDED_SOURCE_SUFFIX,
    )
}

private fun fetchSubscriptionBody(url: String): String {
    val connection = URL(url).openConnection() as HttpURLConnection
    return connection.run {
        requestMethod = "GET"
        connectTimeout = RELAY_AUTOSELECT_HTTP_TIMEOUT_MS
        readTimeout = RELAY_AUTOSELECT_HTTP_TIMEOUT_MS
        instanceFollowRedirects = true
        setRequestProperty("User-Agent", "odin-one-relay-autoselect/1")
        inputStream.bufferedReader().use { it.readText() }
    }
}

private fun decodeSubscriptionBody(rawBody: String): String {
    if (rawBody.contains("vless://")) {
        return rawBody
    }
    val compact = rawBody.filterNot(Char::isWhitespace)
    if (!compact.contains("dmxlc3M6Ly8", ignoreCase = true) && !compact.contains("vless://", ignoreCase = true)) {
        return rawBody
    }
    return runCatching {
        String(Base64.decode(compact, Base64.DEFAULT), Charsets.UTF_8)
    }.getOrDefault(rawBody)
}

private fun deriveSourceLabel(subscriptionUrl: String): String =
    runCatching { URL(subscriptionUrl).host.trim() }.getOrNull()
        ?.takeUnless { it.isBlank() }
        ?: "relay-autoselect"

private fun defaultRelayFingerprint(transport: String): String =
    if (transport == "grpc") "firefox" else "chrome"

private fun buildDefaultRelayTag(candidate: RealityRelayCandidate): String =
    "auto-" + slugifyRelayValue("${candidate.sni}-${candidate.host}-${candidate.port}-${candidate.transport}")

private fun parseRelayQuery(rawQuery: String?): Map<String, String> {
    if (rawQuery.isNullOrBlank()) {
        return emptyMap()
    }
    val query = LinkedHashMap<String, String>()
    rawQuery.split('&').forEach { part ->
        if (part.isBlank()) {
            return@forEach
        }
        val pieces = part.split('=', limit = 2)
        val key = decodeRelayQueryPart(pieces[0])
        val value = decodeRelayQueryPart(pieces.getOrElse(1) { "" })
        if (key.isNotBlank()) {
            query[key] = value
        }
    }
    return query
}

private fun decodeRelayQueryPart(value: String): String =
    runCatching { URLDecoder.decode(value, "UTF-8") }.getOrDefault(value)

internal fun isRussianRelayLabel(
    tag: String?,
    uri: String,
): Boolean {
    val text = listOf(tag.orEmpty(), uri)
        .joinToString(" ")
        .lowercase(Locale.ROOT)
    return listOf("russia", "рос", "🇷🇺").any(text::contains)
}

private fun normalizeRelayHostname(value: String?): String = value?.trim()?.lowercase(Locale.ROOT)?.trimEnd('.') ?: ""

private fun slugifyRelayValue(value: String): String =
    value.lowercase(Locale.ROOT)
        .replace(Regex("[^a-z0-9]+"), "-")
        .trim('-')
        .ifBlank { "candidate" }

private fun measureTcpLatencyMs(
    host: String,
    port: Int,
    timeoutMs: Int,
): Int? {
    var best: Int? = null
    repeat(2) {
        val socket = Socket()
        val started = SystemClock.elapsedRealtime()
        try {
            socket.connect(java.net.InetSocketAddress(host, port), timeoutMs)
            val elapsed = (SystemClock.elapsedRealtime() - started).toInt()
            best = if (best == null) elapsed else min(best ?: elapsed, elapsed)
        } catch (_: Exception) {
        } finally {
            runCatching { socket.close() }
        }
    }
    return best
}

private fun probeHistoryScore(
    targetHistory: JSONObject?,
    label: String,
    exactWeight: Int,
    familyWeight: Int,
    failWeight: Int,
): Int {
    if (targetHistory == null) {
        return 0
    }
    val probeHistory = targetHistory.optJSONObject("probes")?.optJSONObject(label) ?: return 0
    val passCount = probeHistory.optInt("passCount", 0)
    val failCount = probeHistory.optInt("failCount", 0)
    var score = 0
    if (exactWeight > 0) {
        score += min(passCount * exactWeight, exactWeight * 3)
    } else if (familyWeight > 0) {
        score += min(passCount * familyWeight, familyWeight * 3)
    }
    score -= min(failCount * failWeight, failWeight * 2)
    return score
}

private fun historySelectionTier(
    candidate: RealityRelayCandidate,
    history: JSONObject,
): Int {
    val entries = history.optJSONObject("entries")
    val families = history.optJSONObject("families")
    val exact = entries?.optJSONObject(candidate.exactKey())
    val family = families?.optJSONObject(candidate.familyKey())

    val exactOwner = probeHistoryPassed(exact, RELAY_PROBE_OWNER)
    val exactGeneric = genericProbePassed(exact)
    val familyOwner = probeHistoryPassed(family, RELAY_PROBE_OWNER)
    val familyGeneric = genericProbePassed(family)
    val exactClean = !hasProbeFailures(exact, RELAY_PROBE_OWNER, RELAY_PROBE_GOOGLEVIDEO, RELAY_PROBE_GSTATIC, RELAY_PROBE_YOUTUBE)
    val familyClean = !hasProbeFailures(family, RELAY_PROBE_OWNER, RELAY_PROBE_GOOGLEVIDEO, RELAY_PROBE_GSTATIC, RELAY_PROBE_YOUTUBE)
    val exactRecentFailure = hasRecentProbeFailure(exact, RELAY_PROBE_OWNER, RELAY_PROBE_GOOGLEVIDEO, RELAY_PROBE_GSTATIC, RELAY_PROBE_YOUTUBE)
    val familyRecentFailure = hasRecentProbeFailure(family, RELAY_PROBE_OWNER, RELAY_PROBE_GOOGLEVIDEO, RELAY_PROBE_GSTATIC, RELAY_PROBE_YOUTUBE)

    return when {
        exactOwner && exactGeneric && exactClean -> 0
        exactOwner && exactGeneric && !exactRecentFailure -> 1
        exactOwner && exactGeneric -> 2
        exactOwner && exactClean -> 3
        exactOwner -> 4
        familyOwner && familyGeneric && familyClean -> 5
        familyOwner && familyGeneric && !familyRecentFailure -> 6
        familyOwner && familyGeneric -> 7
        familyOwner && familyClean -> 8
        familyOwner -> 9
        else -> 10
    }
}

private fun directRelaySelectionTier(
    candidate: RealityRelayCandidate,
    history: JSONObject,
): Int {
    val entries = history.optJSONObject("entries")
    val families = history.optJSONObject("families")
    val exact = entries?.optJSONObject(candidate.exactKey())
    val family = families?.optJSONObject(candidate.familyKey())

    val exactOwner = probeHistoryPassed(exact, RELAY_PROBE_OWNER)
    val exactGeneric = genericProbePassed(exact)
    val familyOwner = probeHistoryPassed(family, RELAY_PROBE_OWNER)
    val familyGeneric = genericProbePassed(family)
    val exactClean =
        !hasProbeFailures(
            exact,
            RELAY_PROBE_OWNER,
            RELAY_PROBE_GOOGLEVIDEO,
            RELAY_PROBE_GSTATIC,
            RELAY_PROBE_YOUTUBE,
        )
    val familyClean =
        !hasProbeFailures(
            family,
            RELAY_PROBE_OWNER,
            RELAY_PROBE_GOOGLEVIDEO,
            RELAY_PROBE_GSTATIC,
            RELAY_PROBE_YOUTUBE,
        )
    val exactRecentFailure =
        hasRecentProbeFailure(
            exact,
            RELAY_PROBE_OWNER,
            RELAY_PROBE_GOOGLEVIDEO,
            RELAY_PROBE_GSTATIC,
            RELAY_PROBE_YOUTUBE,
        )
    val familyRecentFailure =
        hasRecentProbeFailure(
            family,
            RELAY_PROBE_OWNER,
            RELAY_PROBE_GOOGLEVIDEO,
            RELAY_PROBE_GSTATIC,
            RELAY_PROBE_YOUTUBE,
        )
    val preferredSeed = ownerEgressSeedTier(candidate)

    return when {
        exactOwner && exactGeneric && exactClean -> preferredSeed
        exactOwner && exactGeneric && !exactRecentFailure -> 5 + preferredSeed
        exactOwner && exactClean -> 10 + preferredSeed
        exactOwner -> 15 + preferredSeed
        familyOwner && familyGeneric && familyClean -> 20 + preferredSeed
        familyOwner && familyGeneric && !familyRecentFailure -> 25 + preferredSeed
        familyOwner && familyClean -> 30 + preferredSeed
        familyOwner -> 35 + preferredSeed
        exactGeneric && exactClean -> 40 + preferredSeed
        exactGeneric && !exactRecentFailure -> 45 + preferredSeed
        exactGeneric -> 50 + preferredSeed
        familyGeneric && familyClean -> 55 + preferredSeed
        familyGeneric && !familyRecentFailure -> 60 + preferredSeed
        familyGeneric -> 65 + preferredSeed
        exactClean && familyClean -> 70 + preferredSeed
        exactClean && !familyRecentFailure -> 75 + preferredSeed
        familyClean && !exactRecentFailure -> 80 + preferredSeed
        !exactRecentFailure && !familyRecentFailure -> 85 + preferredSeed
        else -> 90 + preferredSeed
    }
}

private fun ownerEgressSeedTier(candidate: RealityRelayCandidate): Int {
    val familyIndex = OWNER_EGRESS_RELAY_FAMILY_PRIORITY.indexOf(candidate.sni)
    val normalizedFamilyRank =
        if (familyIndex >= 0) {
            familyIndex
        } else {
            OWNER_EGRESS_RELAY_FAMILY_PRIORITY.size + 1
        }
    val transportPenalty =
        when {
            candidate.transport == "tcp" && candidate.port == 443 -> 0
            candidate.transport == "tcp" -> 8
            else -> 16
        }
    return transportPenalty + normalizedFamilyRank
}

private fun ownerEgressSecondHopTier(
    candidate: RealityRelayCandidate,
    history: JSONObject,
): Int {
    val provenIndex = OWNER_EGRESS_PROVEN_SECOND_HOP_FAMILY_PRIORITY.indexOf(candidate.sni)
    if (provenIndex < 0) {
        return OWNER_EGRESS_PROVEN_SECOND_HOP_FAMILY_PRIORITY.size + 10
    }

    val entries = history.optJSONObject("entries")
    val families = history.optJSONObject("families")
    val exact = entries?.optJSONObject(candidate.exactKey())
    val family = families?.optJSONObject(candidate.familyKey())
    val recentFailure =
        hasRecentProbeFailure(exact, RELAY_PROBE_OWNER, RELAY_PROBE_GOOGLEVIDEO, RELAY_PROBE_GSTATIC, RELAY_PROBE_YOUTUBE) ||
            hasRecentProbeFailure(family, RELAY_PROBE_OWNER, RELAY_PROBE_GOOGLEVIDEO, RELAY_PROBE_GSTATIC, RELAY_PROBE_YOUTUBE)

    return if (recentFailure) {
        100 + provenIndex
    } else {
        provenIndex
    }
}

private fun genericProbePassed(targetHistory: JSONObject?): Boolean =
    probeHistoryPassed(targetHistory, RELAY_PROBE_GOOGLEVIDEO) ||
        probeHistoryPassed(targetHistory, RELAY_PROBE_GSTATIC) ||
        probeHistoryPassed(targetHistory, RELAY_PROBE_YOUTUBE)

private fun probeHistoryPassed(
    targetHistory: JSONObject?,
    label: String,
): Boolean {
    val probeHistory = targetHistory?.optJSONObject("probes")?.optJSONObject(label) ?: return false
    return probeHistory.optInt("passCount", 0) > 0
}

private fun hasProbeFailures(
    targetHistory: JSONObject?,
    vararg labels: String,
): Boolean =
    labels.any { label ->
        val probeHistory = targetHistory?.optJSONObject("probes")?.optJSONObject(label) ?: return@any false
        probeHistory.optInt("failCount", 0) > 0
    }

private fun hasRecentProbeFailure(
    targetHistory: JSONObject?,
    vararg labels: String,
): Boolean =
    labels.any { label ->
        val probeHistory = targetHistory?.optJSONObject("probes")?.optJSONObject(label) ?: return@any false
        probeHistory.optString("lastOutcome", "").trim().equals("failed", ignoreCase = true)
    }

private fun classifyRelayProbeLabel(rawUrl: String?): String? {
    if (rawUrl.isNullOrBlank()) {
        return null
    }
    val url = runCatching { URL(rawUrl) }.getOrNull() ?: return null
    val host = normalizeRelayHostname(url.host)
    val path = url.path.trim()
    return when {
        host == "95-81-120-226.sslip.io" && path == "/_odin_probe_204" -> RELAY_PROBE_OWNER
        host == "redirector.googlevideo.com" && path == "/generate_204" -> RELAY_PROBE_GOOGLEVIDEO
        host == "www.gstatic.com" && path == "/generate_204" -> RELAY_PROBE_GSTATIC
        host == "www.youtube.com" -> RELAY_PROBE_YOUTUBE
        else -> null
    }
}

private fun relayCandidateFromSnapshot(
    snapshot: TunnelSnapshot,
    bestCandidate: RealityRelayCandidate?,
): RealityRelayCandidate? {
    val host = snapshot.frontConnectHost?.trim().orEmpty()
    val port = snapshot.frontConnectPort ?: return null
    val sni = snapshot.selectedSniHint?.trim().orEmpty()
    if (host.isBlank() || sni.isBlank()) {
        return null
    }
    if (bestCandidate != null &&
        normalizeRelayHostname(bestCandidate.host) == normalizeRelayHostname(host) &&
        bestCandidate.port == port &&
        normalizeRelayHostname(bestCandidate.sni) == normalizeRelayHostname(sni)
    ) {
        return bestCandidate
    }
    return RealityRelayCandidate(
        uri = "",
        host = normalizeRelayHostname(host),
        port = port,
        uuid = "",
        transport = "tcp",
        security = "reality",
        sni = normalizeRelayHostname(sni),
        tag = snapshot.frontTag?.trim()?.takeUnless { it.isBlank() },
        flow = "xtls-rprx-vision",
        fingerprint = null,
        publicKey = "",
        shortId = "",
        grpcServiceName = null,
        grpcAuthority = null,
        regionBucket = if (isRussianRelayLabel(snapshot.frontTag, snapshot.selectedSniHint ?: "")) "russia" else "other",
        preScore = 0,
        tcpLatencyMs = snapshot.relayAutoselectBestLatencyMs,
        selectionScore = null,
    )
}

private fun resolveRelayCandidateForProbe(
    context: Context,
    snapshot: TunnelSnapshot,
    bestCandidate: RealityRelayCandidate?,
): RealityRelayCandidate? {
    val attempted = relayCandidateFromRequest(VpnRuntimeRestoreStore.readAttemptedStartRequest(context))
    if (attempted != null && relayCandidateMatchesSnapshot(attempted, snapshot)) {
        return attempted
    }
    val persistedRelay = relayCandidateFromRequest(VpnRuntimeRestoreStore.readRelayAutoselectRequest(context))
    if (persistedRelay != null && relayCandidateMatchesSnapshot(persistedRelay, snapshot)) {
        return persistedRelay
    }
    if (bestCandidate != null && relayCandidateMatchesSnapshot(bestCandidate, snapshot)) {
        return bestCandidate
    }
    return relayCandidateFromSnapshot(snapshot, bestCandidate)
}

private fun relayCandidateMatchesSnapshot(
    candidate: RealityRelayCandidate,
    snapshot: TunnelSnapshot,
): Boolean {
    val host = normalizeRelayHostname(snapshot.frontConnectHost)
    val port = snapshot.frontConnectPort
    val sni = normalizeRelayHostname(snapshot.selectedSniHint)
    if (host.isBlank() || port == null || sni.isBlank()) {
        return false
    }
    return normalizeRelayHostname(candidate.host) == host &&
        candidate.port == port &&
        normalizeRelayHostname(candidate.sni) == sni
}

internal fun relayCandidateFromRequest(request: JSObject?): RealityRelayCandidate? {
    if (request == null) {
        return null
    }
    if ((request.getString("runtimeFamily", null) ?: "").trim() != "reality-vps-lab") {
        return null
    }
    val profileRaw = request.getString("profileJson", null)?.trim().takeUnless { it.isNullOrBlank() } ?: return null
    val profile = runCatching { JSObject(profileRaw) }.getOrNull() ?: return null
    val runtime =
        profile.optJSONObject("androidRuntime")
            ?.optJSONObject("realityVpsLab")
            ?: return null
    val staged =
        profile.optJSONObject("stagedFallbacks")
            ?.optJSONObject("vlessReality")
            ?: profile.optJSONObject("vlessReality")
            ?: JSObject()

    val host =
        normalizeRelayHostname(
            runtime.optString("connectHost").trim().takeUnless { it.isBlank() }
                ?: request.getString("vpsRealityConnectHost", null)
                ?: request.getString("frontConnectHost", null)
                ?: request.getString("serverHost", null),
        )
    val port =
        optJsonIntOrNull(runtime, "connectPort")
            ?: optJsIntOrNull(request, "vpsRealityConnectPort")
            ?: optJsIntOrNull(request, "frontConnectPort")
            ?: optJsonIntOrNull(runtime, "port")
            ?: optJsonIntOrNull(staged, "port")
            ?: 443
    val sni =
        normalizeRelayHostname(
            runtime.optString("serverName").trim().takeUnless { it.isBlank() }
                ?: request.getString("selectedSniHint", null)
                ?: staged.optString("serverName").trim().takeUnless { it.isBlank() },
        )
    val uuid =
        staged.optString("uuid").trim().takeUnless { it.isBlank() }
            ?.trim()
            .takeUnless { it.isNullOrBlank() }
            ?: return null
    val publicKey =
        staged.optString("publicKey").trim().takeUnless { it.isBlank() }
            ?.trim()
            .takeUnless { it.isNullOrBlank() }
            ?: return null
    val shortId =
        staged.optString("shortId").trim().takeUnless { it.isBlank() }
            ?.trim()
            .takeUnless { it.isNullOrBlank() }
            ?: return null
    if (host.isBlank() || sni.isBlank()) {
        return null
    }

    return RealityRelayCandidate(
        uri = "",
        host = host,
        port = port,
        uuid = uuid,
        transport = (runtime.optString("transport").trim().takeUnless { it.isBlank() } ?: request.getString("vpsRealityTransport", null) ?: "tcp").trim().ifBlank { "tcp" },
        security = "reality",
        sni = sni,
        tag =
            runtime.optString("tag").trim().takeUnless { it.isBlank() }
                ?.trim()
                .takeUnless { it.isNullOrBlank() }
                ?: request.getString("whitelistHintTag", null)?.trim()?.takeUnless { it.isNullOrBlank() },
        flow =
            runtime.optString("flow").trim().takeUnless { it.isBlank() }
                ?.trim()
                .takeUnless { it.isNullOrBlank() }
                ?: staged.optString("flow").trim().takeUnless { it.isBlank() },
        fingerprint =
            runtime.optString("fingerprint").trim().takeUnless { it.isBlank() }
                ?.trim()
                .takeUnless { it.isNullOrBlank() }
                ?: defaultRelayFingerprint((runtime.optString("transport").trim().takeUnless { it.isBlank() } ?: request.getString("vpsRealityTransport", null) ?: "tcp").trim().ifBlank { "tcp" }),
        publicKey = publicKey,
        shortId = shortId,
        grpcServiceName = runtime.optString("grpcServiceName").trim().takeUnless { it.isBlank() },
        grpcAuthority = runtime.optString("grpcAuthority").trim().takeUnless { it.isBlank() },
        regionBucket =
            if (isRussianRelayLabel(
                    runtime.optString("tag").trim().takeUnless { it.isBlank() } ?: request.getString("whitelistHintTag", null),
                    sni,
                )
            ) {
                "russia"
            } else {
                "other"
            },
        preScore = 0,
        tcpLatencyMs = snapshotLikeLatency(request),
        selectionScore = null,
    )
}

private fun snapshotLikeLatency(request: JSObject): Int? =
    optJsIntOrNull(request, "relayAutoselectBestLatencyMs")

private fun optJsonIntOrNull(
    obj: JSONObject,
    key: String,
): Int? = if (obj.has(key) && !obj.isNull(key)) obj.optInt(key) else null

private fun optJsIntOrNull(
    obj: JSObject,
    key: String,
): Int? = if (obj.has(key) && !obj.isNull(key)) obj.optInt(key) else null

private fun updateProbeHistory(
    history: JSONObject,
    candidate: RealityRelayCandidate,
    label: String,
    passed: Boolean,
    checkedAt: String,
    url: String?,
    output: String?,
    error: String?,
): JSONObject {
    val next = JSONObject(history.toString())
    val entries = next.optJSONObject("entries") ?: JSONObject().also { next.put("entries", it) }
    val families = next.optJSONObject("families") ?: JSONObject().also { next.put("families", it) }
    val entry = entries.optJSONObject(candidate.exactKey()) ?: JSONObject().also { entries.put(candidate.exactKey(), it) }
    val family = families.optJSONObject(candidate.familyKey()) ?: JSONObject().also { families.put(candidate.familyKey(), it) }
    val entryProbes = entry.optJSONObject("probes") ?: JSONObject().also { entry.put("probes", it) }
    val familyProbes = family.optJSONObject("probes") ?: JSONObject().also { family.put("probes", it) }
    val entryProbe = entryProbes.optJSONObject(label) ?: JSONObject().also { entryProbes.put(label, it) }
    val familyProbe = familyProbes.optJSONObject(label) ?: JSONObject().also { familyProbes.put(label, it) }
    listOf(entryProbe to entry, familyProbe to family).forEach { (probe, container) ->
        if (passed) {
            probe.put("passCount", probe.optInt("passCount", 0) + 1)
        } else {
            probe.put("failCount", probe.optInt("failCount", 0) + 1)
        }
        probe.put("lastOutcome", if (passed) "passed" else "failed")
        probe.put("lastSeen", checkedAt)
        url?.takeIf { it.isNotBlank() }?.let { probe.put("lastUrl", it) }
        output?.takeIf { it.isNotBlank() }?.let { probe.put("lastOutput", it) }
        error?.takeIf { it.isNotBlank() }?.let { probe.put("lastError", it) }
        container.put("lastSeen", checkedAt)
    }
    val runs = next.optJSONArray("runs") ?: JSONArray().also { next.put("runs", it) }
    runs.put(
        JSONObject()
            .put("generatedAt", checkedAt)
            .put("kind", "probe")
            .put("label", label)
            .put("passed", passed)
            .put("bestSni", candidate.sni)
            .put("bestHost", candidate.host)
            .put("bestPort", candidate.port),
    )
    while (runs.length() > 30) {
        runs.remove(0)
    }
    next.put("generatedAt", checkedAt)
    return next
}
