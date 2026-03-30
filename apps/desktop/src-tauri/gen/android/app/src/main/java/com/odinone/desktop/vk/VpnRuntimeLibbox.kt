package com.odinone.desktop.vk

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.os.Build
import android.system.OsConstants
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
import java.security.KeyStore
import java.util.Locale
import kotlin.concurrent.thread
import org.json.JSONObject

private const val DEFAULT_TUN_MTU = 1280
private const val DEFAULT_TUN_ADDRESS = "172.19.0.1/30"
private const val DEFAULT_TUN_DNS_ADDRESS = "172.19.0.2"
private const val DEFAULT_SOCKS_PORT = 58371
private const val DEFAULT_VK_BRIDGE_PORT = 39090
private const val DEFAULT_LOG_LINES = 3000L
private const val DEFAULT_HTTP_FALLBACK_TEST_URL = "http://example.com"

data class PreparedRuntime(
    val configContent: String,
    val configPath: String,
    val socksAddress: String,
    val bridgeAddress: String? = null,
    val remotePeer: String? = null,
    val vkBinaryPath: String? = null,
    val vkArgs: List<String> = emptyList(),
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

        val protocol = args.getString("protocol", "vless-reality")?.trim().orEmpty()
        val transport = args.getString("transport", "xray")?.trim().orEmpty()
        val rawProfile = args.getString("profileJson", "{}") ?: "{}"
        val profile = try {
            JSObject(rawProfile)
        } catch (error: Exception) {
            throw IllegalArgumentException("Failed to parse access profile for Android runtime: ${error.message}")
        }
        val serverHost = args.getString("serverHost", "")?.trim().orEmpty().ifBlank {
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
                PreparedRuntime(
                    configContent = buildRealityConfig(socksPort, reality),
                    configPath = File(runtimeDir, "active-vless-reality.json").path,
                    socksAddress = socksAddress,
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
        if (current.status != "running" || current.socksAddress.isNullOrBlank()) {
            val next = current.copy(
                lastTest = TunnelTestSnapshot(
                    ok = false,
                    status = "failed",
                    url = targetUrl,
                    error = "Android VPN tunnel is not running.",
                    checkedAt = currentTimestamp(),
                ),
                logTail = trimLogTail(current.logTail + "Connectivity test skipped because the Android VPN tunnel is not running."),
            )
            return VpnRuntimeStore.write(context, next)
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
                                append(primary.error ?: "Android HTTPS probe failed.")
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
        val next = current.copy(
            lastTest = outcome,
            logTail = trimLogTail(current.logTail + line),
        )
        return VpnRuntimeStore.write(context, next)
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
        val interfaces = mutableListOf<NetworkInterface>()
        val javaInterfaces = JavaNetworkInterface.getNetworkInterfaces()?.toList().orEmpty()
        for (network in connectivity.allNetworks) {
            val linkProperties = connectivity.getLinkProperties(network) ?: continue
            val capabilities = connectivity.getNetworkCapabilities(network) ?: continue
            val interfaceName = linkProperties.interfaceName ?: continue
            val javaInterface = javaInterfaces.firstOrNull { it.name == interfaceName } ?: continue
            val item = NetworkInterface().apply {
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
            interfaces.add(item)
        }
        return NetworkInterfaceArray(interfaces)
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
              "mtu": $DEFAULT_TUN_MTU,
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
          "outbounds": [
            {
              "type": "vless",
              "tag": "main-out",
              "server": ${jsonString(reality.serverHost)},
              "server_port": ${reality.serverPort},
              "uuid": ${jsonString(reality.uuid)},
              "flow": ${jsonString(reality.flow)},
              "packet_encoding": "xudp",
              "tls": {
                "enabled": true,
                "server_name": ${jsonString(reality.serverName)},
                "utls": {
                  "enabled": true,
                  "fingerprint": "chrome"
                },
                "reality": {
                  "enabled": true,
                  "public_key": ${jsonString(reality.publicKey)},
                  "short_id": ${jsonString(reality.shortId)}
                }
              }
            },
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
                "protocol": "dns",
                "action": "hijack-dns"
              },
              {
                "ip_is_private": true,
                "outbound": "direct"
              }
            ],
            "final": "main-out",
            "auto_detect_interface": true,
            "default_domain_resolver": "resolver"
          }
        }
        """.trimIndent()

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
