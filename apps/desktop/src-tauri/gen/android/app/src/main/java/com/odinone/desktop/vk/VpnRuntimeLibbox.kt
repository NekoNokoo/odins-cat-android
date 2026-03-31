package com.odinone.desktop.vk

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.os.Build
import android.system.OsConstants
import android.util.Log
import android.util.Base64
import app.tauri.plugin.JSObject
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.NetworkInterface
import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.RoutePrefix
import io.nekohasekai.libbox.StringBox
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.SystemProxyStatus
import io.nekohasekai.libbox.WIFIState
import java.io.File
import java.net.HttpURLConnection
import java.net.Inet6Address
import java.net.InetSocketAddress
import java.net.NetworkInterface as JavaNetworkInterface
import java.net.Proxy
import java.net.ServerSocket
import java.net.Socket
import java.net.URL
import java.security.MessageDigest
import java.security.KeyStore
import java.util.Locale
import kotlin.concurrent.thread
import org.json.JSONArray
import org.json.JSONObject

private const val DEFAULT_TUN_MTU = 1280
private const val DEFAULT_TUN_ADDRESS = "172.19.0.1/30"
private const val DEFAULT_TUN_DNS_ADDRESS = "172.19.0.2"
private const val DEFAULT_SOCKS_PORT = 58371
private const val DEFAULT_VK_BRIDGE_PORT = 39090
private const val DEFAULT_LOG_LINES = 3000L
private const val DEFAULT_HTTP_FALLBACK_TEST_URL = "http://example.com"
private const val REALITY_MODE_STABLE = "stable"
private const val REALITY_MODE_EXPERIMENTAL = "experimental"
private const val REALITY_DNS_MODE_UDP = "udp"
private const val REALITY_DNS_MODE_DOT = "dot"
private const val REALITY_DNS_MODE_DOH = "doh"
private const val REALITY_DNS_STRATEGY_PREFER_IPV4 = "prefer_ipv4"
private const val REALITY_DNS_STRATEGY_PREFER_IPV6 = "prefer_ipv6"
private const val REALITY_DNS_STRATEGY_IPV4_ONLY = "ipv4_only"
private const val REALITY_DNS_STRATEGY_IPV6_ONLY = "ipv6_only"
private const val REALITY_DNS_DEFAULT_SERVER = "1.1.1.1"
private const val REALITY_DNS_DEFAULT_SERVER_NAME = "cloudflare-dns.com"
private const val REALITY_DNS_DEFAULT_DOH_PATH = "/dns-query"
private const val REALITY_NETWORK_RELOAD_DEBOUNCE_DEFAULT_MS = 1500L
private const val REALITY_NETWORK_RELOAD_DEBOUNCE_MIN_MS = 250L
private const val REALITY_NETWORK_RELOAD_DEBOUNCE_MAX_MS = 5000L

data class PreparedRuntime(
    val configContent: String,
    val configPath: String,
    val socksAddress: String,
    val bridgeAddress: String? = null,
    val remotePeer: String? = null,
    val vkBinaryPath: String? = null,
    val vkArgs: List<String> = emptyList(),
    val configMode: String = REALITY_MODE_STABLE,
    val activeFeatures: List<String> = emptyList(),
    val profileHash: String? = null,
    val networkReloadOnChange: Boolean = false,
    val networkReloadDebounceMs: Long = REALITY_NETWORK_RELOAD_DEBOUNCE_DEFAULT_MS,
)

private data class RealitySettings(
    val serverHost: String,
    val serverPort: Int,
    val uuid: String,
    val flow: String,
    val serverName: String,
    val publicKey: String,
    val shortId: String,
)

private data class WireGuardSettings(
    val serverPublicKey: String,
    val clientPrivateKey: String,
    val address: String,
    val mtu: Int,
    val relayPort: Int,
)

private data class RealityRuntimeOptions(
    val mode: String,
    val dnsMode: String,
    val strictRoute: Boolean,
    val disableMultiplex: Boolean,
    val tlsFragment: Boolean,
    val recordFragment: Boolean,
    val bootRestoreEnabled: Boolean,
    val allowPrivateNetworkBypass: Boolean,
    val privateBypassCidrs: List<String>,
    val networkReloadOnChange: Boolean,
    val networkReloadDebounceMs: Long,
    val dnsServer: String,
    val dnsServerPort: Int?,
    val dnsServerName: String,
    val dnsDohPath: String,
    val dnsStrategy: String,
    val dnsDisableCache: Boolean,
    val dnsIndependentCache: Boolean,
    val includePackages: List<String>,
    val excludePackages: List<String>,
) {
    fun featureLabels(): List<String> =
        buildList {
            add("flow:xtls-rprx-vision")
            add("utls:chrome")
            add("mux:disabled")
            add("dns:$dnsMode")
            add("resolver:$dnsServer")
            add("dns-strategy:$dnsStrategy")
            add("mode:$mode")
            if (strictRoute) {
                add("strict-route")
            }
            if (tlsFragment) {
                add("tls-fragment")
            }
            if (recordFragment) {
                add("tls-record-fragment")
            }
            if (bootRestoreEnabled) {
                add("boot-restore")
            }
            if (networkReloadOnChange) {
                add("net-reload:${networkReloadDebounceMs}ms")
            }
            if (dnsDisableCache) {
                add("dns-cache:disabled")
            }
            if (dnsIndependentCache) {
                add("dns-cache:independent")
            }
            if (includePackages.isNotEmpty()) {
                add("pkg-include:${includePackages.size}")
            }
            if (excludePackages.isNotEmpty()) {
                add("pkg-exclude:${excludePackages.size}")
            }
            when {
                privateBypassCidrs.isNotEmpty() -> add("private-bypass:selective:${privateBypassCidrs.size}")
                allowPrivateNetworkBypass -> add("private-bypass:on")
                else -> add("private-bypass:off")
            }
        }
}

private class StringArray(
    private val values: List<String>,
) : StringIterator {
    private var index = 0

    override fun hasNext(): Boolean = index < values.size

    override fun len(): Int = values.size

    override fun next(): String = values[index++]
}

private class NetworkInterfaceArray(
    private val values: List<NetworkInterface>,
) : NetworkInterfaceIterator {
    private var index = 0

    override fun hasNext(): Boolean = index < values.size

    override fun next(): NetworkInterface = values[index++]
}

object VpnRuntimeLibbox {
    @Volatile
    private var initialized = false

