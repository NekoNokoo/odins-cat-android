package com.odinone.desktop.vk

import android.content.Context
import app.tauri.plugin.JSArray
import app.tauri.plugin.JSObject

private const val PREFS_NAME = "odin_one_vpn_runtime"
private const val SNAPSHOT_KEY = "snapshot"
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
            val lines = ArrayList<String>(array.length())
            for (index in 0 until array.length()) {
                val line = array.optString(index, "")
                if (line.isNotBlank()) {
                    lines.add(line)
                }
            }
            return lines
        }
    }
}

object VpnRuntimeStore {
    fun snapshot(context: Context): TunnelSnapshot {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return TunnelSnapshot.fromJson(prefs.getString(SNAPSHOT_KEY, null))
    }

    fun write(context: Context, snapshot: TunnelSnapshot): TunnelSnapshot {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit().putString(SNAPSHOT_KEY, snapshot.toPersistedObject().toString()).apply()
        return snapshot
    }
}

fun currentTimestamp(): String = java.time.Instant.now().toString()

fun trimLogTail(lines: List<String>): List<String> = lines.takeLast(DEFAULT_LOG_TAIL_LINES)

private fun normalizeTunnelArg(value: String?): String = value?.trim().orEmpty()

fun isActiveTunnelStatus(status: String): Boolean = status == "starting" || status == "running"

fun matchesTunnelRequest(
    snapshot: TunnelSnapshot,
    args: JSObject,
): Boolean =
    normalizeTunnelArg(snapshot.serverHost) == normalizeTunnelArg(args.getString("serverHost", null)) &&
        normalizeTunnelArg(snapshot.transport) == normalizeTunnelArg(args.getString("transport", null)) &&
        normalizeTunnelArg(snapshot.engine) == normalizeTunnelArg(args.getString("engine", null)) &&
        normalizeTunnelArg(snapshot.protocol) == normalizeTunnelArg(args.getString("protocol", null)) &&
        normalizeTunnelArg(snapshot.vkLink) == normalizeTunnelArg(args.getString("vkLink", null))

fun startSnapshotFromArgs(args: JSObject, logLine: String): TunnelSnapshot =
    TunnelSnapshot(
        status = "starting",
        vkLink = args.getString("vkLink", null),
        serverHost = args.getString("serverHost", null),
        transport = args.getString("transport", null),
        engine = args.getString("engine", null),
        protocol = args.getString("protocol", null),
        logTail = listOf(logLine),
        lastTest = TunnelTestSnapshot(),
    )

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