    fun ensureInitialized(context: Context) {
        if (initialized) {
            return
        }
        synchronized(this) {
            if (initialized) {
                return
            }

            val baseDir = File(context.filesDir, "libbox").apply { mkdirs() }
            val workingDir = (context.getExternalFilesDir("vpn-runtime") ?: File(context.filesDir, "vpn-runtime"))
                .apply { mkdirs() }
            val tempDir = File(context.cacheDir, "libbox").apply { mkdirs() }

            Libbox.setLocale(Locale.getDefault().toLanguageTag().replace("-", "_"))
            Libbox.setup(
                io.nekohasekai.libbox.SetupOptions().apply {
                    basePath = baseDir.path
                    workingPath = workingDir.path
                    tempPath = tempDir.path
                    fixAndroidStack =
                        BuildConfig.DEBUG ||
                            (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N &&
                                Build.VERSION.SDK_INT <= Build.VERSION_CODES.N_MR1) ||
                            Build.VERSION.SDK_INT >= Build.VERSION_CODES.P
                    logMaxLines = DEFAULT_LOG_LINES
                    debug = BuildConfig.DEBUG
                },
            )
            Libbox.redirectStderr(File(workingDir, "libbox-stderr.log").path)
            initialized = true
        }
    }

    fun prepareRuntime(
        context: Context,
        args: JSObject,
    ): PreparedRuntime {
        ensureInitialized(context)

        val normalizedArgs = normalizeRuntimeArgs(args)
        val protocol = normalizedArgs.getString("protocol", "vless-reality")?.trim().orEmpty()
        val transport = normalizedArgs.getString("transport", "xray")?.trim().orEmpty()
        val rawProfile = normalizedArgs.getString("profileJson", "{}") ?: "{}"
        val profile = try {
            JSObject(rawProfile)
        } catch (error: Exception) {
            throw IllegalArgumentException("Failed to parse access profile for Android runtime: ${error.message}")
        }
        val serverHost = normalizedArgs.getString("serverHost", "")?.trim().orEmpty().ifBlank {
            profile.optString("serverHost", "").trim()
        }
        if (serverHost.isBlank()) {
            throw IllegalArgumentException("serverHost is required for Android runtime")
        }

        val socksPort = selectTcpPort(DEFAULT_SOCKS_PORT)
        val socksAddress = "127.0.0.1:$socksPort"
        val runtimeDir = File(context.filesDir, "vpn-runtime").apply { mkdirs() }

        val prepared = when (protocol) {
            "vless-reality" -> {
                val reality = readRealitySettings(profile, serverHost)
                val options = readRealityRuntimeOptions(normalizedArgs, profile)
                PreparedRuntime(
                    configContent = buildRealityConfig(socksPort, reality, options),
                    configPath = File(runtimeDir, "active-vless-reality.json").path,
                    socksAddress = socksAddress,
                    configMode = options.mode,
                    activeFeatures = options.featureLabels(),
                    profileHash = normalizedArgs.getString("profileHash", null),
                    networkReloadOnChange = options.networkReloadOnChange,
                    networkReloadDebounceMs = options.networkReloadDebounceMs,
                )
            }

            "direct-wireguard" -> {
                if (transport != "vk-turn-proxy+xray") {
                    throw IllegalArgumentException("Android direct-wireguard runtime currently expects VK relay transport")
                }
                val vkLink = args.getString("vkLink", "")?.trim().orEmpty()
                if (vkLink.isBlank()) {
                    throw IllegalArgumentException("VK call link is required for Android VK relay runtime")
                }
                val wireGuard = readWireGuardSettings(profile)
                val bridgePort = selectUdpPort(DEFAULT_VK_BRIDGE_PORT)
                val vkBinary = File(context.applicationInfo.nativeLibraryDir, "libvkturn.so")
                val vkCacheFile = File(runtimeDir, "vk-turn-creds.json")
                if (!vkBinary.exists()) {
                    throw IllegalArgumentException("Missing bundled libvkturn.so in Android runtime")
                }
                PreparedRuntime(
                    configContent = buildWireGuardConfig(socksPort, bridgePort, wireGuard),
                    configPath = File(runtimeDir, "active-vk-relay.json").path,
                    socksAddress = socksAddress,
                    bridgeAddress = "127.0.0.1:$bridgePort",
                    remotePeer = "$serverHost:${wireGuard.relayPort}",
                    vkBinaryPath = vkBinary.path,
                    vkArgs = buildVkTurnArgs(serverHost, wireGuard.relayPort, bridgePort, vkLink, vkCacheFile.path),
                )
            }

            else -> throw IllegalArgumentException("Unsupported Android runtime protocol: $protocol")
        }

        File(prepared.configPath).writeText(prepared.configContent)
        Libbox.checkConfig(prepared.configContent)
        return prepared
    }

    fun newRunningSnapshot(
        current: TunnelSnapshot,
        prepared: PreparedRuntime,
    ): TunnelSnapshot =
        current.copy(
            status = "running",
            socksAddress = prepared.socksAddress,
            bridgeAddress = prepared.bridgeAddress,
            profileHash = prepared.profileHash,
            configMode = prepared.configMode,
            activeFeatures = prepared.activeFeatures,
            error = null,
            logTail = trimLogTail(current.logTail + "Android VPN runtime is active."),
            lastTest = TunnelTestSnapshot(
                ok = false,
                status = "idle",
                url = "https://example.com",
            ),
        )

    fun newVkWarmupSnapshot(
        current: TunnelSnapshot,
        prepared: PreparedRuntime,
    ): TunnelSnapshot =
        current.copy(
            status = "starting",
            socksAddress = prepared.socksAddress,
            bridgeAddress = prepared.bridgeAddress,
            profileHash = prepared.profileHash,
            configMode = prepared.configMode,
            activeFeatures = prepared.activeFeatures,
            error = null,
            logTail = trimLogTail(current.logTail + "Waiting for VK relay warmup before marking the Android VPN runtime as ready."),
            lastTest = TunnelTestSnapshot(
                ok = false,
                status = "idle",
                url = "https://example.com",
            ),
        )

    fun runConnectivityTest(
        context: Context,
        rawUrl: String,
    ): TunnelSnapshot {
        val current = VpnRuntimeStore.snapshot(context)
        val targetUrl = rawUrl.ifBlank { "https://example.com" }
        Log.i("VpnRuntimeService", "Connectivity test requested for $targetUrl with status=${current.status} socks=${current.socksAddress ?: "<none>"}")
        if (current.status != "running" || current.socksAddress.isNullOrBlank()) {
            Log.i("VpnRuntimeService", "Connectivity test skipped because the Android VPN tunnel is not running.")
            return VpnRuntimeStore.update(context, sync = true) { latest ->
                latest.copy(
                    lastTest = TunnelTestSnapshot(
                        ok = false,
                        status = "failed",
                        url = targetUrl,
                        error = "Android VPN tunnel is not running.",
                        checkedAt = currentTimestamp(),
                    ),
                    logTail = trimLogTail(latest.logTail + "Connectivity test skipped because the Android VPN tunnel is not running."),
                )
            }
        }

        VpnRuntimeStore.update(
            context,
            sync = true,
        ) { latest ->
            latest.copy(
                lastTest = TunnelTestSnapshot(
                    ok = false,
                    status = "running",
                    url = targetUrl,
                    checkedAt = currentTimestamp(),
                ),
                logTail = trimLogTail(latest.logTail + "Connectivity test started for $targetUrl."),
            )
        }
        val (host, port) = splitHostAndPort(current.socksAddress)
        val proxy = Proxy(Proxy.Type.SOCKS, InetSocketAddress(host, port))
        val primary = runCatching {
            executeHttpProbe(targetUrl, proxy, "HEAD")
        }.getOrElse { error ->
            TunnelTestSnapshot(
                ok = false,
                status = "failed",
                url = targetUrl,
                error = error.message ?: "Android SOCKS probe failed.",
                checkedAt = currentTimestamp(),
            )
        }

        val outcome =
            if (!primary.ok &&
                primary.error != null &&
                targetUrl.startsWith("https://", ignoreCase = true) &&
                isCertificateValidationError(primary.error)
            ) {
                val fallback = runCatching {
                    executeHttpProbe(DEFAULT_HTTP_FALLBACK_TEST_URL, proxy, "GET")
                }.getOrElse { fallbackError ->
                    TunnelTestSnapshot(
                        ok = false,
                        status = "failed",
                        url = DEFAULT_HTTP_FALLBACK_TEST_URL,
                        error = fallbackError.message ?: "Android HTTP fallback probe failed.",
                        checkedAt = currentTimestamp(),
                    )
                }
                if (fallback.ok) {
                    fallback.copy(
                        url = targetUrl,
                        output =
                            "HTTPS probe hit app-side certificate validation; HTTP fallback via " +
                                "$DEFAULT_HTTP_FALLBACK_TEST_URL succeeded (${fallback.output ?: "ok"})",
                    )
                } else {
                    primary.copy(
                        error =
                            buildString {
                                append(primary.error)
                                fallback.error?.let {
                                    append(" HTTP fallback also failed: ")
                                    append(it)
                                }
                                fallback.output?.let {
                                    append(" HTTP fallback output: ")
                                    append(it)
                                }
                            },
                    )
                }
            } else {
                primary
            }

        val line =
            if (outcome.ok) {
                "Connectivity test passed for $targetUrl."
            } else {
                "Connectivity test failed for $targetUrl: ${outcome.error ?: outcome.output ?: "unknown error"}"
            }
        Log.i("VpnRuntimeService", line)
        return VpnRuntimeStore.update(context, sync = true) { latest ->
            latest.copy(
                lastTest = outcome,
                logTail = trimLogTail(latest.logTail + line),
            )
        }
    }

    private fun executeHttpProbe(
        targetUrl: String,
        proxy: Proxy,
        method: String,
    ): TunnelTestSnapshot {
        val connection = (URL(targetUrl).openConnection(proxy) as HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = 8_000
            readTimeout = 12_000
            instanceFollowRedirects = false
        }
        try {
            val code = connection.responseCode
            return if (code in 200..399) {
                TunnelTestSnapshot(
                    ok = true,
                    status = "passed",
                    url = targetUrl,
                    output = "HTTP $code",
                    checkedAt = currentTimestamp(),
                )
            } else {
                TunnelTestSnapshot(
                    ok = false,
                    status = "failed",
                    url = targetUrl,
                    output = "HTTP $code",
                    error = "SOCKS probe returned HTTP $code",
                    checkedAt = currentTimestamp(),
                )
            }
        } finally {
            connection.disconnect()
        }
    }

    private fun isCertificateValidationError(message: String): Boolean {
        val lower = message.lowercase(Locale.ROOT)
        return lower.contains("trust anchor") ||
            lower.contains("certpathvalidatorexception") ||
            lower.contains("sslhandshakeexception") ||
            lower.contains("certificate")
    }

    fun waitForLocalSocks(
        socksAddress: String,
        timeoutMs: Long,
    ) {
        val deadline = System.currentTimeMillis() + timeoutMs
        val (host, port) = splitHostAndPort(socksAddress)
        while (System.currentTimeMillis() < deadline) {
            runCatching {
                Socket().use { socket ->
                    socket.connect(InetSocketAddress(host, port), 300)
                }
            }.onSuccess {
                return
            }
            Thread.sleep(150)
        }
        throw IllegalStateException("Local SOCKS listener did not become ready on $socksAddress")
    }

    fun startVkTurnProcess(
        prepared: PreparedRuntime,
        onLogLine: (String) -> Unit,
    ): Process {
        val binary = prepared.vkBinaryPath
            ?: throw IllegalArgumentException("Missing vk-turn-proxy Android binary")
        val binaryFile = File(binary)
        val command = mutableListOf(binary).apply {
            addAll(prepared.vkArgs)
        }
        onLogLine(
            "Using vk-turn-proxy binary: path=$binary exists=${binaryFile.exists()} executable=${binaryFile.canExecute()} size=${binaryFile.length()}",
        )
        onLogLine("Launching vk-turn-proxy bridge: ${command.joinToString(" ")}")
        prepared.bridgeAddress?.let { onLogLine("vk-turn-proxy local bridge address: $it") }
        prepared.remotePeer?.let { onLogLine("vk-turn-proxy remote relay peer: $it") }
        val process = ProcessBuilder(command)
            .redirectErrorStream(true)
            .start()
        thread(name = "vkturn-log-reader", isDaemon = true) {
            runCatching {
                process.inputStream.bufferedReader().useLines { lines ->
                    lines.forEach { line ->
                        if (line.isNotBlank()) {
                            onLogLine(line.trim())
                        }
                    }
                }
            }.onFailure { error ->
                val message = error.message?.trim().orEmpty()
                val expectedShutdown =
                    message.contains("Stream closed", ignoreCase = true) ||
                        message.contains("closed", ignoreCase = true) ||
                        !process.isAlive
                if (!expectedShutdown) {
                    onLogLine("vk-turn-proxy log reader stopped unexpectedly: ${error.message ?: error::class.java.simpleName}")
                }
            }
        }
        return process
    }

    fun makeSystemProxyStatus(snapshot: TunnelSnapshot): SystemProxyStatus =
        SystemProxyStatus().apply {
            available = true
            enabled = snapshot.status == "running" && !snapshot.socksAddress.isNullOrBlank()
        }

    fun listPlatformInterfaces(context: Context): NetworkInterfaceIterator {
        val connectivity = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val javaInterfaces = JavaNetworkInterface.getNetworkInterfaces()?.toList().orEmpty()
        val interfaces =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                // Once the system VPN is active, activeNetwork can point at tun0 even though libbox still
                // needs the real upstream network for interface binding and reconnect logic.
                resolveUnderlyingDefaultNetwork(connectivity)
                    ?.let { network -> buildPlatformInterface(connectivity, javaInterfaces, network) }
                    ?.let(::listOf)
                    .orEmpty()
            } else {
                listLegacyPlatformInterfaces(connectivity, javaInterfaces)
            }
        return NetworkInterfaceArray(interfaces)
    }

    private fun buildPlatformInterface(
        connectivity: ConnectivityManager,
        javaInterfaces: List<JavaNetworkInterface>,
        network: android.net.Network,
    ): NetworkInterface? {
        val linkProperties = connectivity.getLinkProperties(network) ?: return null
        val capabilities = connectivity.getNetworkCapabilities(network) ?: return null
        val interfaceName = linkProperties.interfaceName ?: return null
        val javaInterface = javaInterfaces.firstOrNull { it.name == interfaceName } ?: return null
        return NetworkInterface().apply {
            name = interfaceName
            index = javaInterface.index
            mtu = runCatching { javaInterface.mtu }.getOrDefault(DEFAULT_TUN_MTU)
            addresses = StringArray(
                javaInterface.interfaceAddresses.mapNotNull { it.toPrefixOrNull() },
            )
            dnsServer = StringArray(linkProperties.dnsServers.mapNotNull { it.hostAddress })
            type =
                when {
                    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> Libbox.InterfaceTypeWIFI
                    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> Libbox.InterfaceTypeCellular
                    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> Libbox.InterfaceTypeEthernet
                    else -> Libbox.InterfaceTypeOther
                }
            flags = dumpFlags(javaInterface)
            metered = !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
        }
    }

    @Suppress("DEPRECATION")
    private fun listLegacyPlatformInterfaces(
        connectivity: ConnectivityManager,
        javaInterfaces: List<JavaNetworkInterface>,
    ): List<NetworkInterface> =
        connectivity.allNetworks.mapNotNull { network ->
            buildPlatformInterface(connectivity, javaInterfaces, network)
        }

    @Suppress("DEPRECATION")
    fun resolveUnderlyingDefaultNetwork(connectivity: ConnectivityManager): android.net.Network? {
        val active = connectivity.activeNetwork
        if (active != null && isUsableUnderlyingNetwork(connectivity, active)) {
            return active
        }

        return connectivity.allNetworks
            .mapNotNull { network ->
                val capabilities = connectivity.getNetworkCapabilities(network) ?: return@mapNotNull null
                if (!isUsableUnderlyingNetwork(capabilities)) {
                    return@mapNotNull null
                }
                network to scoreUnderlyingNetwork(capabilities)
            }.maxByOrNull { (_, score) -> score }
            ?.first
    }

    private fun isUsableUnderlyingNetwork(
        connectivity: ConnectivityManager,
        network: android.net.Network,
    ): Boolean = connectivity.getNetworkCapabilities(network)?.let(::isUsableUnderlyingNetwork) == true

    private fun isUsableUnderlyingNetwork(capabilities: NetworkCapabilities): Boolean =
        capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)

    private fun scoreUnderlyingNetwork(capabilities: NetworkCapabilities): Int {
        var score = 0
        if (capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) {
            score += 100
        }
        if (capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_TRUSTED)) {
            score += 40
        }
        if (capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_SUSPENDED)) {
            score += 20
        }
        if (capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)) {
            score += 10
        }
        score +=
            when {
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> 30
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> 25
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> 20
                else -> 5
            }
        return score
    }

    fun readWifiState(context: Context): WIFIState? {
        val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            ?: return null
        @Suppress("DEPRECATION")
        val wifiInfo = wifiManager.connectionInfo ?: return null
        var ssid = wifiInfo.ssid ?: return WIFIState("", "")
        if (ssid == "<unknown ssid>") {
            ssid = ""
        }
        if (ssid.startsWith("\"") && ssid.endsWith("\"") && ssid.length >= 2) {
            ssid = ssid.substring(1, ssid.length - 1)
        }
        return WIFIState(ssid, wifiInfo.bssid ?: "")
    }

    fun systemCertificates(): StringIterator {
        val certificates = mutableListOf<String>()
        val keyStore = KeyStore.getInstance("AndroidCAStore")
        keyStore.load(null, null)
        val aliases = keyStore.aliases()
        while (aliases.hasMoreElements()) {
            val certificate = keyStore.getCertificate(aliases.nextElement()) ?: continue
            certificates.add(
                "-----BEGIN CERTIFICATE-----\n" +
                    Base64.encodeToString(certificate.encoded, Base64.NO_WRAP) +
                    "\n-----END CERTIFICATE-----",
            )
        }
        return StringArray(certificates)
    }

    private fun readRealitySettings(
        profile: JSObject,
        serverHost: String,
    ): RealitySettings {
        val reality =
            profile.optJSONObject("vlessReality")
                ?: profile.optJSONObject("stagedFallbacks")?.optJSONObject("vlessReality")
                ?: throw IllegalArgumentException("The access profile does not contain VLESS + REALITY settings")
        val serverPort = reality.optInt("port", 0)
        val uuid = reality.optString("uuid", "").trim()
        val flow = reality.optString("flow", "xtls-rprx-vision").trim().ifBlank { "xtls-rprx-vision" }
        val serverName = reality.optString("serverName", "").trim()
        val publicKey = reality.optString("publicKey", "").trim()
        val shortId = reality.optString("shortId", "").trim()
        if (serverPort <= 0 || uuid.isBlank() || serverName.isBlank() || publicKey.isBlank() || shortId.isBlank()) {
            throw IllegalArgumentException("The VLESS + REALITY access profile is incomplete")
        }
        return RealitySettings(
            serverHost = serverHost,
            serverPort = serverPort,
            uuid = uuid,
            flow = flow,
            serverName = serverName,
            publicKey = publicKey,
            shortId = shortId,
        )
    }

    private fun readWireGuardSettings(profile: JSObject): WireGuardSettings {
        val wireGuard =
            profile.optJSONObject("wireguard")
                ?: profile.optJSONObject("wireGuard")
                ?: throw IllegalArgumentException("The access profile does not contain WireGuard settings")
        val serverPublicKey = wireGuard.optString("serverPublicKey", "").trim()
        val clientPrivateKey = wireGuard.optString("clientPrivateKey", "").trim()
        val address = wireGuard.optString("address", "").trim()
        val mtu = wireGuard.optInt("mtu", DEFAULT_TUN_MTU).coerceAtLeast(1280)
        val relayPort =
            profile.optInt("vkTurnProxyPort", 0).takeIf { it > 0 }
                ?: profile.optInt("endpointPort", 0).takeIf { it > 0 }
                ?: throw IllegalArgumentException("The VK relay access profile is missing the relay port")
        if (serverPublicKey.isBlank() || clientPrivateKey.isBlank() || address.isBlank()) {
            throw IllegalArgumentException("The VK relay access profile is missing WireGuard credentials")
        }
        return WireGuardSettings(
            serverPublicKey = serverPublicKey,
            clientPrivateKey = clientPrivateKey,
            address = address,
            mtu = mtu,
            relayPort = relayPort,
        )
    }

    private fun buildRealityConfig(
        socksPort: Int,
        reality: RealitySettings,
        options: RealityRuntimeOptions,
    ): String =
        when (options.mode) {
            REALITY_MODE_EXPERIMENTAL -> buildRealityConfigExperimental(socksPort, reality, options)
            else -> buildRealityConfigStable(socksPort, reality, options)
        }

    fun normalizeRuntimeArgs(args: JSObject): JSObject {
        val normalized =
            runCatching { JSObject(args.toString()) }
                .getOrElse { args }
        if (normalized.getString("protocol", "vless-reality")?.trim() != "vless-reality") {
            return normalized
        }

        val rawProfile = normalized.getString("profileJson", "{}") ?: "{}"
        val profile =
            runCatching { JSObject(rawProfile) }
                .getOrElse { return normalized }
        val options = readRealityRuntimeOptions(normalized, profile)
        normalized.put("configMode", options.mode)
        normalized.put("dnsMode", options.dnsMode)
        normalized.put("strictRoute", options.strictRoute)
        normalized.put("disableMultiplex", options.disableMultiplex)
        normalized.put("tlsFragment", options.tlsFragment)
        normalized.put("recordFragment", options.recordFragment)
        normalized.put("bootRestoreEnabled", options.bootRestoreEnabled)
        normalized.put("allowPrivateNetworkBypass", options.allowPrivateNetworkBypass)
        normalized.put("privateBypassCidrs", JSONArray(options.privateBypassCidrs))
        normalized.put("networkReloadOnChange", options.networkReloadOnChange)
        normalized.put("networkReloadDebounceMs", options.networkReloadDebounceMs)
        normalized.put("dnsServer", options.dnsServer)
        normalized.put("dnsServerPort", options.dnsServerPort)
        normalized.put("dnsServerName", options.dnsServerName)
        normalized.put("dnsDohPath", options.dnsDohPath)
        normalized.put("dnsStrategy", options.dnsStrategy)
        normalized.put("dnsDisableCache", options.dnsDisableCache)
        normalized.put("dnsIndependentCache", options.dnsIndependentCache)
        normalized.put("includePackages", JSONArray(options.includePackages))
        normalized.put("excludePackages", JSONArray(options.excludePackages))
        normalized.put("activeFeatures", JSONArray(options.featureLabels()))
        normalized.put("profileHash", computeRealityProfileHash(normalized, options))
        return normalized
    }

    private fun buildRealityConfigStable(
        socksPort: Int,
        reality: RealitySettings,
        options: RealityRuntimeOptions,
    ): String = buildRealityConfigDocument(socksPort, reality, options, leakHardened = false)

    private fun buildRealityConfigExperimental(
        socksPort: Int,
        reality: RealitySettings,
        options: RealityRuntimeOptions,
    ): String = buildRealityConfigDocument(socksPort, reality, options, leakHardened = true)

    private fun buildRealityConfigDocument(
        socksPort: Int,
        reality: RealitySettings,
        options: RealityRuntimeOptions,
        leakHardened: Boolean,
    ): String {
        val tls =
            JSONObject().put("enabled", true)
                .put("server_name", reality.serverName)
                .put(
                    "utls",
                    JSONObject()
                        .put("enabled", true)
                        .put("fingerprint", "chrome"),
                ).put(
                    "reality",
                    JSONObject()
                        .put("enabled", true)
                        .put("public_key", reality.publicKey)
                        .put("short_id", reality.shortId),
                )
        if (options.tlsFragment) {
            tls.put("fragment", true)
        }
        if (options.recordFragment) {
            tls.put("record_fragment", true)
        }

        val routeRules = JSONArray()
            .put(JSONObject().put("action", "sniff"))
            .put(JSONObject().put("protocol", "dns").put("action", "hijack-dns"))
            .put(
                JSONObject()
                    .put("type", "logical")
                    .put("mode", "and")
                    .put(
                        "rules",
                        JSONArray()
                            .put(JSONObject().put("ip_cidr", JSONArray().put("$DEFAULT_TUN_DNS_ADDRESS/32")))
                            .put(JSONObject().put("network", "tcp"))
                            .put(JSONObject().put("port", 853)),
                    ).put("action", "hijack-dns"),
            )
        if (leakHardened) {
            routeRules.put(
                JSONObject()
                    .put("type", "logical")
                    .put("mode", "or")
                    .put(
                        "rules",
                        JSONArray()
                            .put(JSONObject().put("network", "udp").put("port", 53))
                            .put(JSONObject().put("network", "tcp").put("port", 53))
                            .put(JSONObject().put("network", "udp").put("port", 853))
                            .put(JSONObject().put("network", "tcp").put("port", 853))
                            .put(JSONObject().put("port", 53))
                            .put(JSONObject().put("port", 853)),
                    ).put("action", "hijack-dns"),
            )
        }
        if (options.privateBypassCidrs.isNotEmpty()) {
            routeRules.put(
                JSONObject()
                    .put("ip_cidr", JSONArray(options.privateBypassCidrs))
                    .put("outbound", "direct"),
            )
        } else if (options.allowPrivateNetworkBypass) {
            routeRules.put(
                JSONObject()
                    .put("ip_is_private", true)
                    .put("outbound", "direct"),
            )
        }

        val config =
            JSONObject()
                .put("log", JSONObject().put("level", "warn"))
                .put(
                    "dns",
                    JSONObject()
                        .put("servers", JSONArray().put(buildRealityDnsServer(options)))
                        .put("final", "resolver")
                        .put("strategy", options.dnsStrategy)
                        .put("disable_cache", options.dnsDisableCache)
                        .put("independent_cache", options.dnsIndependentCache),
                ).put(
                    "inbounds",
                    JSONArray()
                        .put(
                            JSONObject()
                                .put("type", "tun")
                                .put("tag", "tun-in")
                                .put("address", JSONArray().put(DEFAULT_TUN_ADDRESS))
                                .put("mtu", DEFAULT_TUN_MTU)
                                .put("auto_route", true)
                                .put("strict_route", options.strictRoute)
                                .apply {
                                    if (options.includePackages.isNotEmpty()) {
                                        put("include_package", JSONArray(options.includePackages))
                                    }
                                    if (options.excludePackages.isNotEmpty()) {
                                        put("exclude_package", JSONArray(options.excludePackages))
                                    }
                                },
                        ).put(
                            JSONObject()
                                .put("type", "socks")
                                .put("tag", "socks-in")
                                .put("listen", "127.0.0.1")
                                .put("listen_port", socksPort),
                        ),
                ).put(
                    "outbounds",
                    JSONArray()
                        .put(
                            JSONObject()
                                .put("type", "vless")
                                .put("tag", "main-out")
                                .put("server", reality.serverHost)
                                .put("server_port", reality.serverPort)
                                .put("uuid", reality.uuid)
                                .put("flow", reality.flow)
                                .put("packet_encoding", "xudp")
                                .put("tls", tls)
                                .put(
                                    "multiplex",
                                    JSONObject().put("enabled", !options.disableMultiplex),
                                ),
                        ).put(
                            JSONObject()
                                .put("type", "direct")
                                .put("tag", "direct"),
                        ),
                ).put(
                    "route",
                    JSONObject()
                        .put("rules", routeRules)
                        .put("final", "main-out")
                        .put("auto_detect_interface", true)
                        .put("default_domain_resolver", "resolver"),
                )
        return config.toString(2)
    }

    private fun buildRealityDnsServer(options: RealityRuntimeOptions): JSONObject =
        when (options.dnsMode) {
            REALITY_DNS_MODE_DOH ->
                JSONObject()
                    .put("tag", "resolver")
                    .put("type", "https")
                    .put("server", options.dnsServer)
                    .put("server_port", options.dnsServerPort ?: 443)
                    .put("path", options.dnsDohPath)
                    .put(
                        "tls",
                        JSONObject().put("server_name", options.dnsServerName),
                    )

            REALITY_DNS_MODE_DOT ->
                JSONObject()
                    .put("tag", "resolver")
                    .put("type", "tls")
                    .put("server", options.dnsServer)
                    .put("server_port", options.dnsServerPort ?: 853)
                    .put(
                        "tls",
                        JSONObject().put("server_name", options.dnsServerName),
                    )

            else ->
                JSONObject()
                    .put("tag", "resolver")
                    .put("type", "udp")
                    .put("server", options.dnsServer)
                    .put("server_port", options.dnsServerPort ?: 53)
        }

    private fun readRealityRuntimeOptions(
        args: JSObject,
        profile: JSObject,
    ): RealityRuntimeOptions {
        val profileOptions =
            profile.optJSONObject("androidRuntime")?.optJSONObject("reality")
                ?: profile.optJSONObject("runtimeOptions")?.optJSONObject("reality")
                ?: profile.optJSONObject("androidReality")
        val mode =
            normalizeRealityMode(
                args.getString("configMode", null)
                    ?: profileOptions?.optString("mode").takeUnless { it.isNullOrBlank() },
            )
        val dnsMode =
            normalizeRealityDnsMode(
                args.getString("dnsMode", null)
                    ?: profileOptions?.optString("dnsMode").takeUnless { it.isNullOrBlank() }
                    ?: if (mode == REALITY_MODE_EXPERIMENTAL) {
                        REALITY_DNS_MODE_DOT
                    } else {
                        REALITY_DNS_MODE_UDP
                    },
            )
        val strictRoute =
            args.getBoolean(
                "strictRoute",
                profileOptions?.optBoolean("strictRoute", mode == REALITY_MODE_EXPERIMENTAL) ?: (mode == REALITY_MODE_EXPERIMENTAL),
            )
        val tlsFragment = args.getBoolean("tlsFragment", profileOptions?.optBoolean("tlsFragment", false) ?: false)
        val recordFragment = args.getBoolean("recordFragment", profileOptions?.optBoolean("recordFragment", false) ?: false)
        val bootRestoreEnabled =
            args.getBoolean("bootRestoreEnabled", profileOptions?.optBoolean("autoRestoreOnBoot", false) ?: false)
        val rawAllowPrivateNetworkBypass =
            args.getBoolean(
                "allowPrivateNetworkBypass",
                profileOptions?.optBoolean("allowPrivateNetworkBypass", true) ?: true,
            )
        val privateBypassCidrs = readStringListOption(args, "privateBypassCidrs", profileOptions, "privateBypassCidrs")
        val allowPrivateNetworkBypass = rawAllowPrivateNetworkBypass && privateBypassCidrs.isEmpty()
        val networkReloadOnChange =
            args.getBoolean(
                "networkReloadOnChange",
                profileOptions?.optBoolean("networkReloadOnChange", false) ?: false,
            )
        val networkReloadDebounceMs =
            normalizeRealityNetworkReloadDebounceMs(
                readLongOption(
                    args = args,
                    key = "networkReloadDebounceMs",
                    defaultValue = profileOptions?.optLong("networkReloadDebounceMs", REALITY_NETWORK_RELOAD_DEBOUNCE_DEFAULT_MS)
                        ?: REALITY_NETWORK_RELOAD_DEBOUNCE_DEFAULT_MS,
                ),
            )
        val dnsServer =
            args.getString("dnsServer", null)
                ?.trim()
                .takeUnless { it.isNullOrBlank() }
                ?: profileOptions?.optString("dnsServer").takeUnless { it.isNullOrBlank() }
                ?: REALITY_DNS_DEFAULT_SERVER
        val dnsServerPort =
            readNullableIntOption(
                args = args,
                key = "dnsServerPort",
                fallback = profileOptions?.optInt("dnsServerPort"),
            )
        val dnsDohPath =
            normalizeDohPath(
                args.getString("dnsDohPath", null)
                    ?.trim()
                    .takeUnless { it.isNullOrBlank() }
                    ?: profileOptions?.optString("dnsDohPath").takeUnless { it.isNullOrBlank() }
                    ?: REALITY_DNS_DEFAULT_DOH_PATH,
            )
        val dnsServerName =
            normalizeRealityDnsServerName(
                rawValue =
                    args.getString("dnsServerName", null)
                        ?.trim()
                        .takeUnless { it.isNullOrBlank() }
                        ?: profileOptions?.optString("dnsServerName").takeUnless { it.isNullOrBlank() },
                dnsServer = dnsServer,
                dnsMode = dnsMode,
            )
        validateRealityDnsServerAddress(
            dnsServer = dnsServer,
            dnsMode = dnsMode,
        )
        val dnsStrategy =
            normalizeRealityDnsStrategy(
                args.getString("dnsStrategy", null)
                    ?.trim()
                    .takeUnless { it.isNullOrBlank() }
                    ?: profileOptions?.optString("dnsStrategy").takeUnless { it.isNullOrBlank() }
                    ?: REALITY_DNS_STRATEGY_PREFER_IPV4,
            )
        val dnsDisableCache =
            args.getBoolean(
                "dnsDisableCache",
                profileOptions?.optBoolean("dnsDisableCache", false) ?: false,
            )
        val dnsIndependentCache =
            args.getBoolean(
                "dnsIndependentCache",
                profileOptions?.optBoolean("dnsIndependentCache", false) ?: false,
            )
        val includePackages = readStringListOption(args, "includePackages", profileOptions, "includePackages")
        val excludePackages = readStringListOption(args, "excludePackages", profileOptions, "excludePackages")
        if (includePackages.isNotEmpty() && excludePackages.isNotEmpty()) {
            throw IllegalArgumentException("Only one of includePackages or excludePackages may be set for Android REALITY runtime")
        }
        return RealityRuntimeOptions(
            mode = mode,
            dnsMode = dnsMode,
            strictRoute = strictRoute,
            disableMultiplex = true,
            tlsFragment = tlsFragment,
            recordFragment = recordFragment,
            bootRestoreEnabled = bootRestoreEnabled,
            allowPrivateNetworkBypass = allowPrivateNetworkBypass,
            privateBypassCidrs = privateBypassCidrs,
            networkReloadOnChange = networkReloadOnChange,
            networkReloadDebounceMs = networkReloadDebounceMs,
            dnsServer = dnsServer,
            dnsServerPort = dnsServerPort,
            dnsServerName = dnsServerName,
            dnsDohPath = dnsDohPath,
            dnsStrategy = dnsStrategy,
            dnsDisableCache = dnsDisableCache,
            dnsIndependentCache = dnsIndependentCache,
            includePackages = includePackages,
            excludePackages = excludePackages,
        )
    }

    private fun normalizeRealityMode(value: String?): String =
        if (value?.trim()?.lowercase(Locale.ROOT) == REALITY_MODE_EXPERIMENTAL) {
            REALITY_MODE_EXPERIMENTAL
        } else {
            REALITY_MODE_STABLE
        }

    private fun normalizeRealityDnsMode(value: String?): String =
        when (value?.trim()?.lowercase(Locale.ROOT)) {
            REALITY_DNS_MODE_DOT -> REALITY_DNS_MODE_DOT
            REALITY_DNS_MODE_DOH -> REALITY_DNS_MODE_DOH
            else -> REALITY_DNS_MODE_UDP
        }

    private fun normalizeRealityDnsStrategy(value: String?): String =
        when (value?.trim()?.lowercase(Locale.ROOT)) {
            REALITY_DNS_STRATEGY_PREFER_IPV6 -> REALITY_DNS_STRATEGY_PREFER_IPV6
            REALITY_DNS_STRATEGY_IPV4_ONLY -> REALITY_DNS_STRATEGY_IPV4_ONLY
            REALITY_DNS_STRATEGY_IPV6_ONLY -> REALITY_DNS_STRATEGY_IPV6_ONLY
            else -> REALITY_DNS_STRATEGY_PREFER_IPV4
        }

    private fun normalizeRealityNetworkReloadDebounceMs(value: Long): Long =
        value.coerceIn(REALITY_NETWORK_RELOAD_DEBOUNCE_MIN_MS, REALITY_NETWORK_RELOAD_DEBOUNCE_MAX_MS)

    private fun normalizeDohPath(value: String): String =
        when {
            value.isBlank() -> REALITY_DNS_DEFAULT_DOH_PATH
            value.startsWith("/") -> value
            else -> "/$value"
        }

    private fun normalizeRealityDnsServerName(
        rawValue: String?,
        dnsServer: String,
        dnsMode: String,
    ): String {
        val explicit = rawValue?.trim().orEmpty()
        if (explicit.isNotEmpty()) {
            return explicit
        }
        if (dnsServer == REALITY_DNS_DEFAULT_SERVER) {
            return REALITY_DNS_DEFAULT_SERVER_NAME
        }
        if (looksLikeIpLiteral(dnsServer)) {
            if (dnsMode == REALITY_DNS_MODE_UDP) {
                return ""
            }
            throw IllegalArgumentException("dnsServerName is required for encrypted DNS when dnsServer is an IP literal")
        }
        return dnsServer
    }

    private fun validateRealityDnsServerAddress(
        dnsServer: String,
        dnsMode: String,
    ) {
        if (dnsMode == REALITY_DNS_MODE_UDP) {
            return
        }
        if (!looksLikeIpLiteral(dnsServer)) {
            throw IllegalArgumentException(
                "Encrypted DNS currently requires dnsServer to be an IP literal and dnsServerName to carry the TLS hostname",
            )
        }
    }

    private fun readLongOption(
        args: JSObject,
        key: String,
        defaultValue: Long,
    ): Long {
        if (!args.has(key) || args.isNull(key)) {
            return defaultValue
        }
        return args.optLong(key, defaultValue)
    }

    private fun readNullableIntOption(
        args: JSObject,
        key: String,
        fallback: Int?,
    ): Int? {
        val raw =
            if (args.has(key) && !args.isNull(key)) {
                args.optInt(key)
            } else {
                fallback
        }
        return raw?.takeIf { it > 0 }
    }

    private fun readStringListOption(
        args: JSObject,
        key: String,
        profileOptions: JSONObject?,
        profileKey: String,
    ): List<String> {
        val fromArgs = args.optJSONArray(key)?.let(::parseJsonStringArray).orEmpty()
        if (fromArgs.isNotEmpty()) {
            return fromArgs
        }
        val fromProfile = profileOptions?.optJSONArray(profileKey)?.let(::parseJsonStringArray).orEmpty()
        return fromProfile
    }

    private fun parseJsonStringArray(array: JSONArray): List<String> =
        buildList(array.length()) {
            for (index in 0 until array.length()) {
                val value = array.optString(index, "").trim()
                if (value.isNotEmpty()) {
                    add(value)
                }
            }
        }

    private fun looksLikeIpLiteral(value: String): Boolean = value.all { char ->
        char.isDigit() || char == '.' || char == ':'
    }

    private fun computeRealityProfileHash(
        args: JSObject,
        options: RealityRuntimeOptions,
    ): String {
        val digest =
            buildString {
                append(args.getString("serverHost", "")?.trim().orEmpty())
                append('|')
                append(args.getString("transport", "")?.trim().orEmpty())
                append('|')
                append(args.getString("engine", "")?.trim().orEmpty())
                append('|')
                append(args.getString("protocol", "")?.trim().orEmpty())
                append('|')
                append(options.mode)
                append('|')
                append(options.dnsMode)
                append('|')
                append(options.strictRoute)
                append('|')
                append(options.disableMultiplex)
                append('|')
                append(options.tlsFragment)
                append('|')
                append(options.recordFragment)
                append('|')
                append(options.bootRestoreEnabled)
                append('|')
                append(options.allowPrivateNetworkBypass)
                append('|')
                append(options.privateBypassCidrs.joinToString(","))
                append('|')
                append(options.networkReloadOnChange)
                append('|')
                append(options.networkReloadDebounceMs)
                append('|')
                append(options.dnsServer)
                append('|')
                append(options.dnsServerPort ?: 0)
                append('|')
                append(options.dnsServerName)
                append('|')
                append(options.dnsDohPath)
                append('|')
                append(options.dnsStrategy)
                append('|')
                append(options.dnsDisableCache)
                append('|')
                append(options.dnsIndependentCache)
                append('|')
                append(options.includePackages.joinToString(","))
                append('|')
                append(options.excludePackages.joinToString(","))
                append('|')
                append(args.getString("profileJson", "{}") ?: "{}")
            }
        return sha256Hex(digest)
    }

    private fun sha256Hex(value: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8))
        return digest.joinToString("") { byte -> "%02x".format(byte) }
    }

    private fun buildWireGuardConfig(
        socksPort: Int,
        bridgePort: Int,
        wireGuard: WireGuardSettings,
    ): String =
        """
        {
          "log": {
            "level": "warn"
          },
          "dns": {
            "servers": [
              {
                "tag": "resolver",
                "type": "udp",
                "server": "1.1.1.1",
                "server_port": 53
              }
            ],
            "final": "resolver",
            "strategy": "prefer_ipv4"
          },
          "inbounds": [
            {
              "type": "tun",
              "tag": "tun-in",
              "address": [${
                  jsonString(DEFAULT_TUN_ADDRESS)
              }],
              "mtu": ${wireGuard.mtu},
              "auto_route": true,
              "strict_route": false
            },
            {
              "type": "socks",
              "tag": "socks-in",
              "listen": "127.0.0.1",
              "listen_port": $socksPort
            }
          ],
          "endpoints": [
            {
              "type": "wireguard",
              "tag": "wg-ep",
              "address": [${jsonString(wireGuard.address)}],
              "private_key": ${jsonString(wireGuard.clientPrivateKey)},
              "peers": [
                {
                  "address": "127.0.0.1",
                  "port": $bridgePort,
                  "public_key": ${jsonString(wireGuard.serverPublicKey)},
                  "allowed_ips": [
                    "0.0.0.0/0"
                  ],
                  "persistent_keepalive_interval": 30
                }
              ],
              "mtu": ${wireGuard.mtu}
            }
          ],
          "outbounds": [
            {
              "type": "direct",
              "tag": "direct"
            }
          ],
          "route": {
            "rules": [
              {
                "action": "sniff"
              },
              {
                "type": "logical",
                "mode": "and",
                "rules": [
                  {
                    "ip_cidr": [${jsonString("$DEFAULT_TUN_DNS_ADDRESS/32")}]
                  },
                  {
                    "network": "tcp"
                  },
                  {
                    "port": 853
                  }
                ],
                "action": "hijack-dns"
              },
              {
                "type": "logical",
                "mode": "or",
                "rules": [
                  {
                    "protocol": "dns"
                  },
                  {
                    "port": 53
                  },
                  {
                    "port": 853
                  }
                ],
                "action": "hijack-dns"
              },
              {
                "ip_is_private": true,
                "outbound": "direct"
              }
            ],
            "final": "wg-ep",
            "auto_detect_interface": true,
            "default_domain_resolver": "resolver"
          }
        }
        """.trimIndent()

    private fun buildVkTurnArgs(
        serverHost: String,
        relayPort: Int,
        bridgePort: Int,
        link: String,
        cachePath: String,
    ): List<String> {
        val linkFlag =
            if (link.contains("telemost.yandex", ignoreCase = true) || link.contains("yandex", ignoreCase = true)) {
                "-yandex-link"
            } else {
                "-vk-link"
            }
        return listOf(
            "-peer",
            "$serverHost:$relayPort",
            linkFlag,
            link,
            "-cache-file",
            cachePath,
            "-fresh-bootstrap-count",
            "4",
            "-n",
            "16",
            "-listen",
            "127.0.0.1:$bridgePort",
        )
    }

    private fun selectTcpPort(preferred: Int): Int {
        if (canBindTcp(preferred)) {
            return preferred
        }
        ServerSocket(0).use { socket ->
            return socket.localPort
        }
    }

    private fun selectUdpPort(preferred: Int): Int {
        if (canBindUdp(preferred)) {
            return preferred
        }
        java.net.DatagramSocket(0).use { socket ->
            return socket.localPort
        }
    }

    private fun canBindTcp(port: Int): Boolean =
        runCatching {
            ServerSocket().use { socket ->
                socket.reuseAddress = false
                socket.bind(InetSocketAddress("127.0.0.1", port))
            }
        }.isSuccess

    private fun canBindUdp(port: Int): Boolean =
        runCatching {
            java.net.DatagramSocket(null).use { socket ->
                socket.reuseAddress = false
                socket.bind(InetSocketAddress("127.0.0.1", port))
            }
        }.isSuccess

    private fun splitHostAndPort(address: String): Pair<String, Int> {
        val separator = address.lastIndexOf(':')
        require(separator > 0 && separator < address.length - 1) { "Invalid address: $address" }
        return address.substring(0, separator) to address.substring(separator + 1).toInt()
    }

    private fun dumpFlags(networkInterface: JavaNetworkInterface): Int {
        var flags = 0
        if (networkInterface.isUp) {
            flags = flags or OsConstants.IFF_UP or OsConstants.IFF_RUNNING
        }
        if (networkInterface.isLoopback) {
            flags = flags or OsConstants.IFF_LOOPBACK
        }
        if (networkInterface.isPointToPoint) {
            flags = flags or OsConstants.IFF_POINTOPOINT
        }
        if (networkInterface.supportsMulticast()) {
            flags = flags or OsConstants.IFF_MULTICAST
        }
        return flags
    }

    private fun java.net.InterfaceAddress.toPrefixOrNull(): String? {
        val hostAddress = address?.hostAddress ?: return null
        return if (address is Inet6Address) {
            "${Inet6Address.getByAddress(address.address).hostAddress}/$networkPrefixLength"
        } else {
            "$hostAddress/$networkPrefixLength"
        }
    }

    fun RoutePrefix.toIpPrefixString(): String = "${address()}/${prefix()}"

    fun StringBox.valueOrNull(): String? = value.takeIf { !it.isNullOrBlank() }

    fun defaultConnectionOwner(
        context: Context,
        ipProtocol: Int,
        sourceAddress: String,
        sourcePort: Int,
        destinationAddress: String,
        destinationPort: Int,
    ): io.nekohasekai.libbox.ConnectionOwner {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            throw UnsupportedOperationException("Android connection owner lookup requires API 29+")
        }
        val connectivity = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val uid =
            connectivity.getConnectionOwnerUid(
                ipProtocol,
                InetSocketAddress(sourceAddress, sourcePort),
                InetSocketAddress(destinationAddress, destinationPort),
            )
        if (uid == android.os.Process.INVALID_UID) {
            throw IllegalStateException("Connection owner not found")
        }
        val packages = context.packageManager.getPackagesForUid(uid)?.toList().orEmpty()
        return io.nekohasekai.libbox.ConnectionOwner().apply {
            userId = uid
            userName = packages.firstOrNull().orEmpty()
            setAndroidPackageNames(StringArray(packages))
        }
    }

    private fun jsonString(value: String): String = JSONObject.quote(value)
}
