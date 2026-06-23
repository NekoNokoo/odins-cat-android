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
import java.net.Inet4Address
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
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicLong
import kotlin.concurrent.thread
import org.json.JSONArray
import org.json.JSONObject

private const val DEFAULT_TUN_MTU = 1280
private const val DEFAULT_TUN_ADDRESS = "172.19.0.1/30"
private const val DEFAULT_TUN_DNS_ADDRESS = "172.19.0.2"
private const val DEFAULT_SOCKS_PORT = 58371
private const val DEFAULT_NATIVE_SIDEcar_SOCKS_PORT = 58372
private const val DEFAULT_VK_BRIDGE_PORT = 39090
private const val DEFAULT_VK_TURN_STREAM_COUNT = 1
private const val MIN_VK_TURN_STREAM_COUNT = 1
private const val MAX_VK_TURN_STREAM_COUNT = 16
private const val DEFAULT_LOG_LINES = 3000L
private const val DEFAULT_HTTP_FALLBACK_TEST_URL = "http://example.com"
private const val DEFAULT_SPEEDTEST_LATENCY_URL = "https://www.gstatic.com/generate_204"
private const val DEFAULT_SPEEDTEST_DOWNLOAD_BYTES = 250_000_000L
private const val DEFAULT_SPEEDTEST_DOWNLOAD_URL = "https://speed.cloudflare.com/__down"
private const val DEFAULT_SPEEDTEST_WARMUP_DURATION_MS = 2_000L
private const val DEFAULT_SPEEDTEST_MEASURE_DURATION_MS = 8_000L
private const val DEFAULT_SPEEDTEST_STREAM_COUNT = 8
private const val MAX_SPEEDTEST_STREAM_COUNT = 8
private const val DEFAULT_SPEEDTEST_LATENCY_SAMPLE_COUNT = 4
private const val NETWORK_LENS_YANDEX_URL = "https://yandex.ru"
private const val NETWORK_LENS_GOOGLE_URL = "https://google.com"
private const val NETWORK_LENS_GEOLOOKUP_URL_PREFIX = "https://ipwho.is/"
private const val NETWORK_LENS_TIMEOUT_MS = 4500
private const val NETWORK_LENS_GEOLOOKUP_CACHE_TTL_MS = 6 * 60 * 60 * 1000L
private const val RUNTIME_FAMILY_DIRECT_REALITY = "direct-reality"
private const val RUNTIME_FAMILY_REALITY_WHITELIST_ASSISTED = "reality-whitelist-assisted"
private const val RUNTIME_FAMILY_REALITY_VPS_LAB = "reality-vps-lab"
private const val RUNTIME_FAMILY_CDN_ANTI_WHITELIST = "cdn-anti-whitelist"
private const val RUNTIME_FAMILY_VK_RELAY = "vk-relay"
private const val RUNTIME_FAMILY_HYSTERIA2 = "hysteria2-direct"
private const val ENGINE_SING_BOX = "sing-box"
private const val ENGINE_XRAY_NATIVE = "xray-native"
private const val ACTIVATION_STATE_ACTIVE = "active"
private const val ACTIVATION_STATE_SCAFFOLD_ONLY = "scaffold_only"
private const val REALITY_MODE_STABLE = "stable"
private const val REALITY_MODE_EXPERIMENTAL = "experimental"
private const val REALITY_WHITELIST_MODE_SCAFFOLD = "scaffold"
private const val REALITY_WHITELIST_MODE_LAB = "lab"
private const val REALITY_VPS_LAB_MODE_SCAFFOLD = "scaffold"
private const val REALITY_VPS_LAB_MODE_LAB = "lab"
private const val REALITY_VPS_LAB_TRANSPORT_TCP = "tcp"
private const val REALITY_VPS_LAB_TRANSPORT_GRPC = "grpc"
private const val REALITY_VPS_LAB_FINGERPRINT_CHROME = "chrome"
private const val REALITY_VPS_LAB_FINGERPRINT_FIREFOX = "firefox"
private const val REALITY_WHITELIST_SELECTION_ORDERED = "ordered"
private const val REALITY_WHITELIST_SELECTION_SOURCE_ROUND_ROBIN = "source-round-robin"
private const val CDN_MODE_SCAFFOLD = "scaffold"
private const val CDN_MODE_LAB = "lab"
private const val CDN_PROVIDER_GENERIC = "generic"
private const val CDN_TRANSPORT_WEBSOCKET = "websocket"
private const val CDN_TRANSPORT_XHTTP = "xhttp"
private const val CDN_TRANSPORT_HTTP_UPGRADE = "httpupgrade"
private const val CDN_XHTTP_MODE_STREAM_ONE = "stream-one"
private const val CDN_XHTTP_MODE_STREAM_UP = "stream-up"
private const val CDN_XHTTP_MODE_PACKET_UP = "packet-up"
private const val CDN_BOOTSTRAP_DIRECT_REALITY = "direct-reality"
private const val CDN_FRONT_SELECTION_ORDERED = "ordered"
private const val CDN_DEFAULT_FRONT_PATH = "/"
private const val CDN_DEFAULT_FRONT_PORT = 443
private const val CDN_DEFAULT_ORIGIN_PORT = 443
private const val CDN_ORIGIN_SCHEME_HTTPS = "https"
private const val CDN_ORIGIN_SCHEME_HTTP = "http"
private const val CDN_ROUTING_DNS_QUERY_STRATEGY_AUTO = "auto"
private const val CDN_ROUTING_DNS_QUERY_STRATEGY_USE_IP = "use_ip"
private const val CDN_ROUTING_DOMAIN_STRATEGY_IP_IF_NON_MATCH = "ip_if_non_match"
private const val CDN_ROUTING_DOMAIN_STRATEGY_AS_IS = "as_is"
private const val CDN_ROUTING_DOMAIN_MATCHER_HYBRID = "hybrid"
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
private val DEFAULT_LOCAL_BYPASS_DOMAIN_KEYWORDS =
    listOf(
        "vk",
        "ok.ru",
        "mail.ru",
        "gosuslugi",
        "mos.ru",
        "yandex",
        "ya.ru",
        "ozon",
        "wildberries",
        "avito",
        "kinopoisk",
        "dzen",
        "hh",
        "2gis",
        "rutube",
        "magnit",
        "5ka",
        "perekrestok",
        "alfabank",
        "alfaonline",
        "tbank",
        "t-bank",
        "tinkoff",
        "vtb",
        "sber",
        "sberbank",
        "gazprombank",
        "gpb",
        "pochta",
    )
private val DEFAULT_LOCAL_BYPASS_DOMAINS =
    listOf(
        "1018213540.rsc.cdn77.org",
        "avtodor-tr.ru",
        "b2c-ticket-sentry.onelya.ru",
        "bitrix.info",
        "bkvet.ru",
        "cdn1.ozonusercontent.com",
        "cms1.dzvr.ru",
        "counter.yadro.ru",
        "dzvr.ru",
        "emex.ru",
        "fairplay-proxy.ott.yandex.ru",
        "fssp.gov.ru",
        "gorzdrav.spb.ru",
        "gosuslugi.ru",
        "gov.ru",
        "graphql.kinopoisk.ru",
        "gu-st.ru",
        "lemanapro.ru",
        "leroymerlin.ru",
        "mobileapp.russianpost.ru",
        "esia.gosuslugi.ru",
        "lk.gosuslugi.ru",
        "pos.gosuslugi.ru",
        "mos.ru",
        "mosenergosbyt.ru",
        "mosreg.ru",
        "nalog.ru",
        "ozon.ru",
        "pgu.mos.ru",
        "pesc.ru",
        "pochta.ru",
        "reso.ru",
        "rosreestr.gov.ru",
        "rzd-bonus.ru",
        "rzd.ru",
        "showip.net",
        "sys.refocus.ru",
        "vshark.ttk.ru",
        "widevine-proxy.ott.yandex.ru",
        "xn--90aijkdmaud0d.xn--p1ai",
        "yandex.net",
        "yandex.ru",
        "ya.ru",
    )
private val DIRECT_REALITY_RUNTIME_ARTIFACTS = listOf("reality-whitelist-assisted-scaffold.json", "active-vless-reality-vps-lab.json", "reality-vps-lab-scaffold.json", "active-cdn-anti-whitelist.json", "cdn-anti-whitelist-scaffold.json", "active-vk-relay.json", "active-hysteria2.json")
private val REALITY_WHITELIST_RUNTIME_ARTIFACTS = listOf("active-vless-reality.json", "active-vless-reality-vps-lab.json", "reality-vps-lab-scaffold.json", "active-cdn-anti-whitelist.json", "cdn-anti-whitelist-scaffold.json", "active-vk-relay.json")
private val REALITY_VPS_LAB_RUNTIME_ARTIFACTS = listOf("active-vless-reality.json", "reality-whitelist-assisted-scaffold.json", "active-cdn-anti-whitelist.json", "cdn-anti-whitelist-scaffold.json", "active-vk-relay.json")
private val CDN_RUNTIME_ARTIFACTS = listOf("active-vless-reality.json", "reality-whitelist-assisted-scaffold.json", "active-vless-reality-vps-lab.json", "reality-vps-lab-scaffold.json", "active-vk-relay.json")
private val VK_RELAY_RUNTIME_ARTIFACTS = listOf("active-vless-reality.json", "reality-whitelist-assisted-scaffold.json", "active-vless-reality-vps-lab.json", "reality-vps-lab-scaffold.json", "active-cdn-anti-whitelist.json", "cdn-anti-whitelist-scaffold.json")
private val HYSTERIA2_RUNTIME_ARTIFACTS = listOf("active-vless-reality.json", "reality-whitelist-assisted-scaffold.json", "active-vless-reality-vps-lab.json", "reality-vps-lab-scaffold.json", "active-cdn-anti-whitelist.json", "cdn-anti-whitelist-scaffold.json", "active-vk-relay.json")

data class PreparedRuntime(
    val configContent: String,
    val configPath: String,
    val socksAddress: String,
    val bridgeAddress: String? = null,
    val remotePeer: String? = null,
    val vkBinaryPath: String? = null,
    val vkArgs: List<String> = emptyList(),
    val nativeBinaryPath: String? = null,
    val nativeArgs: List<String> = emptyList(),
    val nativeProcessLabel: String? = null,
    val skipVpnTunnel: Boolean = false,
    val runtimeFamily: String = RUNTIME_FAMILY_DIRECT_REALITY,
    val activationState: String = ACTIVATION_STATE_ACTIVE,
    val frontHost: String? = null,
    val frontConnectHost: String? = null,
    val frontConnectPort: Int? = null,
    val frontPath: String? = null,
    val frontProvider: String? = null,
    val frontTag: String? = null,
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
    val configMode: String = REALITY_MODE_STABLE,
    val activeFeatures: List<String> = emptyList(),
    val profileHash: String? = null,
    val networkReloadOnChange: Boolean = false,
    val networkReloadDebounceMs: Long = REALITY_NETWORK_RELOAD_DEBOUNCE_DEFAULT_MS,
)

private data class NetworkLensProbeOutcome(
    val url: String,
    val ok: Boolean,
    val httpStatus: Int? = null,
    val error: String? = null,
    val checkedAt: String = currentTimestamp(),
)

private data class NetworkLensEndpointDetails(
    val host: String,
    val ip: String? = null,
    val countryCode: String? = null,
    val country: String? = null,
    val error: String? = null,
)

private data class CachedGeoLookup(
    val countryCode: String? = null,
    val country: String? = null,
    val expiresAtMs: Long,
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

private data class Hysteria2Settings(
    val serverHost: String,
    val serverPort: Int,
    val password: String,
    val serverName: String,
    val certificatePublicKeySha256: String,
    val obfsType: String,
    val obfsPassword: String,
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
    val localBypassDomainKeywords: List<String>,
    val localBypassDomains: List<String>,
) {
    fun featureLabels(): List<String> =
        buildList {
            add("family:$RUNTIME_FAMILY_DIRECT_REALITY")
            add("activation:$ACTIVATION_STATE_ACTIVE")
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
            val localBypassCount = localBypassDomainKeywords.size + localBypassDomains.size
            if (localBypassCount > 0) {
                add("local-bypass:$localBypassCount")
            }
            when {
                privateBypassCidrs.isNotEmpty() -> add("private-bypass:selective:${privateBypassCidrs.size}")
                allowPrivateNetworkBypass -> add("private-bypass:on")
                else -> add("private-bypass:off")
            }
        }
}

private data class CdnAntiWhitelistRuntimeOptions(
    val mode: String,
    val provider: String,
    val transport: String,
    val xhttpMode: String?,
    val tlsAlpn: List<String>,
    val xmuxMaxConcurrency: Int?,
    val xmuxHMaxRequestTimes: Int?,
    val xmuxHMaxReusableSecs: Int?,
    val frontHost: String,
    val frontPort: Int,
    val connectHost: String,
    val connectPort: Int,
    val frontPath: String,
    val tlsServerName: String,
    val tlsAllowInsecure: Boolean,
    val httpHostHeader: String,
    val originHost: String,
    val originPort: Int,
    val originScheme: String,
    val originPath: String,
    val frontTag: String?,
    val frontSelection: String,
    val frontPoolSize: Int,
    val frontPool: List<CdnFrontCandidate>,
    val bootstrap: String,
    val routingPolicy: CdnRoutingPolicyOptions,
    val activationState: String,
) {
    fun selectedFrontLabel(): String =
        buildString {
            append(tlsServerName)
            frontTag?.takeIf { it.isNotBlank() }?.let {
                append(" [")
                append(it)
                append("]")
            }
            if (!frontHost.equals(connectHost, ignoreCase = true)) {
                append(" via ")
                append(frontHost)
            }
        }

    fun featureLabels(): List<String> =
        buildList {
            add("family:$RUNTIME_FAMILY_CDN_ANTI_WHITELIST")
            add("activation:$activationState")
            add("mode:$mode")
            add("cdn-provider:$provider")
            add("cdn-transport:$transport")
            xhttpMode?.takeIf { transport == CDN_TRANSPORT_XHTTP }?.let { add("cdn-xhttp-mode:$it") }
            if (tlsAlpn.isNotEmpty()) {
                add("cdn-alpn:${tlsAlpn.joinToString(",")}")
            }
            xmuxMaxConcurrency?.let { add("cdn-xmux-max-concurrency:$it") }
            xmuxHMaxRequestTimes?.let { add("cdn-xmux-hmax-requests:$it") }
            xmuxHMaxReusableSecs?.let { add("cdn-xmux-hmax-reuse-secs:$it") }
            add("cdn-front:$frontHost")
            add("cdn-front-port:$frontPort")
            if (!frontHost.equals(connectHost, ignoreCase = true) || frontPort != connectPort) {
                add("cdn-connect:$connectHost")
                add("cdn-connect-port:$connectPort")
            }
            add("cdn-front-sni:$tlsServerName")
            if (tlsAllowInsecure) {
                add("cdn-front-tls:insecure")
            }
            add("cdn-http-host:$httpHostHeader")
            frontTag?.takeIf { it.isNotBlank() }?.let { add("cdn-front-tag:$it") }
            add("cdn-front-selected:${selectedFrontLabel()}")
            add("cdn-front-selection:$frontSelection")
            add("cdn-front-pool:$frontPoolSize")
            add("cdn-origin:$originHost")
            add("cdn-origin-port:$originPort")
            add("cdn-origin-scheme:$originScheme")
            add("cdn-origin-path:$originPath")
            add("cdn-bootstrap:$bootstrap")
            addAll(routingPolicy.featureLabels())
        }
}

private data class CdnRoutingPolicyOptions(
    val dnsQueryStrategy: String,
    val domainStrategy: String,
    val domainMatcher: String,
    val directDomainKeywords: List<String>,
    val directDomains: List<String>,
    val blockedDomainKeywords: List<String>,
    val blockedDomains: List<String>,
    val blockSelectedFrontHost: Boolean,
) {
    val directRuleCount: Int
        get() = directDomainKeywords.size + directDomains.size

    val blockRuleCount: Int
        get() = blockedDomainKeywords.size + blockedDomains.size + if (blockSelectedFrontHost) 1 else 0

    fun isConfigured(): Boolean =
        dnsQueryStrategy != CDN_ROUTING_DNS_QUERY_STRATEGY_AUTO ||
            domainStrategy != CDN_ROUTING_DOMAIN_STRATEGY_IP_IF_NON_MATCH ||
            domainMatcher != CDN_ROUTING_DOMAIN_MATCHER_HYBRID ||
            directRuleCount > 0 ||
            blockRuleCount > 0

    fun featureLabels(): List<String> =
        buildList {
            if (!isConfigured()) {
                return@buildList
            }
            add("cdn-routing")
            add("cdn-routing-dns:$dnsQueryStrategy")
            add("cdn-routing-domain-strategy:$domainStrategy")
            add("cdn-routing-domain-matcher:$domainMatcher")
            if (directRuleCount > 0) {
                add("cdn-routing-direct:$directRuleCount")
            }
            if (blockRuleCount > 0) {
                add("cdn-routing-block:$blockRuleCount")
            }
            if (blockSelectedFrontHost) {
                add("cdn-routing-block-front")
            }
        }
}

private data class CdnFrontCandidate(
    val host: String,
    val port: Int,
    val connectHost: String,
    val connectPort: Int,
    val path: String,
    val tlsServerName: String,
    val tlsAllowInsecure: Boolean,
    val httpHostHeader: String,
    val provider: String,
    val tag: String?,
)

private data class RealityWhitelistHintRuntimeOptions(
    val mode: String,
    val selection: String,
    val selectedSniHint: String,
    val selectedCidrHint: String?,
    val whitelistHintSource: String?,
    val whitelistHintTag: String?,
    val hintPoolSize: Int,
    val hintPool: List<RealityWhitelistHintCandidate>,
    val bootstrap: String,
    val activationState: String,
    val baseRealityMode: String,
    val dnsMode: String,
    val dnsServer: String,
    val dnsStrategy: String,
) {
    fun featureLabels(): List<String> =
        buildList {
            add("family:$RUNTIME_FAMILY_REALITY_WHITELIST_ASSISTED")
            add("activation:$activationState")
            add("mode:$mode")
            add("whitelist-selection:$selection")
            add("whitelist-sni:$selectedSniHint")
            selectedCidrHint?.takeIf { it.isNotBlank() }?.let { add("whitelist-cidr:$it") }
            whitelistHintSource?.takeIf { it.isNotBlank() }?.let { add("whitelist-source:$it") }
            whitelistHintTag?.takeIf { it.isNotBlank() }?.let { add("whitelist-tag:$it") }
            add("whitelist-pool:$hintPoolSize")
            add("whitelist-bootstrap:$bootstrap")
            add("base-reality-mode:$baseRealityMode")
            add("dns:$dnsMode")
            add("resolver:$dnsServer")
            add("dns-strategy:$dnsStrategy")
        }
}

private data class RealityVpsLabRuntimeOptions(
    val mode: String,
    val serverName: String,
    val serverPort: Int,
    val connectHost: String,
    val connectPort: Int,
    val transport: String,
    val flow: String?,
    val fingerprint: String,
    val grpcServiceName: String?,
    val grpcAuthority: String?,
    val source: String?,
    val tag: String?,
    val ownerRealityEgress: Boolean,
    val activationState: String,
) {
    fun featureLabels(): List<String> =
        buildList {
            add("family:$RUNTIME_FAMILY_REALITY_VPS_LAB")
            add("activation:$activationState")
            add("mode:$mode")
            add("reality-vps-sni:$serverName")
            add("reality-vps-port:$serverPort")
            add("reality-vps-connect:$connectHost")
            add("reality-vps-connect-port:$connectPort")
            add("reality-vps-transport:$transport")
            add("reality-vps-fingerprint:$fingerprint")
            flow?.takeIf { it.isNotBlank() }?.let { add("reality-vps-flow:$it") }
            grpcServiceName?.takeIf { it.isNotBlank() }?.let { add("reality-vps-grpc-service:$it") }
            grpcAuthority?.takeIf { it.isNotBlank() }?.let { add("reality-vps-grpc-authority:$it") }
            source?.takeIf { it.isNotBlank() }?.let { add("reality-vps-source:$it") }
            tag?.takeIf { it.isNotBlank() }?.let { add("reality-vps-tag:$it") }
            add(if (ownerRealityEgress) "reality-vps-owner-egress:on" else "reality-vps-owner-egress:off")
        }
}

private data class RealityWhitelistHintCandidate(
    val serverName: String,
    val cidrBucket: String?,
    val source: String?,
    val tag: String?,
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
    private val geoLookupCache = ConcurrentHashMap<String, CachedGeoLookup>()

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

        val normalizedArgs = normalizeRuntimeArgs(context, args, refreshRelayAutoselect = true)
        val protocol = normalizedArgs.getString("protocol", "vless-reality")?.trim().orEmpty()
        val transport = normalizedArgs.getString("transport", "xray")?.trim().orEmpty()
        val runtimeFamily =
            normalizedArgs.getString("runtimeFamily", null)
                ?.trim()
                .takeUnless { it.isNullOrEmpty() }
                ?: when (protocol) {
                    "direct-wireguard" -> RUNTIME_FAMILY_VK_RELAY
                    "hysteria2" -> RUNTIME_FAMILY_HYSTERIA2
                    else -> RUNTIME_FAMILY_DIRECT_REALITY
                }
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
                when (runtimeFamily) {
                    RUNTIME_FAMILY_CDN_ANTI_WHITELIST ->
                        when (normalizeRuntimeEngine(normalizedArgs.getString("engine", null))) {
                            ENGINE_XRAY_NATIVE ->
                                prepareCdnAntiWhitelistXrayNativeRuntime(
                                    context = context,
                                    runtimeDir = runtimeDir,
                                    args = normalizedArgs,
                                    profile = profile,
                                    serverHost = serverHost,
                                    socksPort = socksPort,
                                    socksAddress = socksAddress,
                                )

                            else ->
                                prepareCdnAntiWhitelistRuntime(
                                    runtimeDir = runtimeDir,
                                    args = normalizedArgs,
                                    profile = profile,
                                    serverHost = serverHost,
                                    socksPort = socksPort,
                                    socksAddress = socksAddress,
                                )
                        }

                    RUNTIME_FAMILY_REALITY_VPS_LAB ->
                        prepareRealityVpsLabRuntime(
                            runtimeDir = runtimeDir,
                            args = normalizedArgs,
                            profile = profile,
                            serverHost = serverHost,
                            socksPort = socksPort,
                            socksAddress = socksAddress,
                        )

                    RUNTIME_FAMILY_REALITY_WHITELIST_ASSISTED ->
                        prepareRealityWhitelistAssistedRuntime(
                            runtimeDir = runtimeDir,
                            args = normalizedArgs,
                            profile = profile,
                            serverHost = serverHost,
                            socksPort = socksPort,
                            socksAddress = socksAddress,
                        )

                    else -> {
                        val reality = readRealitySettings(profile, serverHost)
                        val options = readRealityRuntimeOptions(normalizedArgs, profile)
                        PreparedRuntime(
                            configContent = buildRealityConfig(socksPort, reality, options),
                            configPath = File(runtimeDir, "active-vless-reality.json").path,
                            socksAddress = socksAddress,
                            runtimeFamily = RUNTIME_FAMILY_DIRECT_REALITY,
                            activationState = ACTIVATION_STATE_ACTIVE,
                            configMode = options.mode,
                            activeFeatures = options.featureLabels(),
                            profileHash = normalizedArgs.getString("profileHash", null),
                            networkReloadOnChange = options.networkReloadOnChange,
                            networkReloadDebounceMs = options.networkReloadDebounceMs,
                        )
                    }
                }
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
                val vkTurnStreamCount = readVkTurnStreamCount(normalizedArgs, profile)
                val requestedExcludePackages =
                    com.odinone.desktop.vk.normalizeSplitTunnelPackages(
                        com.odinone.desktop.vk.parseStringArray(normalizedArgs, "excludePackages"),
                    )
                val vkBinary = File(context.applicationInfo.nativeLibraryDir, "libvkturn.so")
                if (!vkBinary.exists()) {
                    throw IllegalArgumentException("Missing bundled libvkturn.so in Android runtime")
                }
                PreparedRuntime(
                    configContent = buildWireGuardConfig(socksPort, bridgePort, wireGuard, requestedExcludePackages),
                    configPath = File(runtimeDir, "active-vk-relay.json").path,
                    socksAddress = socksAddress,
                    bridgeAddress = "127.0.0.1:$bridgePort",
                    remotePeer = "$serverHost:${wireGuard.relayPort}",
                    vkBinaryPath = vkBinary.path,
                    vkArgs = buildVkTurnArgs(serverHost, wireGuard.relayPort, bridgePort, vkLink, vkTurnStreamCount),
                    runtimeFamily = RUNTIME_FAMILY_VK_RELAY,
                    activationState = ACTIVATION_STATE_ACTIVE,
                    activeFeatures =
                        buildList {
                            add("family:$RUNTIME_FAMILY_VK_RELAY")
                            add("activation:$ACTIVATION_STATE_ACTIVE")
                            add("vk-turn-streams:${normalizeVkTurnStreamCount(vkTurnStreamCount)}")
                            if (requestedExcludePackages.isNotEmpty()) {
                                add("pkg-exclude:${requestedExcludePackages.size}")
                            }
                            if (requestedExcludePackages.isNotEmpty()) {
                                add("split-tunnel:exclude:${requestedExcludePackages.size}")
                            }
                        },
                )
            }

            "hysteria2" -> {
                val hysteria2 = readHysteria2Settings(profile, serverHost)
                val options = readRealityRuntimeOptions(normalizedArgs, profile)
                PreparedRuntime(
                    configContent = buildHysteria2Config(socksPort, hysteria2, options),
                    configPath = File(runtimeDir, "active-hysteria2.json").path,
                    socksAddress = socksAddress,
                    runtimeFamily = RUNTIME_FAMILY_HYSTERIA2,
                    activationState = ACTIVATION_STATE_ACTIVE,
                    configMode = "beta",
                    activeFeatures =
                        options.featureLabels()
                            .filterNot { it.startsWith("family:") || it.startsWith("flow:") || it.startsWith("utls:") }
                            .plus(
                                listOf(
                                    "family:$RUNTIME_FAMILY_HYSTERIA2",
                                    "transport:quic",
                                    "obfs:salamander",
                                    "congestion:bbr",
                                    "tls:public-key-pin",
                                ),
                            ),
                    profileHash = normalizedArgs.getString("profileHash", null),
                    networkReloadOnChange = options.networkReloadOnChange,
                    networkReloadDebounceMs = options.networkReloadDebounceMs,
                )
            }

            else -> throw IllegalArgumentException("Unsupported Android runtime protocol: $protocol")
        }

        clearInactiveRuntimeArtifacts(runtimeDir, runtimeFamily)
        File(prepared.configPath).writeText(prepared.configContent)
        if (prepared.nativeBinaryPath.isNullOrBlank()) {
            Libbox.checkConfig(prepared.configContent)
        }
        return prepared
    }

    fun normalizeRuntimeArgs(
        context: Context,
        args: JSObject,
        refreshRelayAutoselect: Boolean = false,
    ): JSObject {
        val patched =
            com.odinone.desktop.vk.RealityRelayAutoselect.normalizeRuntimeArgs(
                context,
                args,
                refreshIfStale = refreshRelayAutoselect,
            )
        val normalized = normalizeRuntimeArgs(patched)
        return com.odinone.desktop.vk.RealityRelayAutoselect.appendTelemetry(context, normalized)
    }

    private fun clearInactiveRuntimeArtifacts(
        runtimeDir: File,
        runtimeFamily: String,
    ) {
        val staleArtifacts =
            when (runtimeFamily) {
                RUNTIME_FAMILY_REALITY_WHITELIST_ASSISTED -> REALITY_WHITELIST_RUNTIME_ARTIFACTS
                RUNTIME_FAMILY_REALITY_VPS_LAB -> REALITY_VPS_LAB_RUNTIME_ARTIFACTS
                RUNTIME_FAMILY_CDN_ANTI_WHITELIST -> CDN_RUNTIME_ARTIFACTS
                RUNTIME_FAMILY_VK_RELAY -> VK_RELAY_RUNTIME_ARTIFACTS
                RUNTIME_FAMILY_HYSTERIA2 -> HYSTERIA2_RUNTIME_ARTIFACTS
                else -> DIRECT_REALITY_RUNTIME_ARTIFACTS
            }
        staleArtifacts.forEach { filename ->
            runCatching { File(runtimeDir, filename).delete() }
        }
    }

    fun newRunningSnapshot(
        current: TunnelSnapshot,
        prepared: PreparedRuntime,
    ): TunnelSnapshot =
        current.copy(
            status = "running",
            socksAddress = prepared.socksAddress,
            bridgeAddress = prepared.bridgeAddress,
            runtimeFamily = prepared.runtimeFamily,
            activationState = prepared.activationState,
            frontHost = prepared.frontHost,
            frontConnectHost = prepared.frontConnectHost,
            frontConnectPort = prepared.frontConnectPort,
            frontPath = prepared.frontPath,
            frontProvider = prepared.frontProvider,
            frontTag = prepared.frontTag,
            cdnRoutingDnsQueryStrategy = prepared.cdnRoutingDnsQueryStrategy,
            cdnRoutingDomainStrategy = prepared.cdnRoutingDomainStrategy,
            cdnRoutingDomainMatcher = prepared.cdnRoutingDomainMatcher,
            cdnRoutingDirectRuleCount = prepared.cdnRoutingDirectRuleCount,
            cdnRoutingBlockRuleCount = prepared.cdnRoutingBlockRuleCount,
            cdnRoutingBlockSelectedFrontHost = prepared.cdnRoutingBlockSelectedFrontHost,
            cdnDnsLocalResolverEnabled = prepared.cdnDnsLocalResolverEnabled,
            selectedSniHint = prepared.selectedSniHint,
            selectedCidrHint = prepared.selectedCidrHint,
            whitelistHintSource = prepared.whitelistHintSource,
            whitelistHintTag = prepared.whitelistHintTag,
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
            runtimeFamily = prepared.runtimeFamily,
            activationState = prepared.activationState,
            frontHost = prepared.frontHost,
            frontConnectHost = prepared.frontConnectHost,
            frontConnectPort = prepared.frontConnectPort,
            frontPath = prepared.frontPath,
            frontProvider = prepared.frontProvider,
            frontTag = prepared.frontTag,
            cdnRoutingDnsQueryStrategy = prepared.cdnRoutingDnsQueryStrategy,
            cdnRoutingDomainStrategy = prepared.cdnRoutingDomainStrategy,
            cdnRoutingDomainMatcher = prepared.cdnRoutingDomainMatcher,
            cdnRoutingDirectRuleCount = prepared.cdnRoutingDirectRuleCount,
            cdnRoutingBlockRuleCount = prepared.cdnRoutingBlockRuleCount,
            cdnRoutingBlockSelectedFrontHost = prepared.cdnRoutingBlockSelectedFrontHost,
            cdnDnsLocalResolverEnabled = prepared.cdnDnsLocalResolverEnabled,
            selectedSniHint = prepared.selectedSniHint,
            selectedCidrHint = prepared.selectedCidrHint,
            whitelistHintSource = prepared.whitelistHintSource,
            whitelistHintTag = prepared.whitelistHintTag,
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
        val primary = executeHttpProbeWithLocalSocksRetries(targetUrl, proxy, "HEAD", host, port)

        val outcome =
            if (!primary.ok &&
                primary.error != null &&
                targetUrl.startsWith("https://", ignoreCase = true) &&
                isCertificateValidationError(primary.error)
            ) {
                val fallback =
                    executeHttpProbeWithLocalSocksRetries(
                        targetUrl = DEFAULT_HTTP_FALLBACK_TEST_URL,
                        proxy = proxy,
                        method = "GET",
                        proxyHost = host,
                        proxyPort = port,
                    )
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
        val updated = VpnRuntimeStore.update(context, sync = true) { latest ->
            latest.copy(
                lastTest = outcome,
                logTail = trimLogTail(latest.logTail + line),
            )
        }
        runCatching {
            com.odinone.desktop.vk.recordConnectivityProbeResult(context, updated)
        }.onFailure { error ->
            Log.w("VpnRuntimeService", "Failed to persist relay autoselect probe history", error)
        }
        return updated
    }

    fun runSpeedTest(
        context: Context,
        latencyUrl: String,
        downloadUrl: String,
        requestedDownloadBytes: Long,
        warmupDurationMs: Long,
        measureDurationMs: Long,
        streamCount: Int,
    ): TunnelSpeedTestSnapshot {
        val current = VpnRuntimeStore.snapshot(context)
        if (current.status != "running" || current.socksAddress.isNullOrBlank()) {
            return TunnelSpeedTestSnapshot(
                ok = false,
                status = "failed",
                latencyUrl = latencyUrl.ifBlank { DEFAULT_SPEEDTEST_LATENCY_URL },
                downloadUrl = downloadUrl.ifBlank { DEFAULT_SPEEDTEST_DOWNLOAD_URL },
                checkedAt = currentTimestamp(),
                warmupDurationMs = warmupDurationMs,
                streamCount = streamCount,
                measuredViaTunnel = true,
                error = "Android VPN tunnel is not running.",
            )
        }

        val resolvedLatencyUrl = latencyUrl.ifBlank { DEFAULT_SPEEDTEST_LATENCY_URL }
        val resolvedDownloadBytes =
            if (requestedDownloadBytes > 0) {
                requestedDownloadBytes
            } else {
                DEFAULT_SPEEDTEST_DOWNLOAD_BYTES
            }
        val resolvedDownloadUrl = downloadUrl.ifBlank { DEFAULT_SPEEDTEST_DOWNLOAD_URL }
        val resolvedWarmupDurationMs = warmupDurationMs.coerceAtLeast(0L)
        val resolvedMeasureDurationMs = measureDurationMs.coerceAtLeast(1L)
        val resolvedStreamCount =
            streamCount.coerceIn(1, MAX_SPEEDTEST_STREAM_COUNT)
        val (host, port) = splitHostAndPort(current.socksAddress)
        val proxy = Proxy(Proxy.Type.SOCKS, InetSocketAddress(host, port))

        VpnRuntimeStore.update(context, sync = true) { latest ->
            latest.copy(
                logTail =
                    trimLogTail(
                        latest.logTail +
                            "Speed test started for $resolvedDownloadUrl via $host:$port ($resolvedStreamCount streams, warmup ${resolvedWarmupDurationMs}ms, measure ${resolvedMeasureDurationMs}ms).",
                    ),
            )
        }

        return runCatching {
            val latencyResult = executeLatencyProbeWithLocalSocksRetries(resolvedLatencyUrl, proxy, "HEAD", host, port)
            if (!latencyResult.ok) {
                throw IllegalStateException(latencyResult.error ?: "Latency probe failed.")
            }

            val downloadResult = executeDownloadProbeWithLocalSocksRetries(
                targetUrl = resolvedDownloadUrl,
                requestedDownloadBytes = resolvedDownloadBytes,
                warmupDurationMs = resolvedWarmupDurationMs,
                measureDurationMs = resolvedMeasureDurationMs,
                streamCount = resolvedStreamCount,
                proxy = proxy,
                proxyHost = host,
                proxyPort = port,
            )
            if (!downloadResult.ok) {
                throw IllegalStateException(downloadResult.error ?: "Download probe failed.")
            }

            val snapshot =
                TunnelSpeedTestSnapshot(
                    ok = true,
                    status = "passed",
                    latencyUrl = resolvedLatencyUrl,
                    downloadUrl = resolvedDownloadUrl,
                    checkedAt = currentTimestamp(),
                    latencyMs = latencyResult.latencyMs,
                    downloadMbps = downloadResult.downloadMbps,
                    downloadBytes = downloadResult.downloadBytes,
                    downloadDurationMs = downloadResult.downloadDurationMs,
                    warmupDurationMs = resolvedWarmupDurationMs,
                    streamCount = resolvedStreamCount,
                    measuredViaTunnel = true,
                )
            VpnRuntimeStore.update(context, sync = true) { latest ->
                latest.copy(
                    logTail =
                        trimLogTail(
                            latest.logTail +
                                "Speed test passed: latency ${snapshot.latencyMs ?: "?"} ms, download ${snapshot.downloadMbps ?: "?"} Mbps.",
                        ),
                )
            }
            snapshot
        }.getOrElse { error ->
            val failed =
                TunnelSpeedTestSnapshot(
                    ok = false,
                    status = "failed",
                    latencyUrl = resolvedLatencyUrl,
                    downloadUrl = resolvedDownloadUrl,
                    checkedAt = currentTimestamp(),
                    warmupDurationMs = resolvedWarmupDurationMs,
                    streamCount = resolvedStreamCount,
                    measuredViaTunnel = true,
                    error = error.message ?: "Android VPN speed test failed.",
                )
            VpnRuntimeStore.update(context, sync = true) { latest ->
                latest.copy(
                    logTail =
                        trimLogTail(
                            latest.logTail +
                                "Speed test failed: ${failed.error ?: "unknown error"}.",
                        ),
                )
            }
            failed
        }
    }

    fun inspectNetworkLens(
        context: Context,
        originHost: String,
        tunnelHost: String?,
        cellularOnly: Boolean = true,
    ): JSObject {
        val checkedAt = currentTimestamp()
        val connectivity =
            context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                ?: return JSObject().apply {
                    put("available", false)
                    put("checkedAt", checkedAt)
                    put("networkType", "unknown")
                    put("isCellular", false)
                    put("whitelistStatus", "unknown")
                    put("error", "ConnectivityManager is unavailable.")
                }

        val cellularNetwork = findPreferredCellularNetwork(connectivity)
        val fallbackNetwork = resolveUnderlyingDefaultNetwork(connectivity)
        val selectedNetwork = cellularNetwork ?: fallbackNetwork
        val selectedCapabilities = selectedNetwork?.let(connectivity::getNetworkCapabilities)
        val selectedLinkProperties = selectedNetwork?.let(connectivity::getLinkProperties)
        val selectedNetworkType = selectedCapabilities.toNetworkType()
        val selectedIsCellular =
            selectedCapabilities?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true

        val response =
            JSObject().apply {
                put("available", selectedNetwork != null)
                put("checkedAt", checkedAt)
                put("networkType", selectedNetworkType)
                put("isCellular", selectedIsCellular)
                selectedLinkProperties?.interfaceName?.let { put("interfaceName", it) }
                put("whitelistStatus", "unknown")
            }

        if (selectedNetwork == null) {
            response.put("note", "No usable underlying network is available right now.")
            return response
        }

        if (originHost.trim().isNotEmpty()) {
            response.put("origin", endpointDetailsToJsObject(describeNetworkLensEndpoint(selectedNetwork, originHost)))
        }
        if (!tunnelHost.isNullOrBlank()) {
            response.put("tunnel", endpointDetailsToJsObject(describeNetworkLensEndpoint(selectedNetwork, tunnelHost)))
        }

        val whitelistProbeNetwork =
            when {
                cellularOnly -> cellularNetwork
                else -> selectedNetwork
            }
        val whitelistCapabilities = whitelistProbeNetwork?.let(connectivity::getNetworkCapabilities)
        val whitelistIsCellular =
            whitelistCapabilities?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true

        if (whitelistProbeNetwork == null || !whitelistIsCellular) {
            response.put(
                "note",
                "Whitelist detection is paused until a mobile data network is available.",
            )
            return response
        }

        connectivity.getLinkProperties(whitelistProbeNetwork)?.interfaceName?.let {
            response.put("interfaceName", it)
        }
        response.put("networkType", whitelistCapabilities.toNetworkType())
        response.put("isCellular", true)

        val yandexProbe = executeBoundHttpProbe(whitelistProbeNetwork, NETWORK_LENS_YANDEX_URL)
        val googleProbe = executeBoundHttpProbe(whitelistProbeNetwork, NETWORK_LENS_GOOGLE_URL)

        response.put("yandexProbe", networkLensProbeToJsObject(yandexProbe))
        response.put("googleProbe", networkLensProbeToJsObject(googleProbe))
        response.put(
            "whitelistStatus",
            when {
                yandexProbe.ok && !googleProbe.ok -> "active"
                yandexProbe.ok && googleProbe.ok -> "inactive"
                else -> "unknown"
            },
        )
        if (!yandexProbe.ok && !googleProbe.ok) {
            response.put("note", "Both mobile-network probes failed, so the whitelist state is unknown.")
        } else if (!yandexProbe.ok) {
            response.put("note", "The Yandex mobile-network probe failed, so the whitelist state is unknown.")
        }
        return response
    }

    private fun executeBoundHttpProbe(
        network: android.net.Network,
        targetUrl: String,
    ): NetworkLensProbeOutcome {
        val checkedAt = currentTimestamp()
        return runCatching {
            val connection =
                (network.openConnection(URL(targetUrl)) as HttpURLConnection).apply {
                    requestMethod = "GET"
                    connectTimeout = NETWORK_LENS_TIMEOUT_MS
                    readTimeout = NETWORK_LENS_TIMEOUT_MS
                    instanceFollowRedirects = false
                }
            try {
                val code = connection.responseCode
                val ok = code in 200..399
                NetworkLensProbeOutcome(
                    url = targetUrl,
                    ok = ok,
                    httpStatus = code,
                    error = if (ok) null else "HTTP $code",
                    checkedAt = checkedAt,
                )
            } finally {
                connection.disconnect()
            }
        }.getOrElse { error ->
            NetworkLensProbeOutcome(
                url = targetUrl,
                ok = false,
                error = error.message ?: "Bound HTTP probe failed.",
                checkedAt = checkedAt,
            )
        }
    }

    private fun describeNetworkLensEndpoint(
        network: android.net.Network,
        host: String,
    ): NetworkLensEndpointDetails {
        val trimmedHost = host.trim()
        if (trimmedHost.isEmpty()) {
            return NetworkLensEndpointDetails(host = trimmedHost, error = "Host is empty.")
        }
        val ip = resolveIpv4OnNetwork(network, trimmedHost)
            ?: return NetworkLensEndpointDetails(
                host = trimmedHost,
                error = "IPv4 resolution failed on the current network.",
            )
        val geo = lookupGeoForIp(network, ip)
        return NetworkLensEndpointDetails(
            host = trimmedHost,
            ip = ip,
            countryCode = geo?.countryCode,
            country = geo?.country,
        )
    }

    private fun resolveIpv4OnNetwork(
        network: android.net.Network,
        host: String,
    ): String? {
        val trimmedHost = host.trim()
        if (trimmedHost.isEmpty()) {
            return null
        }
        trimmedHost.toIpv4LiteralOrNull()?.let { return it }
        return runCatching {
            network
                .getAllByName(trimmedHost)
                .firstOrNull { it is Inet4Address }
                ?.hostAddress
        }.getOrNull()
    }

    private fun lookupGeoForIp(
        network: android.net.Network,
        ip: String,
    ): CachedGeoLookup? {
        val now = System.currentTimeMillis()
        geoLookupCache[ip]?.takeIf { it.expiresAtMs > now }?.let { return it }

        val fetched =
            runCatching {
                val connection =
                    (network.openConnection(URL("$NETWORK_LENS_GEOLOOKUP_URL_PREFIX$ip")) as HttpURLConnection).apply {
                        requestMethod = "GET"
                        connectTimeout = NETWORK_LENS_TIMEOUT_MS
                        readTimeout = NETWORK_LENS_TIMEOUT_MS
                        instanceFollowRedirects = true
                    }
                try {
                    val code = connection.responseCode
                    if (code !in 200..399) {
                        null
                    } else {
                        val body = connection.inputStream.bufferedReader().use { reader -> reader.readText() }
                        val payload = JSONObject(body)
                        val countryCode =
                            payload.optString("country_code")
                                .ifBlank { payload.optString("countryCode") }
                                .trim()
                                .uppercase(Locale.ROOT)
                                .ifBlank { null }
                        val country = payload.optString("country").trim().ifBlank { null }
                        CachedGeoLookup(
                            countryCode = countryCode,
                            country = country,
                            expiresAtMs = now + NETWORK_LENS_GEOLOOKUP_CACHE_TTL_MS,
                        )
                    }
                } finally {
                    connection.disconnect()
                }
            }.getOrNull()
        if (fetched != null) {
            geoLookupCache[ip] = fetched
        }
        return fetched
    }

    private fun findPreferredCellularNetwork(
        connectivity: ConnectivityManager,
    ): android.net.Network? =
        connectivity.allNetworks
            .mapNotNull { network ->
                val capabilities = connectivity.getNetworkCapabilities(network) ?: return@mapNotNull null
                if (!isUsableUnderlyingNetwork(capabilities) ||
                    !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)
                ) {
                    return@mapNotNull null
                }
                network to (scoreUnderlyingNetwork(capabilities) + 25)
            }.maxByOrNull { (_, score) -> score }
            ?.first

    private fun endpointDetailsToJsObject(details: NetworkLensEndpointDetails): JSObject =
        JSObject().apply {
            put("host", details.host)
            details.ip?.let { put("ip", it) }
            details.countryCode?.let { put("countryCode", it) }
            details.country?.let { put("country", it) }
            details.error?.let { put("error", it) }
        }

    private fun networkLensProbeToJsObject(probe: NetworkLensProbeOutcome): JSObject =
        JSObject().apply {
            put("url", probe.url)
            put("ok", probe.ok)
            probe.httpStatus?.let { put("httpStatus", it) }
            probe.error?.let { put("error", it) }
            put("checkedAt", probe.checkedAt)
        }

    private fun NetworkCapabilities?.toNetworkType(): String =
        when {
            this == null -> "unknown"
            hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            else -> "other"
        }

    private fun String.toIpv4LiteralOrNull(): String? {
        val parts = trim().split('.')
        if (parts.size != 4) {
            return null
        }
        return if (parts.all { part ->
                val octet = part.toIntOrNull()
                part.isNotEmpty() &&
                    part.all(Char::isDigit) &&
                    octet != null &&
                    octet in 0..255
            }
        ) {
            trim()
        } else {
            null
        }
    }

    private fun executeHttpProbeWithLocalSocksRetries(
        targetUrl: String,
        proxy: Proxy,
        method: String,
        proxyHost: String,
        proxyPort: Int,
    ): TunnelTestSnapshot {
        var latest: TunnelTestSnapshot? = null
        repeat(3) { attempt ->
            val probe =
                runCatching {
                    executeHttpProbe(targetUrl, proxy, method)
                }.getOrElse { error ->
                    TunnelTestSnapshot(
                        ok = false,
                        status = "failed",
                        url = targetUrl,
                        error = error.message ?: "Android SOCKS probe failed.",
                        checkedAt = currentTimestamp(),
                    )
                }
            latest = probe
            if (probe.ok) {
                return probe
            }
            val retryable = isLocalSocksConnectError(probe.error, proxyHost, proxyPort)
            if (!retryable || attempt == 2) {
                return probe
            }
            Log.i(
                "VpnRuntimeService",
                "Retrying connectivity probe for $targetUrl after local SOCKS connect error on $proxyHost:$proxyPort (attempt ${attempt + 2}/3)",
            )
            Thread.sleep(750L * (attempt + 1))
        }
        return latest
            ?: TunnelTestSnapshot(
                ok = false,
                status = "failed",
                url = targetUrl,
                error = "Android SOCKS probe did not produce a result.",
                checkedAt = currentTimestamp(),
            )
    }

    private fun executeTimedHttpProbeWithLocalSocksRetries(
        targetUrl: String,
        proxy: Proxy,
        method: String,
        proxyHost: String,
        proxyPort: Int,
    ): TunnelSpeedTestSnapshot {
        var latest: TunnelSpeedTestSnapshot? = null
        repeat(3) { attempt ->
            val probe =
                runCatching {
                    executeTimedHttpProbe(targetUrl, proxy, method)
                }.getOrElse { error ->
                    TunnelSpeedTestSnapshot(
                        ok = false,
                        status = "failed",
                        latencyUrl = targetUrl,
                        checkedAt = currentTimestamp(),
                        error = error.message ?: "Android timed probe failed.",
                    )
                }
            latest = probe
            if (probe.ok) {
                return probe
            }
            val retryable = isLocalSocksConnectError(probe.error, proxyHost, proxyPort)
            if (!retryable || attempt == 2) {
                return probe
            }
            Thread.sleep(750L * (attempt + 1))
        }
        return latest
            ?: TunnelSpeedTestSnapshot(
                ok = false,
                status = "failed",
                latencyUrl = targetUrl,
                checkedAt = currentTimestamp(),
                error = "Android timed probe did not produce a result.",
            )
    }

    private fun executeLatencyProbeWithLocalSocksRetries(
        targetUrl: String,
        proxy: Proxy,
        method: String,
        proxyHost: String,
        proxyPort: Int,
    ): TunnelSpeedTestSnapshot {
        val latencySamples = mutableListOf<Int>()
        var latestFailure: TunnelSpeedTestSnapshot? = null

        repeat(DEFAULT_SPEEDTEST_LATENCY_SAMPLE_COUNT) { sampleIndex ->
            val probe =
                executeTimedHttpProbeWithLocalSocksRetries(
                    targetUrl = targetUrl,
                    proxy = proxy,
                    method = method,
                    proxyHost = proxyHost,
                    proxyPort = proxyPort,
                )
            if (!probe.ok) {
                latestFailure = probe
                return probe
            }
            probe.latencyMs?.let { latency ->
                if (sampleIndex > 0) {
                    latencySamples.add(latency)
                }
            }
        }

        val bestLatencyMs = latencySamples.minOrNull()
        return if (bestLatencyMs != null) {
            TunnelSpeedTestSnapshot(
                ok = true,
                status = "passed",
                latencyUrl = targetUrl,
                checkedAt = currentTimestamp(),
                latencyMs = bestLatencyMs,
                measuredViaTunnel = true,
            )
        } else {
            latestFailure
                ?: TunnelSpeedTestSnapshot(
                    ok = false,
                    status = "failed",
                    latencyUrl = targetUrl,
                    checkedAt = currentTimestamp(),
                    measuredViaTunnel = true,
                    error = "Android latency probe did not produce a usable sample.",
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

    private fun executeTimedHttpProbe(
        targetUrl: String,
        proxy: Proxy,
        method: String,
    ): TunnelSpeedTestSnapshot {
        val startedAt = System.nanoTime()
        val connection = (URL(targetUrl).openConnection(proxy) as HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = 8_000
            readTimeout = 12_000
            instanceFollowRedirects = false
        }
        try {
            val code = connection.responseCode
            val latencyMs = ((System.nanoTime() - startedAt) / 1_000_000L).toInt().coerceAtLeast(1)
            return if (code in 200..399) {
                TunnelSpeedTestSnapshot(
                    ok = true,
                    status = "passed",
                    latencyUrl = targetUrl,
                    checkedAt = currentTimestamp(),
                    latencyMs = latencyMs,
                )
            } else {
                TunnelSpeedTestSnapshot(
                    ok = false,
                    status = "failed",
                    latencyUrl = targetUrl,
                    checkedAt = currentTimestamp(),
                    latencyMs = latencyMs,
                    error = "Timed probe returned HTTP $code",
                )
            }
        } finally {
            connection.disconnect()
        }
    }

    private fun executeDownloadProbeWithLocalSocksRetries(
        targetUrl: String,
        requestedDownloadBytes: Long,
        warmupDurationMs: Long,
        measureDurationMs: Long,
        streamCount: Int,
        proxy: Proxy,
        proxyHost: String,
        proxyPort: Int,
    ): TunnelSpeedTestSnapshot {
        var latest: TunnelSpeedTestSnapshot? = null
        repeat(3) { attempt ->
            val probe =
                runCatching {
                    executeDownloadProbe(
                        targetUrl = targetUrl,
                        requestedDownloadBytes = requestedDownloadBytes,
                        warmupDurationMs = warmupDurationMs,
                        measureDurationMs = measureDurationMs,
                        streamCount = streamCount,
                        proxy = proxy,
                    )
                }.getOrElse { error ->
                    TunnelSpeedTestSnapshot(
                        ok = false,
                        status = "failed",
                        downloadUrl = targetUrl,
                        checkedAt = currentTimestamp(),
                        warmupDurationMs = warmupDurationMs,
                        streamCount = streamCount,
                        measuredViaTunnel = true,
                        error = error.message ?: "Android download probe failed.",
                    )
                }
            latest = probe
            if (probe.ok) {
                return probe
            }
            val retryable = isLocalSocksConnectError(probe.error, proxyHost, proxyPort)
            if (!retryable || attempt == 2) {
                return probe
            }
            Thread.sleep(750L * (attempt + 1))
        }
        return latest
            ?: TunnelSpeedTestSnapshot(
                ok = false,
                status = "failed",
                downloadUrl = targetUrl,
                checkedAt = currentTimestamp(),
                warmupDurationMs = warmupDurationMs,
                streamCount = streamCount,
                measuredViaTunnel = true,
                error = "Android download probe did not produce a result.",
            )
    }

    private fun executeDownloadProbe(
        targetUrl: String,
        requestedDownloadBytes: Long,
        warmupDurationMs: Long,
        measureDurationMs: Long,
        streamCount: Int,
        proxy: Proxy,
    ): TunnelSpeedTestSnapshot {
        val measuredBytes = AtomicLong(0L)
        val streamErrors = ConcurrentLinkedQueue<String>()
        val startAtNs = System.nanoTime() + 200_000_000L
        val measureStartAtNs = startAtNs + (warmupDurationMs * 1_000_000L)
        val measureEndAtNs = measureStartAtNs + (measureDurationMs * 1_000_000L)
        val workers =
            (0 until streamCount).map { streamIndex ->
                thread(name = "odin-speedtest-$streamIndex", isDaemon = true) {
                    val now = System.nanoTime()
                    if (startAtNs > now) {
                        Thread.sleep(((startAtNs - now) / 1_000_000L).coerceAtLeast(0L))
                    }
                    var requestRound = 0
                    while (System.nanoTime() < measureEndAtNs) {
                        val streamUrl =
                            appendSpeedTestQuery(
                                baseUrl = targetUrl,
                                requestedDownloadBytes = requestedDownloadBytes,
                                streamIndex = streamIndex,
                                requestRound = requestRound,
                            )
                        requestRound += 1
                        val connection =
                            (URL(streamUrl).openConnection(proxy) as HttpURLConnection).apply {
                                requestMethod = "GET"
                                connectTimeout = 8_000
                                readTimeout = (warmupDurationMs + measureDurationMs + 5_000L).toInt()
                                instanceFollowRedirects = true
                                useCaches = false
                                setRequestProperty("Cache-Control", "no-store")
                                setRequestProperty("Pragma", "no-cache")
                                setRequestProperty("Accept-Encoding", "identity")
                                setRequestProperty("Connection", "keep-alive")
                            }

                        try {
                            val code = connection.responseCode
                            if (code !in 200..399) {
                                streamErrors.add("Stream ${streamIndex + 1} returned HTTP $code")
                                return@thread
                            }

                            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                            connection.inputStream.use { input ->
                                while (System.nanoTime() < measureEndAtNs) {
                                    val read = input.read(buffer)
                                    if (read <= 0) {
                                        break
                                    }
                                    if (System.nanoTime() >= measureStartAtNs) {
                                        measuredBytes.addAndGet(read.toLong())
                                    }
                                }
                            }
                        } catch (error: Exception) {
                            streamErrors.add(
                                error.message ?: "Stream ${streamIndex + 1} failed during download.",
                            )
                            return@thread
                        } finally {
                            connection.disconnect()
                        }
                    }
                }
            }

        workers.forEach { worker -> worker.join((warmupDurationMs + measureDurationMs + 8_000L).coerceAtLeast(5_000L)) }

        val totalBytes = measuredBytes.get().coerceAtLeast(0L)
        val mbps = (((totalBytes * 8.0) / 1_000_000.0) / (measureDurationMs / 1000.0))
        val primaryError = streamErrors.peek()
        return TunnelSpeedTestSnapshot(
            ok = totalBytes > 0,
            status = if (totalBytes > 0) "passed" else "failed",
            downloadUrl = targetUrl,
            checkedAt = currentTimestamp(),
            downloadMbps = if (totalBytes > 0) String.format(Locale.US, "%.1f", mbps).toDouble() else null,
            downloadBytes = totalBytes,
            downloadDurationMs = measureDurationMs,
            warmupDurationMs = warmupDurationMs,
            streamCount = streamCount,
            measuredViaTunnel = true,
            error =
                if (totalBytes > 0) {
                    null
                } else {
                    primaryError ?: "Download probe returned no bytes."
                },
        )
    }

    private fun appendSpeedTestQuery(
        baseUrl: String,
        requestedDownloadBytes: Long,
        streamIndex: Int,
        requestRound: Int,
    ): String {
        val separator = if (baseUrl.contains("?")) "&" else "?"
        return "$baseUrl${separator}bytes=$requestedDownloadBytes&stream=$streamIndex&round=$requestRound&cache_bust=${System.currentTimeMillis()}_${streamIndex}_$requestRound"
    }

    private fun isCertificateValidationError(message: String): Boolean {
        val lower = message.lowercase(Locale.ROOT)
        return lower.contains("trust anchor") ||
            lower.contains("certpathvalidatorexception") ||
            lower.contains("sslhandshakeexception") ||
            lower.contains("certificate")
    }

    private fun isLocalSocksConnectError(
        message: String?,
        proxyHost: String,
        proxyPort: Int,
    ): Boolean {
        val text = message?.lowercase(Locale.ROOT) ?: return false
        val normalizedProxyHost = proxyHost.lowercase(Locale.ROOT)
        return (text.contains("failed to connect to /$normalizedProxyHost") ||
            text.contains("failed to connect to $normalizedProxyHost") ||
            text.contains("connect timed out")) &&
            text.contains("port $proxyPort")
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

    fun startNativeProcess(
        prepared: PreparedRuntime,
        onLogLine: (String) -> Unit,
    ): Process {
        val binary = prepared.nativeBinaryPath
            ?: throw IllegalArgumentException("Missing native Android binary")
        val label = prepared.nativeProcessLabel?.takeIf { it.isNotBlank() } ?: "native-runtime"
        val binaryFile = File(binary)
        val command = mutableListOf(binary).apply {
            addAll(prepared.nativeArgs)
        }
        onLogLine(
            "Using $label binary: path=$binary exists=${binaryFile.exists()} executable=${binaryFile.canExecute()} size=${binaryFile.length()}",
        )
        onLogLine("Launching $label: ${command.joinToString(" ")}")
        val process = ProcessBuilder(command)
            .redirectErrorStream(true)
            .start()
        thread(name = "${label}-log-reader", isDaemon = true) {
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
                    onLogLine("$label log reader stopped unexpectedly: ${error.message ?: error::class.java.simpleName}")
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

    private fun readHysteria2Settings(
        profile: JSObject,
        fallbackServerHost: String,
    ): Hysteria2Settings {
        val fallback =
            profile.optJSONObject("stagedFallbacks")?.optJSONObject("hysteria2")
                ?: throw IllegalArgumentException("The access profile does not contain Hysteria 2 settings")
        if (fallback.optString("status", "").trim() != "ready") {
            throw IllegalArgumentException("Hysteria 2 is not ready in this access profile")
        }
        val serverHost =
            fallback.optString("connectHost", "").trim().ifBlank { fallbackServerHost }
        val serverPort = fallback.optInt("connectPort", 0)
        val password = fallback.optString("password", "").trim()
        val serverName = fallback.optString("serverName", "").trim()
        val certificatePin = fallback.optString("certificatePublicKeySha256", "").trim()
        val obfsType = fallback.optString("obfsType", "").trim()
        val obfsPassword = fallback.optString("obfsPassword", "").trim()
        if (
            serverHost.isBlank() ||
                serverPort <= 0 ||
                password.isBlank() ||
                serverName.isBlank() ||
                certificatePin.isBlank() ||
                obfsType != "salamander" ||
                obfsPassword.isBlank()
        ) {
            throw IllegalArgumentException("The Hysteria 2 access profile is incomplete")
        }
        return Hysteria2Settings(
            serverHost = serverHost,
            serverPort = serverPort,
            password = password,
            serverName = serverName,
            certificatePublicKeySha256 = certificatePin,
            obfsType = obfsType,
            obfsPassword = obfsPassword,
        )
    }

    private fun readRealityVpsLabOwnerBootstrapSettings(
        profile: JSObject,
        fallbackServerHost: String,
    ): RealitySettings? {
        val bootstrap =
            profile.optJSONObject("androidRuntime")
                ?.optJSONObject("realityVpsLab")
                ?.optJSONObject("ownerRealityBootstrap")
                ?: profile.optJSONObject("runtimeOptions")
                    ?.optJSONObject("realityVpsLab")
                    ?.optJSONObject("ownerRealityBootstrap")
                ?: return null
        val serverHost =
            bootstrap.optString("serverHost").trim().takeUnless { it.isBlank() }
                ?: fallbackServerHost.trim().takeUnless { it.isBlank() }
                ?: return null
        val serverPort = bootstrap.optInt("port", 0)
        val uuid = bootstrap.optString("uuid", "").trim()
        val flow = bootstrap.optString("flow", "xtls-rprx-vision").trim().ifBlank { "xtls-rprx-vision" }
        val serverName = bootstrap.optString("serverName", "").trim()
        val publicKey = bootstrap.optString("publicKey", "").trim()
        val shortId = bootstrap.optString("shortId", "").trim()
        if (serverPort <= 0 || uuid.isBlank() || serverName.isBlank() || publicKey.isBlank() || shortId.isBlank()) {
            return null
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

    private fun readRealityVpsLabRelaySettings(
        profile: JSObject,
        serverHost: String,
        fallback: RealitySettings,
        options: RealityVpsLabRuntimeOptions,
    ): RealitySettings {
        val stagedFallbacks = profile.optJSONObject("stagedFallbacks")
        val edge =
            stagedFallbacks?.optJSONObject("realityYandexEdgeProxy")
                ?: stagedFallbacks?.optJSONObject("realityYandexEdge")
                ?: return fallback
        val connectHost = edge.optString("connectHost", "").trim()
        val connectPort = edge.optInt("connectPort", 0)
        val originPort = edge.optInt("originPort", 0)
        if (
            connectHost.isBlank() ||
                connectPort <= 0 ||
                originPort <= 0 ||
                !connectHost.equals(options.connectHost, ignoreCase = true) ||
                connectPort != options.connectPort ||
                originPort != options.serverPort
        ) {
            return fallback
        }

        val uuid = edge.optString("uuid", "").trim()
        val flow = edge.optString("flow", fallback.flow).trim().ifBlank { fallback.flow }
        val serverName = edge.optString("serverName", "").trim()
        val publicKey = edge.optString("publicKey", "").trim()
        val shortId = edge.optString("shortId", "").trim()
        if (uuid.isBlank() || serverName.isBlank() || publicKey.isBlank() || shortId.isBlank()) {
            return fallback
        }

        return RealitySettings(
            serverHost = serverHost,
            serverPort = originPort,
            uuid = uuid,
            flow = flow,
            serverName = serverName,
            publicKey = publicKey,
            shortId = shortId,
        )
    }

    private fun readCdnAntiWhitelistRealitySettings(
        profile: JSObject,
        fallback: RealitySettings,
        options: CdnAntiWhitelistRuntimeOptions,
    ): RealitySettings {
        val stagedFallbacks = profile.optJSONObject("stagedFallbacks")
        val edge =
            stagedFallbacks?.optJSONObject("realityYandexEdgeProxy")
                ?: stagedFallbacks?.optJSONObject("realityYandexEdge")
                ?: return fallback
        val connectHost = edge.optString("connectHost", "").trim()
        val connectPort = edge.optInt("connectPort", 0)
        if (
            connectHost.isBlank() ||
                connectPort <= 0 ||
                !connectHost.equals(options.connectHost, ignoreCase = true) ||
                connectPort != options.connectPort
        ) {
            return fallback
        }

        val uuid = edge.optString("uuid", "").trim()
        if (uuid.isBlank()) {
            return fallback
        }

        return fallback.copy(
            serverHost = options.connectHost,
            serverPort = options.connectPort,
            uuid = uuid,
            flow = edge.optString("flow", fallback.flow).trim().ifBlank { fallback.flow },
            serverName = edge.optString("serverName", "").trim().ifBlank { fallback.serverName },
            publicKey = edge.optString("publicKey", "").trim().ifBlank { fallback.publicKey },
            shortId = edge.optString("shortId", "").trim().ifBlank { fallback.shortId },
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

    private fun prepareCdnAntiWhitelistRuntime(
        runtimeDir: File,
        args: JSObject,
        profile: JSObject,
        serverHost: String,
        socksPort: Int,
        socksAddress: String,
    ): PreparedRuntime {
        val options = readCdnAntiWhitelistRuntimeOptions(args, profile, serverHost)
        val reality =
            readCdnAntiWhitelistRealitySettings(
                profile = profile,
                fallback = readRealitySettings(profile, serverHost),
                options = options,
            )
        val scaffoldPath = File(runtimeDir, "cdn-anti-whitelist-scaffold.json")
        scaffoldPath.writeText(buildCdnAntiWhitelistScaffoldDocument(serverHost, reality, options))
        if (options.activationState == ACTIVATION_STATE_ACTIVE) {
            return PreparedRuntime(
                configContent = buildCdnAntiWhitelistConfig(socksPort, reality, options),
                configPath = File(runtimeDir, "active-cdn-anti-whitelist.json").path,
                socksAddress = socksAddress,
                runtimeFamily = RUNTIME_FAMILY_CDN_ANTI_WHITELIST,
                activationState = options.activationState,
                frontHost = options.frontHost,
                frontConnectHost = options.connectHost,
                frontConnectPort = options.connectPort,
                frontPath = options.frontPath,
                frontProvider = options.provider,
                frontTag = options.frontTag,
                selectedSniHint = options.tlsServerName,
                whitelistHintTag = options.frontTag,
                cdnRoutingDnsQueryStrategy = options.routingPolicy.dnsQueryStrategy,
                cdnRoutingDomainStrategy = options.routingPolicy.domainStrategy,
                cdnRoutingDomainMatcher = options.routingPolicy.domainMatcher,
                cdnRoutingDirectRuleCount = options.routingPolicy.directRuleCount,
                cdnRoutingBlockRuleCount = options.routingPolicy.blockRuleCount,
                cdnRoutingBlockSelectedFrontHost = options.routingPolicy.blockSelectedFrontHost,
                cdnDnsLocalResolverEnabled = false,
                configMode = options.mode,
                activeFeatures = options.featureLabels(),
                profileHash = args.getString("profileHash", null),
            )
        }
        throw IllegalArgumentException(
            "Android CDN / anti-whitelist mode is scaffolded only on this branch. Review ${scaffoldPath.path} and keep stable VLESS + REALITY as the active path for now.",
        )
    }

    private fun prepareCdnAntiWhitelistXrayNativeRuntime(
        context: Context,
        runtimeDir: File,
        args: JSObject,
        profile: JSObject,
        serverHost: String,
        socksPort: Int,
        socksAddress: String,
    ): PreparedRuntime {
        val options = readCdnAntiWhitelistRuntimeOptions(args, profile, serverHost)
        val reality =
            readCdnAntiWhitelistRealitySettings(
                profile = profile,
                fallback = readRealitySettings(profile, serverHost),
                options = options,
            )
        if (options.activationState != ACTIVATION_STATE_ACTIVE) {
            throw IllegalArgumentException("Android CDN Xray-native runtime requires an active owner-lab CDN configuration")
        }
        val xrayBinary = File(context.applicationInfo.nativeLibraryDir, "libxray.so")
        if (!xrayBinary.exists()) {
            throw IllegalArgumentException("Missing bundled libxray.so in Android runtime")
        }
        val sidecarSocksPort = selectTcpPort(DEFAULT_NATIVE_SIDEcar_SOCKS_PORT)
        val sidecarSocksAddress = "127.0.0.1:$sidecarSocksPort"
        val configPath = File(runtimeDir, "active-cdn-anti-whitelist-xray-native-bridge.json").path
        val sidecarConfigPath = File(runtimeDir, "active-cdn-anti-whitelist-xray-native.json").path
        return PreparedRuntime(
            configContent = buildCdnAntiWhitelistLocalSocksBridgeConfig(socksPort, sidecarSocksPort, options),
            configPath = configPath,
            socksAddress = socksAddress,
            nativeBinaryPath = xrayBinary.path,
            nativeArgs = listOf("run", "-config", sidecarConfigPath),
            nativeProcessLabel = "xray-native",
            skipVpnTunnel = false,
            runtimeFamily = RUNTIME_FAMILY_CDN_ANTI_WHITELIST,
            activationState = options.activationState,
            frontHost = options.frontHost,
            frontConnectHost = options.connectHost,
            frontConnectPort = options.connectPort,
            frontPath = options.frontPath,
            frontProvider = options.provider,
            frontTag = options.frontTag,
            selectedSniHint = options.tlsServerName,
            whitelistHintTag = options.frontTag,
            cdnRoutingDnsQueryStrategy = options.routingPolicy.dnsQueryStrategy,
            cdnRoutingDomainStrategy = options.routingPolicy.domainStrategy,
            cdnRoutingDomainMatcher = options.routingPolicy.domainMatcher,
            cdnRoutingDirectRuleCount = options.routingPolicy.directRuleCount,
            cdnRoutingBlockRuleCount = options.routingPolicy.blockRuleCount,
            cdnRoutingBlockSelectedFrontHost = options.routingPolicy.blockSelectedFrontHost,
            cdnDnsLocalResolverEnabled = false,
            configMode = options.mode,
            activeFeatures =
                options.featureLabels() +
                    "engine:$ENGINE_XRAY_NATIVE" +
                    "bridge:libbox-socks" +
                    "sidecar-socks:$sidecarSocksAddress",
            profileHash = args.getString("profileHash", null),
        )
            .also {
                File(sidecarConfigPath).writeText(
                    buildXrayNativeCdnAntiWhitelistConfig(sidecarSocksPort, reality, options),
                )
            }
    }

    private fun prepareRealityWhitelistAssistedRuntime(
        runtimeDir: File,
        args: JSObject,
        profile: JSObject,
        serverHost: String,
        socksPort: Int,
        socksAddress: String,
    ): PreparedRuntime {
        val reality = readRealitySettings(profile, serverHost)
        val baseArgs = JSObject(args.toString()).apply { remove("configMode") }
        val baseOptions = readRealityRuntimeOptions(baseArgs, profile)
        val options = readRealityWhitelistHintRuntimeOptions(args, profile, reality.serverName, baseOptions)
        val scaffoldPath = File(runtimeDir, "reality-whitelist-assisted-scaffold.json")
        scaffoldPath.writeText(buildRealityWhitelistAssistedScaffoldDocument(serverHost, reality, baseOptions, options))
        if (options.activationState == ACTIVATION_STATE_ACTIVE) {
            return PreparedRuntime(
                configContent = buildRealityConfig(socksPort, reality.copy(serverName = options.selectedSniHint), baseOptions),
                configPath = File(runtimeDir, "active-vless-reality.json").path,
                socksAddress = socksAddress,
                runtimeFamily = RUNTIME_FAMILY_REALITY_WHITELIST_ASSISTED,
                activationState = options.activationState,
                selectedSniHint = options.selectedSniHint,
                selectedCidrHint = options.selectedCidrHint,
                whitelistHintSource = options.whitelistHintSource,
                whitelistHintTag = options.whitelistHintTag,
                configMode = options.mode,
                activeFeatures = buildRealityWhitelistAssistedFeatureLabels(baseOptions, options),
                profileHash = args.getString("profileHash", null),
                networkReloadOnChange = baseOptions.networkReloadOnChange,
                networkReloadDebounceMs = baseOptions.networkReloadDebounceMs,
            )
        }
        throw IllegalArgumentException(
            "Android REALITY whitelist-assisted mode is scaffolded only on this branch. Review ${scaffoldPath.path} and keep stable VLESS + REALITY as the active path for now.",
        )
    }

    private fun prepareRealityVpsLabRuntime(
        runtimeDir: File,
        args: JSObject,
        profile: JSObject,
        serverHost: String,
        socksPort: Int,
        socksAddress: String,
    ): PreparedRuntime {
        val directReality = readRealitySettings(profile, serverHost)
        val baseArgs = JSObject(args.toString()).apply { remove("configMode") }
        val baseOptions = readRealityRuntimeOptions(baseArgs, profile)
        val options = readRealityVpsLabRuntimeOptions(args, profile, directReality)
        val relayReality = readRealityVpsLabRelaySettings(profile, serverHost, directReality, options)
        val ownerReality = readRealityVpsLabOwnerBootstrapSettings(profile, serverHost) ?: relayReality
        val scaffoldPath = File(runtimeDir, "reality-vps-lab-scaffold.json")
        scaffoldPath.writeText(buildRealityVpsLabScaffoldDocument(serverHost, ownerReality, baseOptions, options))
        if (options.activationState == ACTIVATION_STATE_ACTIVE) {
            return PreparedRuntime(
                configContent = buildRealityVpsLabConfig(socksPort, relayReality, ownerReality, baseOptions, options),
                configPath = File(runtimeDir, "active-vless-reality-vps-lab.json").path,
                socksAddress = socksAddress,
                runtimeFamily = RUNTIME_FAMILY_REALITY_VPS_LAB,
                activationState = options.activationState,
                frontHost = options.serverName,
                frontConnectHost = options.connectHost,
                frontConnectPort = options.connectPort,
                frontTag = options.tag,
                selectedSniHint = options.serverName,
                whitelistHintSource = options.source,
                whitelistHintTag = options.tag,
                configMode = options.mode,
                activeFeatures = buildRealityVpsLabFeatureLabels(baseOptions, options),
                profileHash = args.getString("profileHash", null),
                networkReloadOnChange = baseOptions.networkReloadOnChange,
                networkReloadDebounceMs = baseOptions.networkReloadDebounceMs,
            )
        }
        throw IllegalArgumentException(
            "Android REALITY VPS lab mode is scaffolded only on this branch. Review ${scaffoldPath.path} and keep stable VLESS + REALITY as the active path for now.",
        )
    }

    private fun buildRealityVpsLabConfig(
        socksPort: Int,
        relayReality: RealitySettings,
        ownerReality: RealitySettings,
        options: RealityRuntimeOptions,
        vpsOptions: RealityVpsLabRuntimeOptions,
    ): String {
        val relayTls =
            JSONObject().put("enabled", true)
                .put("server_name", vpsOptions.serverName)
                .put(
                    "utls",
                    JSONObject()
                        .put("enabled", true)
                        .put("fingerprint", vpsOptions.fingerprint),
                ).put(
                    "reality",
                    JSONObject()
                        .put("enabled", true)
                        .put("public_key", relayReality.publicKey)
                        .put("short_id", relayReality.shortId),
                )
        if (options.tlsFragment) {
            relayTls.put("fragment", true)
        }
        if (options.recordFragment) {
            relayTls.put("record_fragment", true)
        }

        val routeRules = JSONArray()
            .put(JSONObject().put("action", "sniff"))
            .put(JSONObject().put("protocol", "dns").put("action", "hijack-dns"))
            .put(
                JSONObject()
                    .put("type", "logical")
                    .put("mode", "or")
                    .put(
                        "rules",
                        JSONArray()
                            .put(JSONObject().put("network", "udp").put("port", 53))
                            .put(JSONObject().put("network", "tcp").put("port", 53)),
                    ).put("action", "hijack-dns"),
            )
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
        appendLocalBypassRouteRules(routeRules, options.localBypassDomainKeywords, options.localBypassDomains)

        val relayOutbound =
            JSONObject()
                .put("type", "vless")
                .put("tag", if (vpsOptions.ownerRealityEgress) "relay-out" else "main-out")
                .put("server", vpsOptions.connectHost)
                .put("server_port", vpsOptions.connectPort)
                .put("uuid", relayReality.uuid)
                .put("network", "tcp")
                .put("tls", relayTls)
        if (vpsOptions.transport == REALITY_VPS_LAB_TRANSPORT_GRPC) {
            relayOutbound.put(
                "transport",
                JSONObject()
                    .put("type", "grpc")
                    .apply {
                        vpsOptions.grpcServiceName?.takeIf { it.isNotBlank() }?.let { put("service_name", it) }
                        vpsOptions.grpcAuthority?.takeIf { it.isNotBlank() }?.let { put("authority", it) }
                    },
            )
        }

        vpsOptions.flow?.takeIf { it.isNotBlank() }?.let { relayOutbound.put("flow", it) }

        val outbounds = JSONArray().put(relayOutbound)
        if (vpsOptions.ownerRealityEgress) {
            val ownerTls =
                JSONObject().put("enabled", true)
                    .put("server_name", ownerReality.serverName)
                    .put(
                        "utls",
                        JSONObject()
                            .put("enabled", true)
                            .put("fingerprint", "chrome"),
                    ).put(
                        "reality",
                        JSONObject()
                            .put("enabled", true)
                            .put("public_key", ownerReality.publicKey)
                            .put("short_id", ownerReality.shortId),
                    )
            if (options.tlsFragment) {
                ownerTls.put("fragment", true)
            }
            if (options.recordFragment) {
                ownerTls.put("record_fragment", true)
            }
            outbounds.put(
                JSONObject()
                    .put("type", "vless")
                    .put("tag", "main-out")
                    .put("server", ownerReality.serverHost)
                    .put("server_port", ownerReality.serverPort)
                    .put("uuid", ownerReality.uuid)
                    .put("flow", ownerReality.flow)
                    .put("packet_encoding", "xudp")
                    .put("tls", ownerTls)
                    .put(
                        "multiplex",
                        JSONObject().put("enabled", !options.disableMultiplex),
                    ).put("detour", "relay-out"),
            )
        }

        val config =
            JSONObject()
                .put("log", JSONObject().put("level", "warn"))
                .put(
                    "dns",
                    JSONObject()
                        .put("servers", JSONArray().put(buildRealityDnsServer(options, "main-out")))
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
                    outbounds.put(
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

    fun normalizeRuntimeArgs(args: JSObject): JSObject {
        val normalized =
            runCatching { JSObject(args.toString()) }
                .getOrElse { args }
        val protocol = normalized.getString("protocol", "vless-reality")?.trim().orEmpty()
        if (protocol == "direct-wireguard") {
            normalized.put("runtimeFamily", RUNTIME_FAMILY_VK_RELAY)
            normalized.put("activationState", ACTIVATION_STATE_ACTIVE)
            return normalized
        }
        if (protocol == "hysteria2") {
            normalized.put("runtimeFamily", RUNTIME_FAMILY_HYSTERIA2)
            normalized.put("activationState", ACTIVATION_STATE_ACTIVE)
            normalized.put("configMode", "beta")
            return normalized
        }
        if (protocol != "vless-reality") {
            return normalized
        }

        val rawProfile = normalized.getString("profileJson", "{}") ?: "{}"
        val profile =
            runCatching { JSObject(rawProfile) }
                .getOrElse { return normalized }
        val inferredRuntimeFamily =
            when {
                isCdnAntiWhitelistEnabled(profile) -> RUNTIME_FAMILY_CDN_ANTI_WHITELIST
                isRealityVpsLabEnabled(profile) -> RUNTIME_FAMILY_REALITY_VPS_LAB
                isRealityWhitelistHintsEnabled(profile) -> RUNTIME_FAMILY_REALITY_WHITELIST_ASSISTED
                else -> RUNTIME_FAMILY_DIRECT_REALITY
            }
        val requestedRuntimeFamily =
            normalized.getString("runtimeFamily", null)
                ?.trim()
                ?.takeUnless { it.isEmpty() }
                ?.takeIf {
                    it == RUNTIME_FAMILY_DIRECT_REALITY ||
                        it == RUNTIME_FAMILY_CDN_ANTI_WHITELIST ||
                        it == RUNTIME_FAMILY_REALITY_VPS_LAB ||
                        it == RUNTIME_FAMILY_REALITY_WHITELIST_ASSISTED ||
                        it == RUNTIME_FAMILY_VK_RELAY
                }
        var runtimeFamily = requestedRuntimeFamily ?: inferredRuntimeFamily
        if (
            runtimeFamily == RUNTIME_FAMILY_REALITY_VPS_LAB &&
            isCdnAntiWhitelistEnabled(profile) &&
            !isRealityVpsLabEnabled(profile)
        ) {
            runtimeFamily = RUNTIME_FAMILY_CDN_ANTI_WHITELIST
        }
        normalized.put("runtimeFamily", runtimeFamily)
        if (runtimeFamily == RUNTIME_FAMILY_CDN_ANTI_WHITELIST) {
            clearRealityDerivedArgs(normalized)
            clearRealityWhitelistDerivedArgs(normalized)
            val options = readCdnAntiWhitelistRuntimeOptions(normalized, profile, normalized.getString("serverHost", "")?.trim().orEmpty())
            val engine =
                normalizeRuntimeEngine(
                    profile.optJSONObject("androidRuntime")
                        ?.optJSONObject("cdnAntiWhitelist")
                        ?.optString("engine")
                        .takeUnless { it.isNullOrBlank() }
                        ?: profile.optJSONObject("runtimeOptions")
                            ?.optJSONObject("cdnAntiWhitelist")
                            ?.optString("engine")
                            .takeUnless { it.isNullOrBlank() }
                        ?: profile.optJSONObject("androidCdnAntiWhitelist")
                            ?.optString("engine")
                            .takeUnless { it.isNullOrBlank() }
                        ?: normalized.getString("engine", null)
                            ?.trim()
                            .takeUnless { it.isNullOrBlank() },
                )
            normalized.put("engine", engine)
            normalized.put("activationState", options.activationState)
            normalized.put("configMode", options.mode)
            normalized.put("bootRestoreEnabled", false)
            normalized.put("frontHost", options.frontHost)
            normalized.put("frontConnectHost", options.connectHost)
            normalized.put("frontConnectPort", options.connectPort)
            normalized.put("frontPath", options.frontPath)
            normalized.put("frontProvider", options.provider)
            normalized.put("frontTag", options.frontTag)
            normalized.put("cdnProvider", options.provider)
            normalized.put("cdnTransport", options.transport)
            options.xhttpMode?.let { normalized.put("cdnXhttpMode", it) }
            normalized.put("cdnFrontHost", options.frontHost)
            normalized.put("cdnFrontPort", options.frontPort)
            normalized.put("cdnFrontPath", options.frontPath)
            normalized.put("cdnConnectHost", options.connectHost)
            normalized.put("cdnConnectPort", options.connectPort)
            normalized.put("cdnTlsServerName", options.tlsServerName)
            normalized.put("cdnTlsAllowInsecure", options.tlsAllowInsecure)
            if (options.tlsAlpn.isNotEmpty()) {
                normalized.put("cdnTlsAlpn", JSONArray().apply { options.tlsAlpn.forEach(::put) })
            }
            options.xmuxMaxConcurrency?.let { normalized.put("cdnXmuxMaxConcurrency", it) }
            options.xmuxHMaxRequestTimes?.let { normalized.put("cdnXmuxHMaxRequestTimes", it) }
            options.xmuxHMaxReusableSecs?.let { normalized.put("cdnXmuxHMaxReusableSecs", it) }
            normalized.put("cdnHttpHostHeader", options.httpHostHeader)
            normalized.put("cdnFrontTag", options.frontTag)
            normalized.put("cdnFrontSelection", options.frontSelection)
            normalized.put("cdnFrontPoolSize", options.frontPoolSize)
            normalized.put("cdnOriginHost", options.originHost)
            normalized.put("cdnOriginPort", options.originPort)
            normalized.put("cdnOriginScheme", options.originScheme)
            normalized.put("cdnOriginPath", options.originPath)
            normalized.put("cdnBootstrapMode", options.bootstrap)
            normalized.put("cdnRoutingDnsQueryStrategy", options.routingPolicy.dnsQueryStrategy)
            normalized.put("cdnRoutingDomainStrategy", options.routingPolicy.domainStrategy)
            normalized.put("cdnRoutingDomainMatcher", options.routingPolicy.domainMatcher)
            normalized.put("cdnRoutingDirectDomainKeywords", JSONArray(options.routingPolicy.directDomainKeywords))
            normalized.put("cdnRoutingDirectDomains", JSONArray(options.routingPolicy.directDomains))
            normalized.put("cdnRoutingBlockedDomainKeywords", JSONArray(options.routingPolicy.blockedDomainKeywords))
            normalized.put("cdnRoutingBlockedDomains", JSONArray(options.routingPolicy.blockedDomains))
            normalized.put("cdnRoutingBlockSelectedFrontHost", options.routingPolicy.blockSelectedFrontHost)
            normalized.put("cdnRoutingDirectRuleCount", options.routingPolicy.directRuleCount)
            normalized.put("cdnRoutingBlockRuleCount", options.routingPolicy.blockRuleCount)
            normalized.put("cdnDnsLocalResolverEnabled", false)
            normalized.put(
                "activeFeatures",
                JSONArray(
                    buildList {
                        addAll(options.featureLabels())
                        add("engine:$engine")
                    },
                ),
            )
            normalized.put("profileHash", computeCdnAntiWhitelistProfileHash(normalized, options))
            return normalized
        }
        if (runtimeFamily == RUNTIME_FAMILY_REALITY_VPS_LAB) {
            clearCdnDerivedArgs(normalized)
            clearRealityWhitelistDerivedArgs(normalized)
            clearRealityVpsLabDerivedArgs(normalized)
            val baseArgs = JSObject(normalized.toString()).apply { remove("configMode") }
            val baseOptions = readRealityRuntimeOptions(baseArgs, profile)
            val vpsOptions = readRealityVpsLabRuntimeOptions(normalized, profile, readRealitySettings(profile, normalized.getString("serverHost", "")?.trim().orEmpty()))
            normalized.put("activationState", vpsOptions.activationState)
            normalized.put("configMode", vpsOptions.mode)
            normalized.put("dnsMode", baseOptions.dnsMode)
            normalized.put("strictRoute", baseOptions.strictRoute)
            normalized.put("disableMultiplex", baseOptions.disableMultiplex)
            normalized.put("tlsFragment", baseOptions.tlsFragment)
            normalized.put("recordFragment", baseOptions.recordFragment)
            normalized.put("bootRestoreEnabled", false)
            normalized.put("allowPrivateNetworkBypass", baseOptions.allowPrivateNetworkBypass)
            normalized.put("privateBypassCidrs", JSONArray(baseOptions.privateBypassCidrs))
            normalized.put("networkReloadOnChange", baseOptions.networkReloadOnChange)
            normalized.put("networkReloadDebounceMs", baseOptions.networkReloadDebounceMs)
            normalized.put("dnsServer", baseOptions.dnsServer)
            normalized.put("dnsServerPort", baseOptions.dnsServerPort)
            normalized.put("dnsServerName", baseOptions.dnsServerName)
            normalized.put("dnsDohPath", baseOptions.dnsDohPath)
            normalized.put("dnsStrategy", baseOptions.dnsStrategy)
            normalized.put("dnsDisableCache", baseOptions.dnsDisableCache)
            normalized.put("dnsIndependentCache", baseOptions.dnsIndependentCache)
            normalized.put("includePackages", JSONArray(baseOptions.includePackages))
            normalized.put("excludePackages", JSONArray(baseOptions.excludePackages))
            normalized.put("selectedSniHint", vpsOptions.serverName)
            normalized.put("whitelistHintSource", vpsOptions.source)
            normalized.put("whitelistHintTag", vpsOptions.tag)
            normalized.put("vpsRealityPort", vpsOptions.serverPort)
            normalized.put("vpsRealityConnectHost", vpsOptions.connectHost)
            normalized.put("vpsRealityConnectPort", vpsOptions.connectPort)
            normalized.put("vpsRealityTransport", vpsOptions.transport)
            normalized.put("vpsRealityFingerprint", vpsOptions.fingerprint)
            normalized.put("vpsRealityOwnerEgress", vpsOptions.ownerRealityEgress)
            normalized.put("frontHost", vpsOptions.serverName)
            normalized.put("frontConnectHost", vpsOptions.connectHost)
            normalized.put("frontConnectPort", vpsOptions.connectPort)
            normalized.put("frontTag", vpsOptions.tag)
            if (!vpsOptions.flow.isNullOrBlank()) {
                normalized.put("vpsRealityFlow", vpsOptions.flow)
            }
            if (!vpsOptions.grpcServiceName.isNullOrBlank()) {
                normalized.put("vpsRealityGrpcServiceName", vpsOptions.grpcServiceName)
            }
            if (!vpsOptions.grpcAuthority.isNullOrBlank()) {
                normalized.put("vpsRealityGrpcAuthority", vpsOptions.grpcAuthority)
            }
            normalized.put("activeFeatures", JSONArray(buildRealityVpsLabFeatureLabels(baseOptions, vpsOptions)))
            normalized.put("profileHash", computeRealityVpsLabProfileHash(normalized, baseOptions, vpsOptions))
            return normalized
        }
        if (runtimeFamily == RUNTIME_FAMILY_REALITY_WHITELIST_ASSISTED) {
            clearCdnDerivedArgs(normalized)
            clearRealityVpsLabDerivedArgs(normalized)
            clearRealityWhitelistDerivedArgs(normalized)
            val baseArgs = JSObject(normalized.toString()).apply { remove("configMode") }
            val baseOptions = readRealityRuntimeOptions(baseArgs, profile)
            val hintOptions =
                readRealityWhitelistHintRuntimeOptions(
                    args = normalized,
                    profile = profile,
                    fallbackServerName = readRealityServerNameHint(profile, normalized.getString("serverHost", "")?.trim().orEmpty()),
                    baseOptions = baseOptions,
                )
            normalized.put("activationState", hintOptions.activationState)
            normalized.put("configMode", hintOptions.mode)
            normalized.put("dnsMode", baseOptions.dnsMode)
            normalized.put("strictRoute", baseOptions.strictRoute)
            normalized.put("disableMultiplex", baseOptions.disableMultiplex)
            normalized.put("tlsFragment", baseOptions.tlsFragment)
            normalized.put("recordFragment", baseOptions.recordFragment)
            normalized.put("bootRestoreEnabled", false)
            normalized.put("allowPrivateNetworkBypass", baseOptions.allowPrivateNetworkBypass)
            normalized.put("privateBypassCidrs", JSONArray(baseOptions.privateBypassCidrs))
            normalized.put("networkReloadOnChange", baseOptions.networkReloadOnChange)
            normalized.put("networkReloadDebounceMs", baseOptions.networkReloadDebounceMs)
            normalized.put("dnsServer", baseOptions.dnsServer)
            normalized.put("dnsServerPort", baseOptions.dnsServerPort)
            normalized.put("dnsServerName", baseOptions.dnsServerName)
            normalized.put("dnsDohPath", baseOptions.dnsDohPath)
            normalized.put("dnsStrategy", baseOptions.dnsStrategy)
            normalized.put("dnsDisableCache", baseOptions.dnsDisableCache)
            normalized.put("dnsIndependentCache", baseOptions.dnsIndependentCache)
            normalized.put("includePackages", JSONArray(baseOptions.includePackages))
            normalized.put("excludePackages", JSONArray(baseOptions.excludePackages))
            normalized.put("selectedSniHint", hintOptions.selectedSniHint)
            normalized.put("selectedCidrHint", hintOptions.selectedCidrHint)
            normalized.put("whitelistHintSource", hintOptions.whitelistHintSource)
            normalized.put("whitelistHintTag", hintOptions.whitelistHintTag)
            normalized.put("whitelistHintSelection", hintOptions.selection)
            normalized.put("whitelistHintPoolSize", hintOptions.hintPoolSize)
            normalized.put("whitelistBootstrapMode", hintOptions.bootstrap)
            normalized.put("activeFeatures", JSONArray(buildRealityWhitelistAssistedFeatureLabels(baseOptions, hintOptions)))
            normalized.put("profileHash", computeRealityWhitelistAssistedProfileHash(normalized, baseOptions, hintOptions))
            return normalized
        }
        clearCdnDerivedArgs(normalized)
        clearRealityVpsLabDerivedArgs(normalized)
        clearRealityWhitelistDerivedArgs(normalized)
        val options = readRealityRuntimeOptions(normalized, profile)
        normalized.put(
            "activationState",
            normalized.getString("activationState", null)?.trim().takeUnless { it.isNullOrEmpty() }
                ?: ACTIVATION_STATE_ACTIVE,
        )
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

    private fun clearRealityDerivedArgs(args: JSObject) {
        listOf(
            "dnsMode",
            "strictRoute",
            "disableMultiplex",
            "tlsFragment",
            "recordFragment",
            "allowPrivateNetworkBypass",
            "privateBypassCidrs",
            "networkReloadOnChange",
            "networkReloadDebounceMs",
            "dnsServer",
            "dnsServerPort",
            "dnsServerName",
            "dnsDohPath",
            "dnsStrategy",
            "dnsDisableCache",
            "dnsIndependentCache",
            "includePackages",
            "excludePackages",
        ).forEach(args::remove)
    }

    private fun clearRealityWhitelistDerivedArgs(args: JSObject) {
        listOf(
            "selectedSniHint",
            "selectedCidrHint",
            "whitelistHintSource",
            "whitelistHintTag",
            "whitelistHintSelection",
            "whitelistHintPoolSize",
            "whitelistBootstrapMode",
        ).forEach(args::remove)
    }

    private fun clearRealityVpsLabDerivedArgs(args: JSObject) {
        listOf(
            "vpsRealityPort",
            "vpsRealityConnectHost",
            "vpsRealityConnectPort",
            "vpsRealityTransport",
            "vpsRealityFingerprint",
            "vpsRealityOwnerEgress",
            "vpsRealityFlow",
            "vpsRealityGrpcServiceName",
            "vpsRealityGrpcAuthority",
        ).forEach(args::remove)
    }

    private fun clearCdnDerivedArgs(args: JSObject) {
        listOf(
            "cdnProvider",
            "cdnTransport",
            "cdnFrontHost",
            "cdnFrontPort",
            "cdnFrontPath",
            "cdnConnectHost",
            "cdnConnectPort",
            "cdnTlsServerName",
            "cdnHttpHostHeader",
            "cdnFrontTag",
            "cdnFrontSelection",
            "cdnFrontPoolSize",
            "cdnOriginHost",
            "cdnOriginPort",
            "cdnOriginScheme",
            "cdnOriginPath",
            "cdnBootstrapMode",
            "cdnRoutingDnsQueryStrategy",
            "cdnRoutingDomainStrategy",
            "cdnRoutingDomainMatcher",
            "cdnRoutingDirectDomainKeywords",
            "cdnRoutingDirectDomains",
            "cdnRoutingBlockedDomainKeywords",
            "cdnRoutingBlockedDomains",
            "cdnRoutingBlockSelectedFrontHost",
            "cdnRoutingDirectRuleCount",
            "cdnRoutingBlockRuleCount",
            "cdnDnsLocalResolverEnabled",
            "frontHost",
            "frontConnectHost",
            "frontConnectPort",
            "frontPath",
            "frontProvider",
            "frontTag",
        ).forEach(args::remove)
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

    private fun buildHysteria2Config(
        socksPort: Int,
        hysteria2: Hysteria2Settings,
        options: RealityRuntimeOptions,
    ): String {
        val scaffold =
            JSONObject(
                buildRealityConfigDocument(
                    socksPort,
                    RealitySettings(
                        serverHost = hysteria2.serverHost,
                        serverPort = hysteria2.serverPort,
                        uuid = "00000000-0000-4000-8000-000000000000",
                        flow = "xtls-rprx-vision",
                        serverName = hysteria2.serverName,
                        publicKey = "unused",
                        shortId = "0000000000000000",
                    ),
                    options,
                    leakHardened = true,
                ),
            )
        val outbound =
            JSONObject()
                .put("type", "hysteria2")
                .put("tag", "main-out")
                .put("server", hysteria2.serverHost)
                .put("server_port", hysteria2.serverPort)
                .put("password", hysteria2.password)
                .put(
                    "obfs",
                    JSONObject()
                        .put("type", hysteria2.obfsType)
                        .put("password", hysteria2.obfsPassword),
                ).put(
                    "tls",
                    JSONObject()
                        .put("enabled", true)
                        .put("server_name", hysteria2.serverName)
                        .put(
                            "certificate_public_key_sha256",
                            JSONArray().put(hysteria2.certificatePublicKeySha256),
                        ),
                )
        scaffold.getJSONArray("outbounds").put(0, outbound)
        return scaffold.toString(2)
    }

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
        appendLocalBypassRouteRules(routeRules, options.localBypassDomainKeywords, options.localBypassDomains)

        val config =
            JSONObject()
                .put("log", JSONObject().put("level", "warn"))
                .put(
                    "dns",
                    JSONObject()
                        .put("servers", JSONArray().put(buildRealityDnsServer(options, "main-out")))
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

    private fun buildCdnAntiWhitelistConfig(
        socksPort: Int,
        reality: RealitySettings,
        options: CdnAntiWhitelistRuntimeOptions,
    ): String {
        val routeRules = buildCdnAntiWhitelistRouteRules(options)

        val config =
            JSONObject()
                .put("log", JSONObject().put("level", "warn"))
                .put("dns", buildCdnAntiWhitelistDnsConfig(options, "main-out"))
                .put(
                    "inbounds",
                    JSONArray()
                        .put(
                            JSONObject()
                                .put("type", "tun")
                                .put("tag", "tun-in")
                                .put("address", JSONArray().put(DEFAULT_TUN_ADDRESS))
                                .put("mtu", DEFAULT_TUN_MTU)
                                .put("auto_route", true)
                                .put("strict_route", false),
                        ).put(
                            JSONObject()
                                .put("type", "socks")
                                .put("tag", "socks-in")
                                .put("listen", "127.0.0.1")
                                .put("listen_port", socksPort),
                        ),
                ).put(
                    "outbounds",
                    buildCdnAntiWhitelistOutbounds(reality, options),
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

    private fun buildCdnAntiWhitelistLocalSocksBridgeConfig(
        socksPort: Int,
        sidecarSocksPort: Int,
        options: CdnAntiWhitelistRuntimeOptions,
    ): String {
        val routeRules = buildCdnAntiWhitelistRouteRules(options)
        val config =
            JSONObject()
                .put("log", JSONObject().put("level", "warn"))
                .put("dns", buildCdnAntiWhitelistDnsConfig(options, "main-out"))
                .put(
                    "inbounds",
                    JSONArray()
                        .put(
                            JSONObject()
                                .put("type", "tun")
                                .put("tag", "tun-in")
                                .put("address", JSONArray().put(DEFAULT_TUN_ADDRESS))
                                .put("mtu", DEFAULT_TUN_MTU)
                                .put("auto_route", true)
                                .put("strict_route", false),
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
                                .put("type", "socks")
                                .put("tag", "main-out")
                                .put("server", "127.0.0.1")
                                .put("server_port", sidecarSocksPort),
                                )
                        .put(
                            JSONObject()
                                .put("type", "direct")
                                .put("tag", "direct"),
                        ).put(
                            JSONObject()
                                .put("type", "block")
                                .put("tag", "block"),
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

    private fun buildCdnAntiWhitelistDnsConfig(
        options: CdnAntiWhitelistRuntimeOptions,
        detour: String,
    ): JSONObject {
        val servers =
            JSONArray()
                .put(
                    JSONObject()
                        .put("tag", "resolver")
                        .put("type", "https")
                        .put("server", REALITY_DNS_DEFAULT_SERVER)
                        .put("server_port", 443)
                        .put("path", REALITY_DNS_DEFAULT_DOH_PATH)
                        .put("detour", detour)
                        .put(
                            "tls",
                            JSONObject().put("server_name", REALITY_DNS_DEFAULT_SERVER_NAME),
                        ),
                )
        val rules = JSONArray()
        return JSONObject()
            .put("servers", servers)
            .put("rules", rules)
            .put("final", "resolver")
            .put("strategy", REALITY_DNS_STRATEGY_PREFER_IPV4)
    }

    private fun buildCdnAntiWhitelistOutbounds(
        reality: RealitySettings,
        options: CdnAntiWhitelistRuntimeOptions,
    ): JSONArray =
        JSONArray()
            .put(
                JSONObject()
                    .put("type", "vless")
                    .put("tag", "main-out")
                    .put("server", options.connectHost)
                    .put("server_port", options.connectPort)
                    .put("uuid", reality.uuid)
                    .put(
                        "tls",
                        JSONObject()
                            .put("enabled", true)
                            .put("server_name", options.tlsServerName)
                            .put(
                                "utls",
                                JSONObject()
                                    .put("enabled", true)
                                    .put("fingerprint", "chrome"),
                            ),
                    ).put("transport", buildCdnTransportObject(options))
                    .put(
                        "multiplex",
                        JSONObject().put("enabled", false),
                    ),
            ).put(
                JSONObject()
                    .put("type", "direct")
                    .put("tag", "direct"),
            ).put(
                JSONObject()
                    .put("type", "block")
                    .put("tag", "block"),
            )

    private fun buildCdnAntiWhitelistRouteRules(options: CdnAntiWhitelistRuntimeOptions): JSONArray =
        JSONArray()
            .put(JSONObject().put("action", "sniff"))
            .put(
                JSONObject()
                    .put("ip_is_private", true)
                    .put("outbound", "direct"),
            ).apply {
                if (options.routingPolicy.directDomainKeywords.isNotEmpty()) {
                    put(
                        JSONObject()
                            .put("domain_keyword", JSONArray(options.routingPolicy.directDomainKeywords))
                            .put("outbound", "direct"),
                    )
                }
                if (options.routingPolicy.directDomains.isNotEmpty()) {
                    put(
                        JSONObject()
                            .put("domain", JSONArray(options.routingPolicy.directDomains))
                            .put("outbound", "direct"),
                    )
                }
                if (options.routingPolicy.blockedDomainKeywords.isNotEmpty()) {
                    put(
                        JSONObject()
                            .put("domain_keyword", JSONArray(options.routingPolicy.blockedDomainKeywords))
                            .put("outbound", "block"),
                    )
                }
                if (options.routingPolicy.blockedDomains.isNotEmpty()) {
                    put(
                        JSONObject()
                            .put("domain", JSONArray(options.routingPolicy.blockedDomains))
                            .put("outbound", "block"),
                    )
                }
                if (options.routingPolicy.blockSelectedFrontHost) {
                    put(
                        JSONObject()
                            .put("domain", JSONArray().put(options.frontHost.lowercase(Locale.ROOT)))
                            .put("outbound", "block"),
                    )
                }
            }

    internal fun renderCdnAntiWhitelistConfigForTesting(args: JSObject): String {
        val rawProfile = args.getString("profileJson", "{}") ?: "{}"
        val profile = JSObject(rawProfile)
        val serverHost = args.getString("serverHost", "")?.trim().orEmpty().ifBlank {
            profile.optString("serverHost", "").trim()
        }
        require(serverHost.isNotBlank()) { "serverHost is required for CDN config rendering" }
        val normalized = normalizeRuntimeArgs(args)
        val options = readCdnAntiWhitelistRuntimeOptions(normalized, profile, serverHost)
        val reality =
            readCdnAntiWhitelistRealitySettings(
                profile = profile,
                fallback = readRealitySettings(profile, serverHost),
                options = options,
            )
        return buildCdnAntiWhitelistConfig(DEFAULT_SOCKS_PORT, reality, options)
    }

    internal fun renderHysteria2ConfigForTesting(args: JSObject): String {
        val rawProfile = args.getString("profileJson", "{}") ?: "{}"
        val profile = JSObject(rawProfile)
        val serverHost = args.getString("serverHost", "")?.trim().orEmpty().ifBlank {
            profile.optString("serverHost", "").trim()
        }
        require(serverHost.isNotBlank()) { "serverHost is required for Hysteria 2 config rendering" }
        val normalized = normalizeRuntimeArgs(args)
        val options = readRealityRuntimeOptions(normalized, profile)
        return buildHysteria2Config(
            DEFAULT_SOCKS_PORT,
            readHysteria2Settings(profile, serverHost),
            options,
        )
    }

    internal fun renderXrayNativeCdnAntiWhitelistConfigForTesting(args: JSObject): String {
        val rawProfile = args.getString("profileJson", "{}") ?: "{}"
        val profile = JSObject(rawProfile)
        val serverHost = args.getString("serverHost", "")?.trim().orEmpty().ifBlank {
            profile.optString("serverHost", "").trim()
        }
        require(serverHost.isNotBlank()) { "serverHost is required for CDN config rendering" }
        val normalized = normalizeRuntimeArgs(args)
        val options = readCdnAntiWhitelistRuntimeOptions(normalized, profile, serverHost)
        val reality =
            readCdnAntiWhitelistRealitySettings(
                profile = profile,
                fallback = readRealitySettings(profile, serverHost),
                options = options,
            )
        return buildXrayNativeCdnAntiWhitelistConfig(DEFAULT_SOCKS_PORT, reality, options)
    }

    internal fun renderRealityVpsLabConfigForTesting(args: JSObject): String {
        val rawProfile = args.getString("profileJson", "{}") ?: "{}"
        val profile = JSObject(rawProfile)
        val serverHost = args.getString("serverHost", "")?.trim().orEmpty().ifBlank {
            profile.optString("serverHost", "").trim()
        }
        require(serverHost.isNotBlank()) { "serverHost is required for reality-vps-lab config rendering" }
        val directReality = readRealitySettings(profile, serverHost)
        val normalized = normalizeRuntimeArgs(args)
        val baseArgs = JSObject(normalized.toString()).apply { remove("configMode") }
        val baseOptions = readRealityRuntimeOptions(baseArgs, profile)
        val options = readRealityVpsLabRuntimeOptions(normalized, profile, directReality)
        val relayReality = readRealityVpsLabRelaySettings(profile, serverHost, directReality, options)
        val ownerReality = readRealityVpsLabOwnerBootstrapSettings(profile, serverHost) ?: relayReality
        return buildRealityVpsLabConfig(DEFAULT_SOCKS_PORT, relayReality, ownerReality, baseOptions, options)
    }

    private fun buildCdnTransportObject(options: CdnAntiWhitelistRuntimeOptions): JSONObject =
        when (options.transport) {
            CDN_TRANSPORT_XHTTP ->
                JSONObject()
                    .put("type", "xhttp")
                    .put("path", options.frontPath)
                    .put(
                        "headers",
                        JSONObject().put("Host", options.httpHostHeader),
                    )

            CDN_TRANSPORT_HTTP_UPGRADE ->
                JSONObject()
                    .put("type", "httpupgrade")
                    .put("path", options.frontPath)
                    .put(
                        "headers",
                        JSONObject().put("Host", options.httpHostHeader),
                    )

            else ->
                JSONObject()
                    .put("type", "ws")
                    .put("path", options.frontPath)
                    .put(
                        "headers",
                        JSONObject().put("Host", options.httpHostHeader),
                    )
        }

    private fun buildXrayNativeCdnAntiWhitelistConfig(
        socksPort: Int,
        reality: RealitySettings,
        options: CdnAntiWhitelistRuntimeOptions,
    ): String {
        val streamSettings =
            JSONObject()
                .put("security", "tls")
                .put(
                    "tlsSettings",
                    JSONObject()
                        .put("serverName", options.tlsServerName)
                        .put("allowInsecure", options.tlsAllowInsecure),
                )
        if (options.tlsAlpn.isNotEmpty()) {
            streamSettings.getJSONObject("tlsSettings").put(
                "alpn",
                JSONArray().apply { options.tlsAlpn.forEach(::put) },
            )
        }
        when (options.transport) {
            CDN_TRANSPORT_XHTTP ->
                streamSettings
                    .put("network", "xhttp")
                    .put(
                        "xhttpSettings",
                        JSONObject()
                            .put("path", options.frontPath)
                            .put("host", options.httpHostHeader)
                            .apply {
                                options.xhttpMode?.let { put("mode", it) }
                                if (
                                    options.xmuxMaxConcurrency != null ||
                                        options.xmuxHMaxRequestTimes != null ||
                                        options.xmuxHMaxReusableSecs != null
                                ) {
                                    put(
                                        "xmux",
                                        JSONObject().apply {
                                            options.xmuxMaxConcurrency?.let { put("maxConcurrency", it) }
                                            options.xmuxHMaxRequestTimes?.let { put("hMaxRequestTimes", it) }
                                            options.xmuxHMaxReusableSecs?.let { put("hMaxReusableSecs", it) }
                                        },
                                    )
                                }
                            },
                    )

            CDN_TRANSPORT_HTTP_UPGRADE ->
                streamSettings
                    .put("network", "httpupgrade")
                    .put(
                        "httpupgradeSettings",
                        JSONObject()
                            .put("path", options.frontPath)
                            .put("host", options.httpHostHeader),
                    )

            else ->
                streamSettings
                    .put("network", "ws")
                    .put(
                        "wsSettings",
                        JSONObject()
                            .put("path", options.frontPath)
                            .put(
                                "headers",
                                JSONObject().put("Host", options.httpHostHeader),
                            ),
                    )
        }
        return JSONObject()
            .put("log", JSONObject().put("loglevel", "warning"))
            .put(
                "inbounds",
                JSONArray().put(
                    JSONObject()
                        .put("listen", "127.0.0.1")
                        .put("port", socksPort)
                        .put("protocol", "socks")
                        .put(
                            "settings",
                            JSONObject().put("udp", true),
                        ),
                ),
            ).put(
                "outbounds",
                JSONArray().put(
                    JSONObject()
                        .put("tag", "main-out")
                        .put("protocol", "vless")
                        .put(
                            "settings",
                            JSONObject().put(
                                "vnext",
                                JSONArray().put(
                                    JSONObject()
                                        .put("address", options.connectHost)
                                        .put("port", options.connectPort)
                                        .put(
                                            "users",
                                            JSONArray().put(
                                                JSONObject()
                                                    .put("id", reality.uuid)
                                                    .put("encryption", "none"),
                                            ),
                                        ),
                                ),
                            ),
                        ).put("streamSettings", streamSettings),
                ),
            ).toString(2)
    }

    private fun buildCdnAntiWhitelistScaffoldDocument(
        serverHost: String,
        reality: RealitySettings,
        options: CdnAntiWhitelistRuntimeOptions,
    ): String =
        JSONObject()
            .put("kind", "odin-one-android-cdn-anti-whitelist-scaffold")
            .put("runtimeFamily", RUNTIME_FAMILY_CDN_ANTI_WHITELIST)
            .put("activationState", options.activationState)
            .put("configMode", options.mode)
            .put("serverHost", serverHost)
            .put("provider", options.provider)
            .put("transport", options.transport)
            .put("xhttpMode", options.xhttpMode)
            .put("tlsAlpn", JSONArray().apply { options.tlsAlpn.forEach(::put) })
            .put("xmuxMaxConcurrency", options.xmuxMaxConcurrency)
            .put("xmuxHMaxRequestTimes", options.xmuxHMaxRequestTimes)
            .put("xmuxHMaxReusableSecs", options.xmuxHMaxReusableSecs)
            .put("frontHost", options.frontHost)
            .put("frontPort", options.frontPort)
            .put("connectHost", options.connectHost)
            .put("connectPort", options.connectPort)
            .put("frontPath", options.frontPath)
            .put("tlsServerName", options.tlsServerName)
            .put("tlsAllowInsecure", options.tlsAllowInsecure)
            .put("httpHostHeader", options.httpHostHeader)
            .put("frontTag", options.frontTag)
            .put("frontSelection", options.frontSelection)
            .put("frontPoolSize", options.frontPoolSize)
            .put("originHost", options.originHost)
            .put("originPort", options.originPort)
            .put("originScheme", options.originScheme)
            .put("originPath", options.originPath)
            .put("bootstrap", options.bootstrap)
            .put(
                "selectedFront",
                JSONObject()
                    .put("host", options.frontHost)
                    .put("port", options.frontPort)
                    .put("connectHost", options.connectHost)
                    .put("connectPort", options.connectPort)
                    .put("path", options.frontPath)
                    .put("tlsServerName", options.tlsServerName)
                    .put("tlsAllowInsecure", options.tlsAllowInsecure)
                    .put("httpHostHeader", options.httpHostHeader)
                    .put("provider", options.provider)
                    .put("tag", options.frontTag),
            )
            .put(
                "frontPool",
                JSONArray().apply {
                    options.frontPool.forEach { candidate ->
                        put(
                            JSONObject()
                                .put("host", candidate.host)
                                .put("port", candidate.port)
                                .put("connectHost", candidate.connectHost)
                                .put("connectPort", candidate.connectPort)
                                .put("path", candidate.path)
                                .put("tlsServerName", candidate.tlsServerName)
                                .put("tlsAllowInsecure", candidate.tlsAllowInsecure)
                                .put("httpHostHeader", candidate.httpHostHeader)
                                .put("provider", candidate.provider)
                                .put("tag", candidate.tag),
                        )
                    }
                },
            )
            .put(
                "targetShape",
                JSONObject()
                    .put("protocol", "vless")
                    .put("transport", options.transport)
                    .put("security", "tls")
                    .put("frontingModel", "whitelist-reachable-https-front"),
            )
            .put("routingPolicyPlan", buildCdnRoutingPolicyPlan(options.routingPolicy, options.frontHost))
            .put(
                "clientPlan",
                JSONObject()
                    .put("protocol", "vless")
                    .put("transport", options.transport)
                    .put("xhttpMode", options.xhttpMode)
                    .put("security", "tls")
                    .put("connectHost", options.connectHost)
                    .put("connectPort", options.connectPort)
                    .put("serverHost", options.connectHost)
                    .put("serverPort", options.connectPort)
                    .put("path", options.frontPath)
                    .put("tlsServerName", options.tlsServerName)
                    .put("tlsAllowInsecure", options.tlsAllowInsecure)
                    .put("tlsAlpn", JSONArray().apply { options.tlsAlpn.forEach(::put) })
                    .put(
                        "xmux",
                        JSONObject()
                            .put("maxConcurrency", options.xmuxMaxConcurrency)
                            .put("hMaxRequestTimes", options.xmuxHMaxRequestTimes)
                            .put("hMaxReusableSecs", options.xmuxHMaxReusableSecs),
                    )
                    .put("httpHostHeader", options.httpHostHeader)
                    .put("routingPolicy", buildCdnRoutingPolicyPlan(options.routingPolicy, options.frontHost)),
            )
            .put(
                "originPlan",
                JSONObject()
                    .put("host", options.originHost)
                    .put("port", options.originPort)
                    .put("scheme", options.originScheme)
                    .put("path", options.originPath),
            )
            .put("clientBuilderSpec", buildCdnClientBuilderSpec(options))
            .put("serverBuilderSpec", buildCdnServerBuilderSpec(options))
            .put("serverProfileSchema", buildCdnServerProfileSchema())
            .put("rolloutStages", buildCdnRolloutStages())
            .put("deviceValidationMatrix", buildCdnDeviceValidationMatrix(options))
            .put("blockedDirectValidationPlan", buildCdnBlockedDirectValidationPlan(options))
            .put(
                "rolloutGuardrails",
                JSONArray()
                    .put("Keep direct-reality as the default Android data plane.")
                    .put("Activate this family only as a hidden, owner-controlled whitelist-front mode.")
                    .put("Validate the selected front on Russian whitelist-reachable Wi-Fi and LTE paths before any wider rollout."),
            )
            .put(
                "bootstrapReality",
                JSONObject()
                    .put("serverHost", reality.serverHost)
                    .put("serverPort", reality.serverPort)
                    .put("serverName", reality.serverName)
                    .put("flow", reality.flow),
            ).put(
                "notes",
                JSONArray()
                    .put("This file is a scaffold plan, not an active libbox config.")
                    .put("Keep the stable direct-reality path as the default Android data plane.")
                    .put("Treat this as a whitelist-front path for Russian clients, not as REALITY stretched through a generic CDN.")
                    .put("The first realistic activation should use HTTP semantics such as WebSocket or XHTTP over a whitelist-reachable HTTPS front."),
            ).toString(2)

    private fun buildCdnClientBuilderSpec(options: CdnAntiWhitelistRuntimeOptions): JSONObject =
        JSONObject()
            .put("targetRuntimeFamily", RUNTIME_FAMILY_CDN_ANTI_WHITELIST)
            .put("engine", "sing-box")
            .put("protocol", "vless")
            .put("transport", options.transport)
            .put("uuidSource", "profile.stagedFallbacks.vlessReality.uuid")
            .put("bindings", buildCdnClientBindings(options))
            .put("routingPolicy", buildCdnRoutingPolicyPlan(options.routingPolicy, options.frontHost))
            .put("dnsPlanTemplate", buildCdnClientDnsPlanTemplate(options.routingPolicy))
            .put("outboundSetTemplate", buildCdnClientOutboundSetTemplate(options))
            .put("routePlanTemplate", buildCdnClientRoutePlanTemplate(options))
            .put(
                "notes",
                JSONArray()
                    .put("This is a future activation template, not a live runtime config.")
                    .put("Do not reuse REALITY-specific flow settings on the WebSocket family unless explicitly validated.")
                    .put("Keep TLS SNI and HTTP Host aligned with the selected whitelist-reachable front.")
                    .put("Model DNS query strategy, split-direct local-service routing, and anti-loop front blocking before any active rollout."),
            )
            .put("outboundTemplate", buildCdnClientOutboundTemplate(options))

    private fun buildCdnClientBindings(options: CdnAntiWhitelistRuntimeOptions): JSONObject =
        JSONObject()
            .put("frontHost", options.frontHost)
            .put("frontPort", options.frontPort)
            .put("connectHost", options.connectHost)
            .put("connectPort", options.connectPort)
            .put("frontPath", options.frontPath)
            .put("tlsServerName", options.tlsServerName)
            .put("httpHostHeader", options.httpHostHeader)
            .put("originHost", options.originHost)
            .put("originPort", options.originPort)
            .put("originPath", options.originPath)
            .put("routingPolicy", buildCdnRoutingPolicyPlan(options.routingPolicy, options.frontHost))

    private fun buildCdnRoutingPolicyPlan(
        routingPolicy: CdnRoutingPolicyOptions,
        selectedFrontHost: String,
    ): JSONObject {
        val effectiveBlockedDomains =
            buildList {
                addAll(routingPolicy.blockedDomains)
                if (routingPolicy.blockSelectedFrontHost && selectedFrontHost.isNotBlank()) {
                    add(selectedFrontHost.lowercase(Locale.ROOT))
                }
            }.distinct()
        return JSONObject()
            .put("dnsQueryStrategy", routingPolicy.dnsQueryStrategy)
            .put("domainStrategy", routingPolicy.domainStrategy)
            .put("domainMatcher", routingPolicy.domainMatcher)
            .put("directDomainKeywords", JSONArray(routingPolicy.directDomainKeywords))
            .put("directDomains", JSONArray(routingPolicy.directDomains))
            .put("blockedDomainKeywords", JSONArray(routingPolicy.blockedDomainKeywords))
            .put("blockedDomains", JSONArray(routingPolicy.blockedDomains))
            .put("blockSelectedFrontHost", routingPolicy.blockSelectedFrontHost)
            .put("effectiveBlockedDomains", JSONArray(effectiveBlockedDomains))
            .put("selectedFrontHost", selectedFrontHost)
            .put(
                "notes",
                JSONArray()
                    .put("This policy block is scaffold-only in the current CDN family and does not yet alter the live route table.")
                    .put("It captures DNS query strategy, split-direct local-service surfaces, and anti-loop front blocking for a future active rollout."),
            )
    }

    private fun buildCdnClientDnsPlanTemplate(routingPolicy: CdnRoutingPolicyOptions): JSONObject =
        JSONObject()
            .put("engine", "sing-box")
            .put("queryStrategy", routingPolicy.dnsQueryStrategy)
            .put("domainStrategy", routingPolicy.domainStrategy)
            .put(
                "servers",
                JSONArray()
                    .put(
                        JSONObject()
                            .put("tag", "resolver-primary")
                            .put("addressSource", "profile.androidRuntime.reality.dnsServer | default:1.1.1.1")
                            .put("detour", "direct"),
                    )
                    .put(
                        JSONObject()
                            .put("tag", "resolver-secondary")
                            .put("addressLiteral", "1.0.0.1")
                            .put("detour", "direct"),
                    ),
            ).put(
                "notes",
                JSONArray()
                    .put("Model the Happ-style UseIP DNS posture here before enabling the active CDN family.")
                    .put("Prefer reusing the stable direct-reality resolver settings as the primary source of truth."),
            )

    private fun buildCdnClientOutboundSetTemplate(options: CdnAntiWhitelistRuntimeOptions): JSONArray =
        JSONArray()
            .put(
                JSONObject()
                    .put("tag", "cdn-proxy")
                    .put("role", "future-fronted-vless-outbound")
                    .put("transport", options.transport),
            )
            .put(
                JSONObject()
                    .put("tag", "direct")
                    .put("type", "direct"),
            )
            .put(
                JSONObject()
                    .put("tag", "block")
                    .put("type", "block"),
            )

    private fun buildCdnClientRoutePlanTemplate(options: CdnAntiWhitelistRuntimeOptions): JSONObject =
        JSONObject()
            .put("engine", "sing-box")
            .put("domainMatcher", options.routingPolicy.domainMatcher)
            .put("domainStrategy", options.routingPolicy.domainStrategy)
            .put("finalOutbound", "cdn-proxy")
            .put("outbounds", buildCdnClientOutboundSetTemplate(options))
            .put("rules", buildCdnClientRouteRulesTemplate(options))
            .put(
                "notes",
                JSONArray()
                    .put("This route plan is still scaffold-only and does not yet alter the live Android route table.")
                    .put("Keep local-service surfaces direct and block the selected visible front from re-entering the proxy path."),
            )

    private fun buildCdnClientRouteRulesTemplate(options: CdnAntiWhitelistRuntimeOptions): JSONArray =
        JSONArray().apply {
            if (options.routingPolicy.directDomainKeywords.isNotEmpty()) {
                put(
                    JSONObject()
                        .put("type", "field")
                        .put("match", "domain_keyword")
                        .put("values", JSONArray(options.routingPolicy.directDomainKeywords))
                        .put("outboundTag", "direct")
                        .put("reason", "local-service-bypass"),
                )
            }
            if (options.routingPolicy.directDomains.isNotEmpty()) {
                put(
                    JSONObject()
                        .put("type", "field")
                        .put("match", "domain")
                        .put("values", JSONArray(options.routingPolicy.directDomains))
                        .put("outboundTag", "direct")
                        .put("reason", "local-service-bypass-exact"),
                )
            }
            if (options.routingPolicy.blockedDomainKeywords.isNotEmpty()) {
                put(
                    JSONObject()
                        .put("type", "field")
                        .put("match", "domain_keyword")
                        .put("values", JSONArray(options.routingPolicy.blockedDomainKeywords))
                        .put("outboundTag", "block")
                        .put("reason", "anti-loop-keyword"),
                )
            }
            if (options.routingPolicy.blockedDomains.isNotEmpty()) {
                put(
                    JSONObject()
                        .put("type", "field")
                        .put("match", "domain")
                        .put("values", JSONArray(options.routingPolicy.blockedDomains))
                        .put("outboundTag", "block")
                        .put("reason", "anti-loop-domain"),
                )
            }
            if (options.routingPolicy.blockSelectedFrontHost) {
                put(
                    JSONObject()
                        .put("type", "field")
                        .put("match", "domain")
                        .put("values", JSONArray().put(options.frontHost.lowercase(Locale.ROOT)))
                        .put("outboundTag", "block")
                        .put("reason", "anti-loop-selected-front"),
                )
            }
        }

    private fun buildCdnClientOutboundTemplate(options: CdnAntiWhitelistRuntimeOptions): JSONObject =
        when (options.transport) {
            CDN_TRANSPORT_XHTTP ->
                JSONObject()
                    .put("type", "vless")
                    .put("server", "\$connectHost")
                    .put("server_port", "\$connectPort")
                    .put("uuid", "\$profile.stagedFallbacks.vlessReality.uuid")
                    .put(
                        "tls",
                        JSONObject()
                            .put("enabled", true)
                            .put("server_name", "\$tlsServerName")
                            .put(
                                "utls",
                                JSONObject()
                                    .put("enabled", true)
                                    .put("fingerprint", "chrome"),
                            ),
                    ).put(
                        "transport",
                        JSONObject()
                            .put("type", "xhttp")
                            .put("path", "\$frontPath")
                            .put(
                                "headers",
                                JSONObject().put("Host", "\$httpHostHeader"),
                            ),
                    )

            CDN_TRANSPORT_HTTP_UPGRADE ->
                JSONObject()
                    .put("type", "vless")
                    .put("server", "\$connectHost")
                    .put("server_port", "\$connectPort")
                    .put("uuid", "\$profile.stagedFallbacks.vlessReality.uuid")
                    .put(
                        "tls",
                        JSONObject()
                            .put("enabled", true)
                            .put("server_name", "\$tlsServerName")
                            .put(
                                "utls",
                                JSONObject()
                                    .put("enabled", true)
                                    .put("fingerprint", "chrome"),
                            ),
                    ).put(
                        "transport",
                        JSONObject()
                            .put("type", "httpupgrade")
                            .put("path", "\$frontPath")
                            .put(
                                "headers",
                                JSONObject().put("Host", "\$httpHostHeader"),
                            ),
                    )

            else ->
                JSONObject()
                    .put("type", "vless")
                    .put("server", "\$connectHost")
                    .put("server_port", "\$connectPort")
                    .put("uuid", "\$profile.stagedFallbacks.vlessReality.uuid")
                    .put(
                        "tls",
                        JSONObject()
                            .put("enabled", true)
                            .put("server_name", "\$tlsServerName")
                            .put(
                                "utls",
                                JSONObject()
                                    .put("enabled", true)
                                    .put("fingerprint", "chrome"),
                            ),
                    ).put(
                        "transport",
                        JSONObject()
                            .put("type", "ws")
                            .put("path", "\$frontPath")
                            .put(
                                "headers",
                                JSONObject().put("Host", "\$httpHostHeader"),
                            ),
                    )
        }

    private fun buildCdnServerBuilderSpec(options: CdnAntiWhitelistRuntimeOptions): JSONObject =
        JSONObject()
            .put("activationMode", "origin-adapter-plus-core-inbound")
            .put("transport", options.transport)
            .put(
                "originBindings",
                JSONObject()
                    .put("host", options.originHost)
                    .put("port", options.originPort)
                    .put("scheme", options.originScheme)
                    .put("path", options.originPath)
                    .put("expectedFrontHostHeader", options.httpHostHeader),
            )
            .put("coreInboundBlueprint", buildCdnServerInboundBlueprint(options))
            .put("reverseProxyBlueprint", buildCdnReverseProxyBlueprint(options))
            .put(
                "notes",
                JSONArray()
                    .put("Keep server-side CDN handling isolated from the stable REALITY listener.")
                    .put("The origin adapter should preserve the selected path and front Host header.")
                    .put("Treat this as a dedicated inbound family, not a mutation of the direct REALITY inbound."),
            )

    private fun buildCdnServerInboundBlueprint(options: CdnAntiWhitelistRuntimeOptions): JSONObject =
        JSONObject()
            .put("protocol", "vless")
            .put("transport", options.transport)
            .put("listen", "127.0.0.1")
            .put("listenPort", options.originPort)
            .put("path", options.originPath)
            .put("uuidSource", "profile.stagedFallbacks.vlessReality.uuid")
            .put(
                "acceptedHostHeaders",
                JSONArray().put(options.httpHostHeader),
            )
            .put("tlsTermination", "edge-or-reverse-proxy")

    private fun buildCdnReverseProxyBlueprint(options: CdnAntiWhitelistRuntimeOptions): JSONObject =
        JSONObject()
            .put("publicScheme", "https")
            .put("originScheme", options.originScheme)
            .put("originHost", options.originHost)
            .put("originPort", options.originPort)
            .put("path", options.originPath)
            .put("preserveHostHeader", options.httpHostHeader)
            .put("proxyUpgrade", options.transport == CDN_TRANSPORT_WEBSOCKET)

    private fun buildCdnServerProfileSchema(): JSONObject =
        JSONObject()
            .put("kind", "odin-one-whitelist-front-origin-profile-v1")
            .put(
                "requiredFields",
                JSONArray()
                    .put("androidRuntime.cdnAntiWhitelist.frontPool[].host")
                    .put("androidRuntime.cdnAntiWhitelist.frontPool[].port")
                    .put("androidRuntime.cdnAntiWhitelist.frontPool[].path")
                    .put("androidRuntime.cdnAntiWhitelist.frontPool[].tlsServerName")
                    .put("androidRuntime.cdnAntiWhitelist.frontPool[].hostHeader")
                    .put("androidRuntime.cdnAntiWhitelist.origin.host")
                    .put("androidRuntime.cdnAntiWhitelist.origin.port")
                    .put("androidRuntime.cdnAntiWhitelist.origin.scheme")
                    .put("androidRuntime.cdnAntiWhitelist.origin.path"),
            )
            .put(
                "optionalFields",
                JSONArray()
                    .put("androidRuntime.cdnAntiWhitelist.provider")
                    .put("androidRuntime.cdnAntiWhitelist.frontPool[].tag")
                    .put("androidRuntime.cdnAntiWhitelist.frontSelection")
                    .put("androidRuntime.cdnAntiWhitelist.bootstrap")
                    .put("androidRuntime.cdnAntiWhitelist.routingPolicy.dnsQueryStrategy")
                    .put("androidRuntime.cdnAntiWhitelist.routingPolicy.domainStrategy")
                    .put("androidRuntime.cdnAntiWhitelist.routingPolicy.domainMatcher")
                    .put("androidRuntime.cdnAntiWhitelist.routingPolicy.directDomainKeywords[]")
                    .put("androidRuntime.cdnAntiWhitelist.routingPolicy.directDomains[]")
                    .put("androidRuntime.cdnAntiWhitelist.routingPolicy.blockedDomainKeywords[]")
                    .put("androidRuntime.cdnAntiWhitelist.routingPolicy.blockedDomains[]")
                    .put("androidRuntime.cdnAntiWhitelist.routingPolicy.blockSelectedFrontHost"),
            )
            .put(
                "gates",
                JSONArray()
                    .put("Keep direct-reality as the default family until this schema is validated on-device.")
                    .put("Do not widen invite/import until the owner-only hidden path survives blocked-direct validation.")
                    .put("Do not mix server rollout with stable REALITY listener changes."),
            )

    private fun buildCdnRolloutStages(): JSONArray =
        JSONArray()
            .put(
                JSONObject()
                    .put("id", "owner-lab-single-front")
                    .put("goal", "Validate one hidden whitelist front end-to-end with stable REALITY kept as the control lane.")
                    .put("gate", "Cold start, quick test, and blocked-direct survival must pass on one handset."),
            )
            .put(
                JSONObject()
                    .put("id", "owner-lab-front-pool")
                    .put("goal", "Validate ordered failover semantics across at least two hidden whitelist fronts.")
                    .put("gate", "Selected front metadata and path identity must remain stable across retries."),
            )
            .put(
                JSONObject()
                    .put("id", "always-on-lockdown")
                    .put("goal", "Exercise Always-on, Lockdown, and boot restore only after owner lab passes.")
                    .put("gate", "No regression is allowed on the stable direct-reality control sample."),
            )
            .put(
                JSONObject()
                    .put("id", "owner-rollout")
                    .put("goal", "Broader owner-only rollout behind hidden preset gating.")
                    .put("gate", "No invite/import widening before blocked-direct and restore behavior are confirmed."),
            )

    private fun buildCdnDeviceValidationMatrix(options: CdnAntiWhitelistRuntimeOptions): JSONArray =
        JSONArray()
            .put(
                JSONObject()
                    .put("id", "startup-control")
                    .put("phase", "owner-lab-single-front")
                    .put("required", true)
                    .put("expectedFront", options.frontHost)
                    .put("check", "Cold start with hidden whitelist-front preset should select the expected front and emit scaffold diagnostics."),
            )
            .put(
                JSONObject()
                    .put("id", "quick-test")
                    .put("phase", "owner-lab-single-front")
                    .put("required", true)
                    .put("check", "Quick test and runtime log should show the selected front metadata and the correct activation family."),
            )
            .put(
                JSONObject()
                    .put("id", "wifi-lte-handoff")
                    .put("phase", "owner-lab-single-front")
                    .put("required", true)
                    .put("check", "Wi-Fi to LTE and LTE to Wi-Fi should preserve the chosen front identity or fail clearly without touching the stable family."),
            )
            .put(
                JSONObject()
                    .put("id", "blocked-direct-front-survival")
                    .put("phase", "owner-lab-single-front")
                    .put("required", true)
                    .put("check", "When direct paths are blocked, the whitelist-front lane should remain reachable while direct-reality stays as the control sample."),
            )
            .put(
                JSONObject()
                    .put("id", "front-pool-retry")
                    .put("phase", "owner-lab-front-pool")
                    .put("required", true)
                    .put("check", "Ordered front-pool retries should move predictably and remain observable in diagnostics."),
            )
            .put(
                JSONObject()
                    .put("id", "always-on")
                    .put("phase", "always-on-lockdown")
                    .put("required", false)
                    .put("check", "Always-on should be attempted only after startup, handoff, and blocked-direct checks pass."),
            )
            .put(
                JSONObject()
                    .put("id", "lockdown")
                    .put("phase", "always-on-lockdown")
                    .put("required", false)
                    .put("check", "Lockdown should be treated as a separate gate after owner-lab stability is proven."),
            )
            .put(
                JSONObject()
                    .put("id", "boot-restore")
                    .put("phase", "always-on-lockdown")
                    .put("required", false)
                    .put("check", "Boot restore should stay off until the whitelist-front lane is proven under repeated cold starts."),
            )

    private fun buildCdnBlockedDirectValidationPlan(options: CdnAntiWhitelistRuntimeOptions): JSONObject =
        JSONObject()
            .put("frontHost", options.frontHost)
            .put("frontPort", options.frontPort)
            .put("connectHost", options.connectHost)
            .put("connectPort", options.connectPort)
            .put("originHost", options.originHost)
            .put("originPort", options.originPort)
            .put(
                "controlLane",
                JSONObject()
                    .put("family", RUNTIME_FAMILY_DIRECT_REALITY)
                    .put("role", "stable-control-sample"),
            )
            .put(
                "candidateLane",
                JSONObject()
                    .put("family", RUNTIME_FAMILY_CDN_ANTI_WHITELIST)
                    .put("role", "hidden-whitelist-front"),
            )
            .put(
                "expectedSignals",
                JSONArray()
                    .put("The selected front host remains reachable from a whitelist-restricted network.")
                    .put("The candidate lane exposes front metadata that matches the intended preset.")
                    .put("The future active lane must keep local-service direct rules and anti-loop blocking observable in diagnostics before broader rollout.")
                    .put("The stable control lane remains available and testable before and after the blocked-direct run."),
            )
            .put(
                "captureChecklist",
                JSONArray()
                    .put("Persist the exact hidden profile block used for the run.")
                    .put("Persist the hidden routingPolicy block used for the run, including direct and blocked surface lists.")
                    .put("Save the generated cdn-anti-whitelist scaffold file.")
                    .put("Capture runtime prefs and filtered logcat through the Android device dump helper."),
            )

    private fun buildRealityWhitelistAssistedScaffoldDocument(
        serverHost: String,
        reality: RealitySettings,
        baseOptions: RealityRuntimeOptions,
        options: RealityWhitelistHintRuntimeOptions,
    ): String =
        JSONObject()
            .put("kind", "odin-one-android-reality-whitelist-assisted-scaffold")
            .put("runtimeFamily", RUNTIME_FAMILY_REALITY_WHITELIST_ASSISTED)
            .put("activationState", options.activationState)
            .put("configMode", options.mode)
            .put("serverHost", serverHost)
            .put("bootstrap", options.bootstrap)
            .put("hintSelection", options.selection)
            .put("hintPoolSize", options.hintPoolSize)
            .put(
                "selectedHint",
                JSONObject()
                    .put("serverName", options.selectedSniHint)
                    .put("cidrBucket", options.selectedCidrHint)
                    .put("source", options.whitelistHintSource)
                    .put("tag", options.whitelistHintTag),
            ).put(
                "hintPool",
                JSONArray().apply {
                    options.hintPool.forEach { candidate ->
                        put(
                            JSONObject()
                                .put("serverName", candidate.serverName)
                                .put("cidrBucket", candidate.cidrBucket)
                                .put("source", candidate.source)
                                .put("tag", candidate.tag),
                        )
                    }
                },
            ).put(
                "targetShape",
                JSONObject()
                    .put("protocol", "vless")
                    .put("transport", "reality")
                    .put("assistModel", "operator-curated-whitelist-hints"),
            ).put(
                "bootstrapReality",
                JSONObject()
                    .put("serverHost", reality.serverHost)
                    .put("serverPort", reality.serverPort)
                    .put("serverName", reality.serverName)
                    .put("flow", reality.flow),
            ).put(
                "baseRealityPlan",
                JSONObject()
                    .put("mode", baseOptions.mode)
                    .put("dnsMode", baseOptions.dnsMode)
                    .put("dnsServer", baseOptions.dnsServer)
                    .put("dnsServerName", baseOptions.dnsServerName)
                    .put("dnsStrategy", baseOptions.dnsStrategy)
                    .put("strictRoute", baseOptions.strictRoute)
                    .put("tlsFragment", baseOptions.tlsFragment)
                    .put("recordFragment", baseOptions.recordFragment)
                    .put("networkReloadOnChange", baseOptions.networkReloadOnChange)
                    .put("networkReloadDebounceMs", baseOptions.networkReloadDebounceMs)
                    .put("allowPrivateNetworkBypass", baseOptions.allowPrivateNetworkBypass)
                    .put("privateBypassCidrs", JSONArray(baseOptions.privateBypassCidrs))
                    .put("includePackages", JSONArray(baseOptions.includePackages))
                    .put("excludePackages", JSONArray(baseOptions.excludePackages)),
            ).put("clientBuilderSpec", buildRealityWhitelistClientBuilderSpec(options))
            .put("serverProfileSchema", buildRealityWhitelistServerProfileSchema())
            .put("rolloutStages", buildRealityWhitelistRolloutStages())
            .put("deviceValidationMatrix", buildRealityWhitelistDeviceValidationMatrix(options))
            .put("blockedDirectValidationPlan", buildRealityWhitelistBlockedDirectValidationPlan(options))
            .put(
                "rolloutGuardrails",
                JSONArray()
                    .put("Keep direct-reality as the default Android family.")
                    .put("Treat this as a hidden operator-curated hint lane, not as a replacement for stable REALITY.")
                    .put("Do not widen invite/import until one owner-only hint survives blocked-direct handset validation."),
            ).put(
                "notes",
                JSONArray()
                    .put("This file is a scaffold plan, not an active libbox config.")
                    .put("The goal is to preserve the stable REALITY transport while curating whitelist-friendly SNI and CIDR hints for Russian clients.")
                    .put("Selected hint metadata must stay observable in Android diagnostics and capture tooling."),
            ).toString(2)

    private fun buildRealityWhitelistClientBuilderSpec(options: RealityWhitelistHintRuntimeOptions): JSONObject =
        JSONObject()
            .put("targetRuntimeFamily", RUNTIME_FAMILY_REALITY_WHITELIST_ASSISTED)
            .put("engine", "sing-box")
            .put("protocol", "vless")
            .put("transport", "reality")
            .put("bootstrapFamily", options.bootstrap)
            .put(
                "bindings",
                JSONObject()
                    .put("selectedSniHint", options.selectedSniHint)
                    .put("selectedCidrHint", options.selectedCidrHint)
                    .put("whitelistHintSource", options.whitelistHintSource)
                    .put("whitelistHintTag", options.whitelistHintTag),
            ).put(
                "outboundTemplate",
                JSONObject()
                    .put("type", "vless")
                    .put("server", "\$serverHost")
                    .put("server_port", "\$profile.stagedFallbacks.vlessReality.port")
                    .put("uuid", "\$profile.stagedFallbacks.vlessReality.uuid")
                    .put("flow", "\$profile.stagedFallbacks.vlessReality.flow")
                    .put(
                        "tls",
                        JSONObject()
                            .put("enabled", true)
                            .put("server_name", "\$selectedSniHint")
                            .put(
                                "utls",
                                JSONObject()
                                    .put("enabled", true)
                                    .put("fingerprint", "chrome"),
                            ).put(
                                "reality",
                                JSONObject()
                                    .put("enabled", true)
                                    .put("public_key", "\$profile.stagedFallbacks.vlessReality.publicKey")
                                    .put("short_id", "\$profile.stagedFallbacks.vlessReality.shortId"),
                            ),
                    ),
            ).put(
                "notes",
                JSONArray()
                    .put("This is a future activation template, not a live runtime config.")
                    .put("Keep this family additive and hidden until operator-curated hints survive blocked-direct validation."),
            )

    private fun buildRealityWhitelistServerProfileSchema(): JSONObject =
        JSONObject()
            .put("kind", "odin-one-reality-whitelist-assisted-profile-v1")
            .put(
                "requiredFields",
                JSONArray()
                    .put("androidRuntime.realityWhitelistHints.hints[].serverName"),
            ).put(
                "optionalFields",
                JSONArray()
                    .put("androidRuntime.realityWhitelistHints.hints[].cidrBucket")
                    .put("androidRuntime.realityWhitelistHints.hints[].source")
                    .put("androidRuntime.realityWhitelistHints.hints[].tag")
                    .put("androidRuntime.realityWhitelistHints.selection")
                    .put("androidRuntime.realityWhitelistHints.bootstrap"),
            ).put(
                "gates",
                JSONArray()
                    .put("Keep stable REALITY as the default lane.")
                    .put("Treat curated SNI/CIDR hints as owner-only operator data until validated on-device.")
                    .put("Do not widen invite/import before the hint lane has a clean handset runbook."),
            )

    private fun buildRealityWhitelistRolloutStages(): JSONArray =
        JSONArray()
            .put(
                JSONObject()
                    .put("id", "operator-curation")
                    .put("goal", "Collect and curate one hidden SNI/CIDR hint candidate alongside the stable REALITY control lane.")
                    .put("gate", "The hint metadata must remain additive and must not change the default stable family."),
            ).put(
                JSONObject()
                    .put("id", "owner-lab-single-hint")
                    .put("goal", "Validate one curated hint on a handset while preserving the stable control sample.")
                    .put("gate", "Startup, quick test, and blocked-direct checks must be captured with compare/report tooling."),
            ).put(
                JSONObject()
                    .put("id", "operator-rotation")
                    .put("goal", "Exercise ordered hint rotation and operator refresh workflow.")
                    .put("gate", "Selected hint metadata must remain observable and rollback must be trivial."),
            ).put(
                JSONObject()
                    .put("id", "always-on-lockdown")
                    .put("goal", "Consider Always-on, Lockdown, and boot restore only after owner-lab validation passes.")
                    .put("gate", "No regression is allowed on the stable direct-reality control sample."),
            )

    private fun buildRealityWhitelistDeviceValidationMatrix(options: RealityWhitelistHintRuntimeOptions): JSONArray =
        JSONArray()
            .put(
                JSONObject()
                    .put("id", "startup-control")
                    .put("phase", "owner-lab-single-hint")
                    .put("required", true)
                    .put("expectedSniHint", options.selectedSniHint)
                    .put("check", "Cold start should surface the curated SNI hint and keep direct-reality available as the control lane."),
            ).put(
                JSONObject()
                    .put("id", "quick-test")
                    .put("phase", "owner-lab-single-hint")
                    .put("required", true)
                    .put("check", "Quick test and runtime log should record the selected whitelist hint metadata."),
            ).put(
                JSONObject()
                    .put("id", "blocked-direct-survival")
                    .put("phase", "owner-lab-single-hint")
                    .put("required", true)
                    .put("check", "Blocked-direct validation should confirm whether the curated hint survives without touching the stable control lane."),
            ).put(
                JSONObject()
                    .put("id", "hint-rotation")
                    .put("phase", "operator-rotation")
                    .put("required", true)
                    .put("check", "Ordered hint rotation should move predictably and remain visible in diagnostics."),
            ).put(
                JSONObject()
                    .put("id", "always-on")
                    .put("phase", "always-on-lockdown")
                    .put("required", false)
                    .put("check", "Always-on should stay out of scope until hint validation is repeatable."),
            )

    private fun buildRealityWhitelistBlockedDirectValidationPlan(options: RealityWhitelistHintRuntimeOptions): JSONObject =
        JSONObject()
            .put(
                "controlLane",
                JSONObject()
                    .put("family", RUNTIME_FAMILY_DIRECT_REALITY)
                    .put("role", "stable-control-sample"),
            ).put(
                "candidateLane",
                JSONObject()
                    .put("family", RUNTIME_FAMILY_REALITY_WHITELIST_ASSISTED)
                    .put("role", "hidden-operator-curated-hint"),
            ).put(
                "selectedHint",
                JSONObject()
                    .put("serverName", options.selectedSniHint)
                    .put("cidrBucket", options.selectedCidrHint)
                    .put("source", options.whitelistHintSource)
                    .put("tag", options.whitelistHintTag),
            ).put(
                "expectedSignals",
                JSONArray()
                    .put("The candidate lane exposes the curated SNI and CIDR hint metadata that matches the hidden preset.")
                    .put("The stable control lane remains available and testable before and after the candidate run.")
                    .put("Operator notes capture whether the selected hint was actually reachable from the blocked-direct network."),
            ).put(
                "captureChecklist",
                JSONArray()
                    .put("Persist the exact hidden realityWhitelistHints block used for the run.")
                    .put("Save the generated reality-whitelist-assisted scaffold file.")
                    .put("Capture runtime prefs and filtered logcat through the Android device dump helper."),
            )

    private fun buildRealityVpsLabScaffoldDocument(
        serverHost: String,
        reality: RealitySettings,
        baseOptions: RealityRuntimeOptions,
        options: RealityVpsLabRuntimeOptions,
    ): String =
        JSONObject()
            .put("kind", "odin-one-android-reality-vps-lab-scaffold")
            .put("runtimeFamily", RUNTIME_FAMILY_REALITY_VPS_LAB)
            .put("activationState", options.activationState)
            .put("configMode", options.mode)
            .put("serverHost", serverHost)
            .put("ownerRealityEgress", options.ownerRealityEgress)
            .put(
                "selectedEndpoint",
                JSONObject()
                    .put("serverName", options.serverName)
                    .put("port", options.serverPort)
                    .put("connectHost", options.connectHost)
                    .put("connectPort", options.connectPort)
                    .put("transport", options.transport)
                    .put("fingerprint", options.fingerprint)
                    .put("flow", options.flow)
                    .put("grpcServiceName", options.grpcServiceName)
                    .put("grpcAuthority", options.grpcAuthority)
                    .put("source", options.source)
                    .put("tag", options.tag),
            ).put(
                "bootstrapReality",
                JSONObject()
                    .put("serverHost", reality.serverHost)
                    .put("serverPort", reality.serverPort)
                    .put("serverName", reality.serverName)
                    .put("flow", reality.flow),
            ).put(
                "baseRuntime",
                JSONObject()
                    .put("dnsMode", baseOptions.dnsMode)
                    .put("dnsServer", baseOptions.dnsServer)
                    .put("dnsStrategy", baseOptions.dnsStrategy)
                    .put("strictRoute", baseOptions.strictRoute)
                    .put("networkReloadOnChange", baseOptions.networkReloadOnChange)
                    .put("networkReloadDebounceMs", baseOptions.networkReloadDebounceMs),
            ).put(
                "clientPlan",
                JSONObject()
                    .put("protocol", "vless")
                    .put("security", "reality")
                    .put("transport", options.transport)
                    .put("serverHost", serverHost)
                    .put("serverPort", options.serverPort)
                    .put("serverName", options.serverName)
                    .put("fingerprint", options.fingerprint)
                    .put("flow", options.flow)
                    .put("grpcServiceName", options.grpcServiceName)
                    .put("grpcAuthority", options.grpcAuthority),
            ).put(
                "notes",
                JSONArray()
                    .put("This file is a scaffold plan for the owner-only VPS REALITY lab path.")
                    .put("The active lab config should match the proven isolated smoke shape for the same endpoint.")
                    .put("Keep direct-reality on 443 as the stable default while validating these additive lab ports."),
            ).toString(2)

    private fun buildRealityDnsServer(
        options: RealityRuntimeOptions,
        detour: String,
    ): JSONObject =
        when (options.dnsMode) {
            REALITY_DNS_MODE_DOH ->
                JSONObject()
                    .put("tag", "resolver")
                    .put("type", "https")
                    .put("server", options.dnsServer)
                    .put("server_port", options.dnsServerPort ?: 443)
                    .put("path", options.dnsDohPath)
                    .put("detour", detour)
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
                    .put("detour", detour)
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
                    .put("detour", detour)
        }

    private fun isCdnAntiWhitelistEnabled(profile: JSObject): Boolean {
        val options =
            profile.optJSONObject("androidRuntime")?.optJSONObject("cdnAntiWhitelist")
                ?: profile.optJSONObject("runtimeOptions")?.optJSONObject("cdnAntiWhitelist")
                ?: profile.optJSONObject("androidCdnAntiWhitelist")
                ?: return false
        return options.optBoolean("enabled", false)
    }

    private fun isRealityWhitelistHintsEnabled(profile: JSObject): Boolean {
        val options =
            profile.optJSONObject("androidRuntime")?.optJSONObject("realityWhitelistHints")
                ?: profile.optJSONObject("runtimeOptions")?.optJSONObject("realityWhitelistHints")
                ?: profile.optJSONObject("androidRealityWhitelistHints")
                ?: return false
        return options.optBoolean("enabled", false)
    }

    private fun isRealityVpsLabEnabled(profile: JSObject): Boolean {
        val options =
            profile.optJSONObject("androidRuntime")?.optJSONObject("realityVpsLab")
                ?: profile.optJSONObject("runtimeOptions")?.optJSONObject("realityVpsLab")
                ?: return false
        return options.optBoolean("enabled", false)
    }

    private fun readCdnAntiWhitelistRuntimeOptions(
        args: JSObject,
        profile: JSObject,
        serverHost: String,
    ): CdnAntiWhitelistRuntimeOptions {
        val profileOptions =
            profile.optJSONObject("androidRuntime")?.optJSONObject("cdnAntiWhitelist")
                ?: profile.optJSONObject("runtimeOptions")?.optJSONObject("cdnAntiWhitelist")
                ?: profile.optJSONObject("androidCdnAntiWhitelist")
                ?: JSONObject()
        val originOptions = profileOptions.optJSONObject("origin") ?: JSONObject()
        val defaultProvider =
            normalizeCdnProvider(
                args.getString("frontProvider", null)
                    ?.trim()
                    .takeUnless { it.isNullOrBlank() }
                    ?: args.getString("cdnProvider", null)
                        ?.trim()
                        .takeUnless { it.isNullOrBlank() }
                    ?: profileOptions.optString("provider").takeUnless { it.isNullOrBlank() }
                    ?: CDN_PROVIDER_GENERIC,
            )
        val mode =
            normalizeCdnMode(
                args.getString("configMode", null)
                    ?.trim()
                    .takeUnless { it.isNullOrBlank() }
                    ?: profileOptions.optString("mode").takeUnless { it.isNullOrBlank() }
                    ?: CDN_MODE_SCAFFOLD,
            )
        val transport =
            normalizeCdnTransport(
                args.getString("cdnTransport", null)
                    ?.trim()
                    .takeUnless { it.isNullOrBlank() }
                    ?: profileOptions.optString("transport").takeUnless { it.isNullOrBlank() }
                    ?: CDN_TRANSPORT_WEBSOCKET,
            )
        val xhttpOptions = profileOptions.optJSONObject("xhttp") ?: JSONObject()
        val xmuxOptions = profileOptions.optJSONObject("xmux") ?: JSONObject()
        val xhttpMode =
            normalizeCdnXhttpMode(
                args.getString("cdnXhttpMode", null)
                    ?.trim()
                    .takeUnless { it.isNullOrBlank() }
                    ?: profileOptions.optString("xhttpMode").takeUnless { it.isNullOrBlank() }
                    ?: xhttpOptions.optString("mode").takeUnless { it.isNullOrBlank() },
            )
        val tlsAlpn =
            readStringListOption(args, "cdnTlsAlpn", profileOptions, "tlsAlpn")
                .ifEmpty {
                    val profileArray = profileOptions.optJSONArray("tlsAlpn")
                    val xhttpArray = xhttpOptions.optJSONArray("alpn")
                    buildList {
                        val source = profileArray ?: xhttpArray
                        if (source != null) {
                            for (index in 0 until source.length()) {
                                source.optString(index)?.trim()?.takeIf { it.isNotEmpty() }?.let(::add)
                            }
                        }
                    }
                }.map { it.trim().lowercase(Locale.ROOT) }
                .filter { it.isNotBlank() }
                .distinct()
        val xmuxMaxConcurrency =
            normalizePositiveIntOption(
                when {
                    args.has("cdnXmuxMaxConcurrency") && !args.isNull("cdnXmuxMaxConcurrency") -> args.optInt("cdnXmuxMaxConcurrency")
                    profileOptions.has("xmuxMaxConcurrency") && !profileOptions.isNull("xmuxMaxConcurrency") -> profileOptions.optInt("xmuxMaxConcurrency")
                    xmuxOptions.has("maxConcurrency") && !xmuxOptions.isNull("maxConcurrency") -> xmuxOptions.optInt("maxConcurrency")
                    else -> null
                },
            )
        val xmuxHMaxRequestTimes =
            normalizePositiveIntOption(
                when {
                    args.has("cdnXmuxHMaxRequestTimes") && !args.isNull("cdnXmuxHMaxRequestTimes") -> args.optInt("cdnXmuxHMaxRequestTimes")
                    profileOptions.has("xmuxHMaxRequestTimes") && !profileOptions.isNull("xmuxHMaxRequestTimes") -> profileOptions.optInt("xmuxHMaxRequestTimes")
                    xmuxOptions.has("hMaxRequestTimes") && !xmuxOptions.isNull("hMaxRequestTimes") -> xmuxOptions.optInt("hMaxRequestTimes")
                    else -> null
                },
            )
        val xmuxHMaxReusableSecs =
            normalizePositiveIntOption(
                when {
                    args.has("cdnXmuxHMaxReusableSecs") && !args.isNull("cdnXmuxHMaxReusableSecs") -> args.optInt("cdnXmuxHMaxReusableSecs")
                    profileOptions.has("xmuxHMaxReusableSecs") && !profileOptions.isNull("xmuxHMaxReusableSecs") -> profileOptions.optInt("xmuxHMaxReusableSecs")
                    xmuxOptions.has("hMaxReusableSecs") && !xmuxOptions.isNull("hMaxReusableSecs") -> xmuxOptions.optInt("hMaxReusableSecs")
                    else -> null
                },
            )
        val explicitFrontHost =
            args.getString("frontHost", null)
                ?.trim()
                .takeUnless { it.isNullOrBlank() }
                ?: args.getString("cdnFrontHost", null)
                    ?.trim()
                    .takeUnless { it.isNullOrBlank() }
                ?: profileOptions.optString("frontHost").takeUnless { it.isNullOrBlank() }
        val explicitFrontPort =
            normalizeCdnPort(
                when {
                    args.has("frontPort") && !args.isNull("frontPort") -> args.optInt("frontPort")
                    args.has("cdnFrontPort") && !args.isNull("cdnFrontPort") -> args.optInt("cdnFrontPort")
                    profileOptions.optInt("frontPort") > 0 -> profileOptions.optInt("frontPort")
                    else -> null
                },
                defaultPort = CDN_DEFAULT_FRONT_PORT,
            )
        val explicitFrontPath =
            normalizeHttpPath(
                args.getString("frontPath", null)
                    ?.trim()
                    .takeUnless { it.isNullOrBlank() }
                    ?: args.getString("cdnFrontPath", null)
                        ?.trim()
                        .takeUnless { it.isNullOrBlank() }
                    ?: profileOptions.optString("frontPath").takeUnless { it.isNullOrBlank() }
                    ?: CDN_DEFAULT_FRONT_PATH,
            )
        val explicitFrontTag =
            normalizeCdnFrontTag(
                args.getString("frontTag", null)
                    ?.trim()
                    .takeUnless { it.isNullOrBlank() }
                    ?: args.getString("cdnFrontTag", null)
                        ?.trim()
                        .takeUnless { it.isNullOrBlank() }
                    ?: profileOptions.optString("frontTag").takeUnless { it.isNullOrBlank() },
            )
        val explicitConnectHost =
            normalizeCdnConnectHost(
                args.getString("frontConnectHost", null)
                    ?.trim()
                    .takeUnless { it.isNullOrBlank() }
                    ?: args.getString("cdnConnectHost", null)
                        ?.trim()
                        .takeUnless { it.isNullOrBlank() }
                    ?: profileOptions.optString("connectHost").takeUnless { it.isNullOrBlank() }
                    ?: profileOptions.optString("dialHost").takeUnless { it.isNullOrBlank() }
                    ?: profileOptions.optString("serverHost").takeUnless { it.isNullOrBlank() }
                    ?: profileOptions.optString("address").takeUnless { it.isNullOrBlank() },
                explicitFrontHost,
                serverHost,
            )
        val explicitConnectPort =
            normalizeCdnConnectPort(
                when {
                    args.has("frontConnectPort") && !args.isNull("frontConnectPort") -> args.optInt("frontConnectPort")
                    args.has("cdnConnectPort") && !args.isNull("cdnConnectPort") -> args.optInt("cdnConnectPort")
                    profileOptions.optInt("connectPort") > 0 -> profileOptions.optInt("connectPort")
                    profileOptions.optInt("dialPort") > 0 -> profileOptions.optInt("dialPort")
                    profileOptions.optInt("serverPort") > 0 -> profileOptions.optInt("serverPort")
                    else -> null
                },
                explicitFrontPort,
            )
        val explicitTlsServerName =
            normalizeCdnTlsServerName(
                args.getString("cdnTlsServerName", null)
                    ?.trim()
                    .takeUnless { it.isNullOrBlank() }
                    ?: profileOptions.optString("tlsServerName").takeUnless { it.isNullOrBlank() },
                explicitFrontHost,
            )
        val explicitTlsAllowInsecure =
            if (args.has("cdnTlsAllowInsecure") && !args.isNull("cdnTlsAllowInsecure")) {
                args.optBoolean("cdnTlsAllowInsecure", false)
            } else if (args.has("tlsAllowInsecure") && !args.isNull("tlsAllowInsecure")) {
                args.optBoolean("tlsAllowInsecure", false)
            } else {
                profileOptions.optBoolean("tlsAllowInsecure", profileOptions.optBoolean("allowInsecure", false))
            }
        val explicitHttpHostHeader =
            normalizeCdnHttpHostHeader(
                args.getString("cdnHttpHostHeader", null)
                    ?.trim()
                    .takeUnless { it.isNullOrBlank() }
                    ?: profileOptions.optString("hostHeader").takeUnless { it.isNullOrBlank() },
                explicitFrontHost,
                explicitTlsServerName,
            )
        val frontSelection =
            normalizeCdnFrontSelection(
                args.getString("cdnFrontSelection", null)
                    ?.trim()
                    .takeUnless { it.isNullOrBlank() }
                    ?: profileOptions.optString("frontSelection").takeUnless { it.isNullOrBlank() }
                    ?: CDN_FRONT_SELECTION_ORDERED,
            )
        val legacyFront =
            explicitFrontHost?.let { host ->
                CdnFrontCandidate(
                    host = host,
                    port = explicitFrontPort,
                    connectHost = explicitConnectHost,
                    connectPort = explicitConnectPort,
                    path = explicitFrontPath,
                    tlsServerName = explicitTlsServerName,
                    tlsAllowInsecure = explicitTlsAllowInsecure,
                    httpHostHeader = explicitHttpHostHeader,
                    provider = defaultProvider,
                    tag = explicitFrontTag,
                )
            }
        val configuredPool = readCdnFrontPool(profileOptions, defaultProvider)
        val frontPool =
            buildList {
                legacyFront?.let(::add)
                configuredPool.forEach { candidate ->
                    if (legacyFront == null || !sameCdnFrontCandidate(candidate, legacyFront)) {
                        add(candidate)
                    }
                }
                if (isEmpty()) {
                    add(
                        CdnFrontCandidate(
                            host = serverHost,
                            port = CDN_DEFAULT_FRONT_PORT,
                            connectHost = serverHost,
                            connectPort = CDN_DEFAULT_FRONT_PORT,
                            path = CDN_DEFAULT_FRONT_PATH,
                            tlsServerName = serverHost,
                            tlsAllowInsecure = false,
                            httpHostHeader = serverHost,
                            provider = defaultProvider,
                            tag = explicitFrontTag,
                        ),
                    )
                }
            }
        val selectedFront = selectCdnFrontCandidate(frontPool, frontSelection, explicitFrontTag)
        val safeXmuxMaxConcurrency =
            resolveSafeCdnXmuxMaxConcurrency(
                transport,
                selectedFront.port,
                xmuxMaxConcurrency,
            )
        val originHost =
            args.getString("originHost", null)
                ?.trim()
                .takeUnless { it.isNullOrBlank() }
                ?: args.getString("cdnOriginHost", null)
                ?.trim()
                .takeUnless { it.isNullOrBlank() }
                ?: originOptions.optString("host").takeUnless { it.isNullOrBlank() }
                ?: profileOptions.optString("originHost").takeUnless { it.isNullOrBlank() }
                ?: serverHost
        val originPort =
            normalizeCdnPort(
                when {
                    args.has("originPort") && !args.isNull("originPort") -> args.optInt("originPort")
                    args.has("cdnOriginPort") && !args.isNull("cdnOriginPort") -> args.optInt("cdnOriginPort")
                    originOptions.optInt("port") > 0 -> originOptions.optInt("port")
                    profileOptions.optInt("originPort") > 0 -> profileOptions.optInt("originPort")
                    else -> null
                },
                defaultPort = CDN_DEFAULT_ORIGIN_PORT,
            )
        val originScheme =
            normalizeCdnOriginScheme(
                args.getString("cdnOriginScheme", null)
                    ?.trim()
                    .takeUnless { it.isNullOrBlank() }
                    ?: originOptions.optString("scheme").takeUnless { it.isNullOrBlank() }
                    ?: profileOptions.optString("originScheme").takeUnless { it.isNullOrBlank() }
                    ?: CDN_ORIGIN_SCHEME_HTTPS,
            )
        val originPath =
            normalizeHttpPath(
                args.getString("cdnOriginPath", null)
                    ?.trim()
                    .takeUnless { it.isNullOrBlank() }
                    ?: originOptions.optString("path").takeUnless { it.isNullOrBlank() }
                    ?: profileOptions.optString("originPath").takeUnless { it.isNullOrBlank() }
                    ?: selectedFront.path,
            )
        val routingPolicy = readCdnRoutingPolicyOptions(args, profileOptions, selectedFront.host)
        return CdnAntiWhitelistRuntimeOptions(
            mode = mode,
            provider = selectedFront.provider,
            transport = transport,
            xhttpMode = xhttpMode,
            tlsAlpn = tlsAlpn,
            xmuxMaxConcurrency = safeXmuxMaxConcurrency,
            xmuxHMaxRequestTimes = xmuxHMaxRequestTimes,
            xmuxHMaxReusableSecs = xmuxHMaxReusableSecs,
            frontHost = selectedFront.host,
            frontPort = selectedFront.port,
            connectHost = selectedFront.connectHost,
            connectPort = selectedFront.connectPort,
            frontPath = selectedFront.path,
            tlsServerName = selectedFront.tlsServerName,
            tlsAllowInsecure = selectedFront.tlsAllowInsecure,
            httpHostHeader = selectedFront.httpHostHeader,
            originHost = originHost,
            originPort = originPort,
            originScheme = originScheme,
            originPath = originPath,
            frontTag = selectedFront.tag,
            frontSelection = frontSelection,
            frontPoolSize = frontPool.size,
            frontPool = frontPool,
            routingPolicy = routingPolicy,
            bootstrap =
                normalizeCdnBootstrap(
                    args.getString("cdnBootstrapMode", null)
                        ?.trim()
                        .takeUnless { it.isNullOrBlank() }
                        ?: profileOptions.optString("bootstrap").takeUnless { it.isNullOrBlank() }
                        ?: CDN_BOOTSTRAP_DIRECT_REALITY,
                ),
            activationState = resolveCdnActivationState(mode, transport),
        )
    }

    private fun readCdnRoutingPolicyOptions(
        args: JSObject,
        profileOptions: JSONObject,
        selectedFrontHost: String,
    ): CdnRoutingPolicyOptions {
        val routingPolicy = profileOptions.optJSONObject("routingPolicy") ?: JSONObject()
        val dnsQueryStrategy =
            normalizeCdnRoutingDnsQueryStrategy(
                args.getString("cdnRoutingDnsQueryStrategy", null)
                    ?.trim()
                    .takeUnless { it.isNullOrBlank() }
                    ?: routingPolicy.optString("dnsQueryStrategy").takeUnless { it.isNullOrBlank() },
            )
        val domainStrategy =
            normalizeCdnRoutingDomainStrategy(
                args.getString("cdnRoutingDomainStrategy", null)
                    ?.trim()
                    .takeUnless { it.isNullOrBlank() }
                    ?: routingPolicy.optString("domainStrategy").takeUnless { it.isNullOrBlank() },
            )
        val domainMatcher =
            normalizeCdnRoutingDomainMatcher(
                args.getString("cdnRoutingDomainMatcher", null)
                    ?.trim()
                    .takeUnless { it.isNullOrBlank() }
                    ?: routingPolicy.optString("domainMatcher").takeUnless { it.isNullOrBlank() },
            )
        val directDomainKeywords =
            readStringListOption(args, "cdnRoutingDirectDomainKeywords", routingPolicy, "directDomainKeywords")
                .mapNotNull(::normalizeCdnRoutingKeyword)
                .distinct()
        val directDomains =
            readStringListOption(args, "cdnRoutingDirectDomains", routingPolicy, "directDomains")
                .mapNotNull(::normalizeCdnRoutingDomain)
                .distinct()
        val blockedDomainKeywords =
            readStringListOption(args, "cdnRoutingBlockedDomainKeywords", routingPolicy, "blockedDomainKeywords")
                .mapNotNull(::normalizeCdnRoutingKeyword)
                .distinct()
        val blockedDomains =
            readStringListOption(args, "cdnRoutingBlockedDomains", routingPolicy, "blockedDomains")
                .mapNotNull(::normalizeCdnRoutingDomain)
                .filterNot { it == selectedFrontHost.lowercase(Locale.ROOT) }
                .distinct()
        val blockSelectedFrontHost =
            if (args.has("cdnRoutingBlockSelectedFrontHost") && !args.isNull("cdnRoutingBlockSelectedFrontHost")) {
                args.optBoolean("cdnRoutingBlockSelectedFrontHost", false)
            } else {
                routingPolicy.optBoolean("blockSelectedFrontHost", routingPolicy.optBoolean("blockFrontHost", false))
            }
        return CdnRoutingPolicyOptions(
            dnsQueryStrategy = dnsQueryStrategy,
            domainStrategy = domainStrategy,
            domainMatcher = domainMatcher,
            directDomainKeywords = directDomainKeywords,
            directDomains = directDomains,
            blockedDomainKeywords = blockedDomainKeywords,
            blockedDomains = blockedDomains,
            blockSelectedFrontHost = blockSelectedFrontHost,
        )
    }

    private fun readCdnFrontPool(
        profileOptions: JSONObject,
        defaultProvider: String,
    ): List<CdnFrontCandidate> {
        val pool = profileOptions.optJSONArray("frontPool") ?: return emptyList()
        return buildList {
            for (index in 0 until pool.length()) {
                val entry = pool.optJSONObject(index) ?: continue
                val host =
                    entry.optString("host")
                        .ifBlank { entry.optString("frontHost") }
                        .trim()
                if (host.isBlank()) {
                    continue
                }
                add(
                    CdnFrontCandidate(
                        host = host,
                        port =
                            normalizeCdnPort(
                                entry.optInt("port").takeIf { it > 0 },
                                defaultPort = CDN_DEFAULT_FRONT_PORT,
                            ),
                        connectHost =
                            normalizeCdnConnectHost(
                                entry.optString("connectHost").takeUnless { it.isBlank() }
                                    ?: entry.optString("dialHost").takeUnless { it.isBlank() }
                                    ?: entry.optString("serverHost").takeUnless { it.isBlank() }
                                    ?: entry.optString("address").takeUnless { it.isBlank() }
                                    ?: entry.optString("server").takeUnless { it.isBlank() },
                                host,
                                host,
                            ),
                        connectPort =
                            normalizeCdnConnectPort(
                                entry.optInt("connectPort").takeIf { it > 0 }
                                    ?: entry.optInt("dialPort").takeIf { it > 0 }
                                    ?: entry.optInt("serverPort").takeIf { it > 0 },
                                normalizeCdnPort(
                                    entry.optInt("port").takeIf { it > 0 },
                                    defaultPort = CDN_DEFAULT_FRONT_PORT,
                                ),
                            ),
                        path =
                            normalizeHttpPath(
                                entry.optString("path")
                                    .ifBlank { entry.optString("frontPath") }
                                    .takeUnless { it.isBlank() }
                                    ?: CDN_DEFAULT_FRONT_PATH,
                            ),
                        tlsServerName =
                            normalizeCdnTlsServerName(
                                entry.optString("tlsServerName").takeUnless { it.isBlank() },
                                host,
                            ),
                        tlsAllowInsecure =
                            entry.optBoolean("tlsAllowInsecure", entry.optBoolean("allowInsecure", false)),
                        httpHostHeader =
                            normalizeCdnHttpHostHeader(
                                entry.optString("hostHeader").takeUnless { it.isBlank() },
                                host,
                                entry.optString("tlsServerName").takeUnless { it.isBlank() } ?: host,
                            ),
                        provider =
                            normalizeCdnProvider(
                                entry.optString("provider")
                                    .takeUnless { it.isBlank() }
                                    ?: defaultProvider,
                            ),
                        tag =
                            normalizeCdnFrontTag(
                                entry.optString("tag")
                                    .ifBlank { entry.optString("frontTag") }
                                    .takeUnless { it.isBlank() },
                            ),
                    ),
                )
            }
        }
    }

    private fun selectCdnFrontCandidate(
        frontPool: List<CdnFrontCandidate>,
        selection: String,
        preferredTag: String? = null,
    ): CdnFrontCandidate {
        val preferred =
            preferredTag
                ?.trim()
                ?.takeIf { it.isNotEmpty() }
                ?.let { requested ->
                    frontPool.firstOrNull { candidate ->
                        candidate.tag?.trim()?.equals(requested, ignoreCase = true) == true
                    }
                }
        if (preferred != null) {
            return preferred
        }
        return when (selection) {
            CDN_FRONT_SELECTION_ORDERED -> frontPool.first()
            else -> frontPool.first()
        }
    }

    private fun normalizeCdnFrontSelection(raw: String?): String =
        when (raw?.trim()?.lowercase(Locale.ROOT)) {
            CDN_FRONT_SELECTION_ORDERED -> CDN_FRONT_SELECTION_ORDERED
            else -> CDN_FRONT_SELECTION_ORDERED
        }

    private fun normalizeCdnFrontTag(raw: String?): String? =
        raw?.trim()?.takeIf { it.isNotEmpty() }

    fun advanceCdnFrontOverrideForRetry(args: JSObject): JSObject {
        val normalized = normalizeRuntimeArgs(args)
        if (normalized.getString("runtimeFamily", null)?.trim() != RUNTIME_FAMILY_CDN_ANTI_WHITELIST) {
            return normalized
        }
        val rawProfile = normalized.getString("profileJson", "{}") ?: "{}"
        val profile = runCatching { JSObject(rawProfile) }.getOrElse { return normalized }
        val options =
            readCdnAntiWhitelistRuntimeOptions(
                normalized,
                profile,
                normalized.getString("serverHost", "")?.trim().orEmpty(),
            )
        if (options.frontPool.size <= 1) {
            return normalized
        }
        val currentIndex =
            options.frontPool.indexOfFirst { candidate ->
                when {
                    !options.frontTag.isNullOrBlank() && !candidate.tag.isNullOrBlank() ->
                        candidate.tag.equals(options.frontTag, ignoreCase = true)
                    else ->
                        candidate.host.equals(options.frontHost, ignoreCase = true) &&
                            candidate.port == options.frontPort &&
                            candidate.tlsServerName.equals(options.tlsServerName, ignoreCase = true)
                }
            }
        val nextIndex = if (currentIndex >= 0) (currentIndex + 1) % options.frontPool.size else 1 % options.frontPool.size
        val nextFront = options.frontPool[nextIndex]
        return JSObject(normalized.toString()).apply {
            put("frontTag", nextFront.tag)
            put("cdnFrontTag", nextFront.tag)
            put("frontHost", nextFront.host)
            put("cdnFrontHost", nextFront.host)
            put("frontConnectHost", nextFront.connectHost)
            put("cdnConnectHost", nextFront.connectHost)
            put("frontConnectPort", nextFront.connectPort)
            put("cdnConnectPort", nextFront.connectPort)
            put("frontPath", nextFront.path)
            put("cdnFrontPath", nextFront.path)
            put("frontProvider", nextFront.provider)
            put("cdnProvider", nextFront.provider)
            put("cdnTlsServerName", nextFront.tlsServerName)
            put("cdnTlsAllowInsecure", nextFront.tlsAllowInsecure)
            put("cdnHttpHostHeader", nextFront.httpHostHeader)
        }
    }

    private fun normalizeRealityWhitelistMode(value: String?): String =
        when (value?.trim()?.lowercase(Locale.ROOT)) {
            REALITY_WHITELIST_MODE_LAB -> REALITY_WHITELIST_MODE_LAB
            else -> REALITY_WHITELIST_MODE_SCAFFOLD
        }

    private fun normalizeRealityWhitelistSelection(value: String?): String =
        when (value?.trim()?.lowercase(Locale.ROOT)) {
            REALITY_WHITELIST_SELECTION_ORDERED -> REALITY_WHITELIST_SELECTION_ORDERED
            REALITY_WHITELIST_SELECTION_SOURCE_ROUND_ROBIN,
            "source_round_robin",
            "round-robin-source" -> REALITY_WHITELIST_SELECTION_SOURCE_ROUND_ROBIN
            else -> REALITY_WHITELIST_SELECTION_ORDERED
        }

    private fun normalizeRealityWhitelistBootstrap(value: String?): String =
        when (value?.trim()?.lowercase(Locale.ROOT)) {
            CDN_BOOTSTRAP_DIRECT_REALITY -> CDN_BOOTSTRAP_DIRECT_REALITY
            else -> CDN_BOOTSTRAP_DIRECT_REALITY
        }

    private fun resolveRealityWhitelistActivationState(mode: String): String =
        when (mode) {
            REALITY_WHITELIST_MODE_LAB -> ACTIVATION_STATE_ACTIVE
            REALITY_WHITELIST_MODE_SCAFFOLD -> ACTIVATION_STATE_SCAFFOLD_ONLY
            else -> ACTIVATION_STATE_SCAFFOLD_ONLY
        }

    private fun normalizeRealityWhitelistServerName(
        rawValue: String?,
        fallbackServerName: String,
    ): String =
        rawValue?.trim()?.takeIf { it.isNotEmpty() }
            ?: fallbackServerName.trim().ifBlank { "example.com" }

    private fun normalizeRealityWhitelistHintValue(rawValue: String?): String? =
        rawValue
            ?.trim()
            ?.takeUnless { it.isEmpty() || it.equals("null", ignoreCase = true) }

    private fun sameCdnFrontCandidate(
        left: CdnFrontCandidate,
        right: CdnFrontCandidate,
    ): Boolean =
        left.host.equals(right.host, ignoreCase = true) &&
            left.port == right.port &&
            left.connectHost.equals(right.connectHost, ignoreCase = true) &&
        left.connectPort == right.connectPort &&
            left.path == right.path &&
            left.tlsServerName == right.tlsServerName &&
            left.tlsAllowInsecure == right.tlsAllowInsecure &&
            left.httpHostHeader == right.httpHostHeader &&
            left.provider == right.provider &&
            left.tag == right.tag

    private fun normalizeRealityVpsLabMode(rawValue: String?): String =
        when (rawValue?.trim()?.lowercase(Locale.ROOT)) {
            REALITY_VPS_LAB_MODE_LAB -> REALITY_VPS_LAB_MODE_LAB
            else -> REALITY_VPS_LAB_MODE_SCAFFOLD
        }

    private fun normalizeRealityVpsLabTransport(rawValue: String?): String =
        when (rawValue?.trim()?.lowercase(Locale.ROOT)) {
            REALITY_VPS_LAB_TRANSPORT_GRPC -> REALITY_VPS_LAB_TRANSPORT_GRPC
            else -> REALITY_VPS_LAB_TRANSPORT_TCP
        }

    private fun resolveRealityVpsLabActivationState(mode: String): String =
        if (mode == REALITY_VPS_LAB_MODE_LAB) ACTIVATION_STATE_ACTIVE else ACTIVATION_STATE_SCAFFOLD_ONLY

    private fun normalizeRealityVpsLabFingerprint(
        rawValue: String?,
        transport: String,
    ): String =
        rawValue?.trim()?.takeIf { it.isNotEmpty() }
            ?: if (transport == REALITY_VPS_LAB_TRANSPORT_GRPC) {
                REALITY_VPS_LAB_FINGERPRINT_FIREFOX
            } else {
                REALITY_VPS_LAB_FINGERPRINT_CHROME
            }

    private fun readRealityVpsLabRuntimeOptions(
        args: JSObject,
        profile: JSObject,
        reality: RealitySettings,
    ): RealityVpsLabRuntimeOptions {
        val profileOptions =
            profile.optJSONObject("androidRuntime")?.optJSONObject("realityVpsLab")
                ?: profile.optJSONObject("runtimeOptions")?.optJSONObject("realityVpsLab")
                ?: JSONObject()
        val mode =
            normalizeRealityVpsLabMode(
                args.getString("configMode", null)
                    ?.trim()
                    .takeUnless { it.isNullOrBlank() }
                    ?: profileOptions.optString("mode").takeUnless { it.isNullOrBlank() }
                    ?: REALITY_VPS_LAB_MODE_SCAFFOLD,
            )
        val transport =
            normalizeRealityVpsLabTransport(
                args.getString("vpsRealityTransport", null)
                    ?.trim()
                    .takeUnless { it.isNullOrBlank() }
                    ?: profileOptions.optString("transport").takeUnless { it.isNullOrBlank() }
                    ?: REALITY_VPS_LAB_TRANSPORT_TCP,
            )
        val serverName =
            normalizeRealityWhitelistServerName(
                args.getString("selectedSniHint", null)
                    ?.trim()
                    .takeUnless { it.isNullOrBlank() }
                    ?: profileOptions.optString("serverName").takeUnless { it.isNullOrBlank() },
                reality.serverName,
            )
        val serverPort =
            when {
                args.has("vpsRealityPort") && !args.isNull("vpsRealityPort") -> args.optInt("vpsRealityPort", reality.serverPort)
                profileOptions.optInt("port") > 0 -> profileOptions.optInt("port")
                else -> reality.serverPort
            }.coerceAtLeast(1)
        val connectHost =
            normalizeRealityWhitelistServerName(
                args.getString("vpsRealityConnectHost", null)
                    ?.trim()
                    .takeUnless { it.isNullOrBlank() }
                    ?: profileOptions.optString("connectHost").takeUnless { it.isNullOrBlank() },
                reality.serverHost,
            )
        val connectPort =
            when {
                args.has("vpsRealityConnectPort") && !args.isNull("vpsRealityConnectPort") -> args.optInt("vpsRealityConnectPort", serverPort)
                profileOptions.optInt("connectPort") > 0 -> profileOptions.optInt("connectPort")
                else -> serverPort
            }.coerceAtLeast(1)
        val flow =
            normalizeRealityWhitelistHintValue(
                args.getString("vpsRealityFlow", null)
                    ?.trim()
                    .takeUnless { it.isNullOrBlank() }
                    ?: profileOptions.optString("flow").takeUnless { it.isNullOrBlank() }
                    ?: if (transport == REALITY_VPS_LAB_TRANSPORT_TCP) {
                        reality.flow
                    } else {
                        null
                    },
            )
        val fingerprint =
            normalizeRealityVpsLabFingerprint(
                args.getString("vpsRealityFingerprint", null)
                    ?.trim()
                    .takeUnless { it.isNullOrBlank() }
                    ?: profileOptions.optString("fingerprint").takeUnless { it.isNullOrBlank() },
                transport,
            )
        val grpcServiceName =
            normalizeRealityWhitelistHintValue(
                args.getString("vpsRealityGrpcServiceName", null)
                    ?.trim()
                    .takeUnless { it.isNullOrBlank() }
                    ?: profileOptions.optString("grpcServiceName").takeUnless { it.isNullOrBlank() },
            )
        val grpcAuthority =
            normalizeRealityWhitelistHintValue(
                args.getString("vpsRealityGrpcAuthority", null)
                    ?.trim()
                    .takeUnless { it.isNullOrBlank() }
                    ?: profileOptions.optString("grpcAuthority").takeUnless { it.isNullOrBlank() },
            )
        val ownerRealityEgress =
            if (args.has("vpsRealityOwnerEgress") && !args.isNull("vpsRealityOwnerEgress")) {
                args.optBoolean("vpsRealityOwnerEgress", false)
            } else {
                profileOptions.optBoolean("ownerRealityEgress", false)
            }
        return RealityVpsLabRuntimeOptions(
            mode = mode,
            serverName = serverName,
            serverPort = serverPort,
            connectHost = connectHost,
            connectPort = connectPort,
            transport = transport,
            flow = if (transport == REALITY_VPS_LAB_TRANSPORT_GRPC) null else flow,
            fingerprint = fingerprint,
            grpcServiceName = if (transport == REALITY_VPS_LAB_TRANSPORT_GRPC) grpcServiceName else null,
            grpcAuthority = if (transport == REALITY_VPS_LAB_TRANSPORT_GRPC) grpcAuthority else null,
            source =
                normalizeRealityWhitelistHintValue(
                    args.getString("whitelistHintSource", null)
                        ?.trim()
                        .takeUnless { it.isNullOrBlank() }
                        ?: profileOptions.optString("source").takeUnless { it.isNullOrBlank() },
                ) ?: "operator-curated:vps-lab",
            tag =
                normalizeRealityWhitelistHintValue(
                    args.getString("whitelistHintTag", null)
                        ?.trim()
                        .takeUnless { it.isNullOrBlank() }
                        ?: profileOptions.optString("tag").takeUnless { it.isNullOrBlank() },
                ) ?: "owner-vps-lab-$serverName-$transport-$serverPort",
            ownerRealityEgress = ownerRealityEgress,
            activationState = resolveRealityVpsLabActivationState(mode),
        )
    }

    private fun readRealityWhitelistHintRuntimeOptions(
        args: JSObject,
        profile: JSObject,
        fallbackServerName: String,
        baseOptions: RealityRuntimeOptions,
    ): RealityWhitelistHintRuntimeOptions {
        val profileOptions =
            profile.optJSONObject("androidRuntime")?.optJSONObject("realityWhitelistHints")
                ?: profile.optJSONObject("runtimeOptions")?.optJSONObject("realityWhitelistHints")
                ?: profile.optJSONObject("androidRealityWhitelistHints")
                ?: JSONObject()
        val mode =
            normalizeRealityWhitelistMode(
                args.getString("configMode", null)
                    ?.trim()
                    .takeUnless { it.isNullOrBlank() }
                    ?: profileOptions.optString("mode").takeUnless { it.isNullOrBlank() }
                    ?: REALITY_WHITELIST_MODE_SCAFFOLD,
            )
        val selection =
            normalizeRealityWhitelistSelection(
                args.getString("whitelistHintSelection", null)
                    ?.trim()
                    .takeUnless { it.isNullOrBlank() }
                    ?: profileOptions.optString("selection").takeUnless { it.isNullOrBlank() }
                    ?: profileOptions.optString("hintSelection").takeUnless { it.isNullOrBlank() }
                    ?: REALITY_WHITELIST_SELECTION_ORDERED,
            )
        val explicitServerNameRaw =
            args.getString("selectedSniHint", null)
                ?.trim()
                .takeUnless { it.isNullOrBlank() }
                ?: profileOptions.optString("selectedSniHint").takeUnless { it.isNullOrBlank() }
                ?: profileOptions.optString("serverName").takeUnless { it.isNullOrBlank() }
        val explicitCandidate =
            explicitServerNameRaw?.let { serverName ->
                RealityWhitelistHintCandidate(
                    serverName = normalizeRealityWhitelistServerName(serverName, fallbackServerName),
                    cidrBucket =
                        normalizeRealityWhitelistHintValue(
                            args.getString("selectedCidrHint", null)
                                ?.trim()
                                .takeUnless { it.isNullOrBlank() }
                                ?: profileOptions.optString("selectedCidrHint").takeUnless { it.isNullOrBlank() }
                                ?: profileOptions.optString("cidrBucket").takeUnless { it.isNullOrBlank() },
                        ),
                    source =
                        normalizeRealityWhitelistHintValue(
                            args.getString("whitelistHintSource", null)
                                ?.trim()
                                .takeUnless { it.isNullOrBlank() }
                                ?: profileOptions.optString("source").takeUnless { it.isNullOrBlank() },
                        ),
                    tag =
                        normalizeRealityWhitelistHintValue(
                            args.getString("whitelistHintTag", null)
                                ?.trim()
                                .takeUnless { it.isNullOrBlank() }
                                ?: profileOptions.optString("tag").takeUnless { it.isNullOrBlank() },
                        ),
                )
            }
        val configuredPool = readRealityWhitelistHintPool(profileOptions, fallbackServerName)
        val hintPool =
            buildList {
                explicitCandidate?.let(::add)
                configuredPool.forEach { candidate ->
                    if (explicitCandidate == null || !sameRealityWhitelistHintCandidate(candidate, explicitCandidate)) {
                        add(candidate)
                    }
                }
                if (isEmpty()) {
                    add(
                        RealityWhitelistHintCandidate(
                            serverName = normalizeRealityWhitelistServerName(null, fallbackServerName),
                            cidrBucket = null,
                            source = "profile-default",
                            tag = "bootstrap",
                        ),
                    )
                }
            }
        val selectedHint = selectRealityWhitelistHintCandidate(hintPool, selection)
        return RealityWhitelistHintRuntimeOptions(
            mode = mode,
            selection = selection,
            selectedSniHint = selectedHint.serverName,
            selectedCidrHint = selectedHint.cidrBucket,
            whitelistHintSource = selectedHint.source,
            whitelistHintTag = selectedHint.tag,
            hintPoolSize = hintPool.size,
            hintPool = hintPool,
            bootstrap =
                normalizeRealityWhitelistBootstrap(
                    args.getString("whitelistBootstrapMode", null)
                        ?.trim()
                        .takeUnless { it.isNullOrBlank() }
                        ?: profileOptions.optString("bootstrap").takeUnless { it.isNullOrBlank() }
                        ?: CDN_BOOTSTRAP_DIRECT_REALITY,
                ),
            activationState = resolveRealityWhitelistActivationState(mode),
            baseRealityMode = baseOptions.mode,
            dnsMode = baseOptions.dnsMode,
            dnsServer = baseOptions.dnsServer,
            dnsStrategy = baseOptions.dnsStrategy,
        )
    }

    private fun readRealityWhitelistHintPool(
        profileOptions: JSONObject,
        fallbackServerName: String,
    ): List<RealityWhitelistHintCandidate> {
        val pool =
            profileOptions.optJSONArray("hints")
                ?: profileOptions.optJSONArray("hintPool")
                ?: return emptyList()
        return buildList {
            for (index in 0 until pool.length()) {
                val entry = pool.optJSONObject(index) ?: continue
                val serverName =
                    entry.optString("serverName")
                        .ifBlank { entry.optString("sni") }
                        .trim()
                if (serverName.isBlank()) {
                    continue
                }
                add(
                    RealityWhitelistHintCandidate(
                        serverName = normalizeRealityWhitelistServerName(serverName, fallbackServerName),
                        cidrBucket =
                            normalizeRealityWhitelistHintValue(
                                entry.optString("cidrBucket")
                                    .ifBlank { entry.optString("cidr") }
                                    .takeUnless { it.isBlank() },
                            ),
                        source =
                            normalizeRealityWhitelistHintValue(
                                entry.optString("source").takeUnless { it.isBlank() },
                            ),
                        tag =
                            normalizeRealityWhitelistHintValue(
                                entry.optString("tag").takeUnless { it.isBlank() },
                            ),
                    ),
                )
            }
        }
    }

    private fun selectRealityWhitelistHintCandidate(
        hintPool: List<RealityWhitelistHintCandidate>,
        selection: String,
    ): RealityWhitelistHintCandidate =
        when (selection) {
            REALITY_WHITELIST_SELECTION_ORDERED -> hintPool.first()
            REALITY_WHITELIST_SELECTION_SOURCE_ROUND_ROBIN -> hintPool.first()
            else -> hintPool.first()
        }

    private fun sameRealityWhitelistHintCandidate(
        left: RealityWhitelistHintCandidate,
        right: RealityWhitelistHintCandidate,
    ): Boolean =
        left.serverName.equals(right.serverName, ignoreCase = true) &&
            left.cidrBucket == right.cidrBucket &&
            left.source == right.source &&
            left.tag == right.tag

    private fun buildRealityWhitelistAssistedFeatureLabels(
        baseOptions: RealityRuntimeOptions,
        options: RealityWhitelistHintRuntimeOptions,
    ): List<String> =
        buildList {
            addAll(options.featureLabels())
            add("flow:xtls-rprx-vision")
            add("utls:chrome")
            add("mux:disabled")
            if (baseOptions.strictRoute) {
                add("strict-route")
            }
            if (baseOptions.tlsFragment) {
                add("tls-fragment")
            }
            if (baseOptions.recordFragment) {
                add("tls-record-fragment")
            }
            if (baseOptions.networkReloadOnChange) {
                add("net-reload:${baseOptions.networkReloadDebounceMs}ms")
            }
            if (baseOptions.dnsDisableCache) {
                add("dns-cache:disabled")
            }
            if (baseOptions.dnsIndependentCache) {
                add("dns-cache:independent")
            }
            if (baseOptions.includePackages.isNotEmpty()) {
                add("pkg-include:${baseOptions.includePackages.size}")
            }
            if (baseOptions.excludePackages.isNotEmpty()) {
                add("pkg-exclude:${baseOptions.excludePackages.size}")
            }
            when {
                baseOptions.privateBypassCidrs.isNotEmpty() -> add("private-bypass:selective:${baseOptions.privateBypassCidrs.size}")
                baseOptions.allowPrivateNetworkBypass -> add("private-bypass:on")
                else -> add("private-bypass:off")
            }
        }

    private fun buildRealityVpsLabFeatureLabels(
        baseOptions: RealityRuntimeOptions,
        options: RealityVpsLabRuntimeOptions,
    ): List<String> =
        buildList {
            addAll(options.featureLabels())
            add("dns:${baseOptions.dnsMode}")
            add("resolver:${baseOptions.dnsServer}")
            add("dns-strategy:${baseOptions.dnsStrategy}")
            if (baseOptions.strictRoute) {
                add("strict-route")
            }
            if (baseOptions.tlsFragment) {
                add("tls-fragment")
            }
            if (baseOptions.recordFragment) {
                add("tls-record-fragment")
            }
            if (baseOptions.networkReloadOnChange) {
                add("net-reload:${baseOptions.networkReloadDebounceMs}ms")
            }
            if (baseOptions.dnsDisableCache) {
                add("dns-cache:disabled")
            }
            if (baseOptions.dnsIndependentCache) {
                add("dns-cache:independent")
            }
            if (baseOptions.includePackages.isNotEmpty()) {
                add("pkg-include:${baseOptions.includePackages.size}")
            }
            if (baseOptions.excludePackages.isNotEmpty()) {
                add("pkg-exclude:${baseOptions.excludePackages.size}")
            }
        }

    private fun readRealityServerNameHint(
        profile: JSObject,
        fallbackHost: String,
    ): String =
        profile.optJSONObject("vlessReality")?.optString("serverName").takeUnless { it.isNullOrBlank() }
            ?: profile.optJSONObject("stagedFallbacks")?.optJSONObject("vlessReality")?.optString("serverName")
                .takeUnless { it.isNullOrBlank() }
            ?: fallbackHost

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
        val rawDnsMode =
            args.getString("dnsMode", null)
                ?.trim()
                .takeUnless { it.isNullOrBlank() }
                ?: profileOptions?.optString("dnsMode").takeUnless { it.isNullOrBlank() }
        val rawDnsServer =
            args.getString("dnsServer", null)
                ?.trim()
                .takeUnless { it.isNullOrBlank() }
                ?: profileOptions?.optString("dnsServer").takeUnless { it.isNullOrBlank() }
        val rawDnsServerPort =
            readNullableIntOption(
                args = args,
                key = "dnsServerPort",
                fallback = profileOptions?.optInt("dnsServerPort"),
            )
        val rawDnsDohPath =
            args.getString("dnsDohPath", null)
                ?.trim()
                .takeUnless { it.isNullOrBlank() }
                ?: profileOptions?.optString("dnsDohPath").takeUnless { it.isNullOrBlank() }
        val rawDnsServerName =
            args.getString("dnsServerName", null)
                ?.trim()
                .takeUnless { it.isNullOrBlank() }
                ?: profileOptions?.optString("dnsServerName").takeUnless { it.isNullOrBlank() }
        val dnsMode =
            normalizeRealityDnsMode(
                when {
                    shouldUpgradeLegacyDefaultDnsToDoh(
                        mode = mode,
                        rawDnsMode = rawDnsMode,
                        rawDnsServer = rawDnsServer,
                        rawDnsServerPort = rawDnsServerPort,
                        rawDnsServerName = rawDnsServerName,
                        rawDnsDohPath = rawDnsDohPath,
                    ) -> REALITY_DNS_MODE_DOH
                    rawDnsMode != null -> rawDnsMode
                    mode == REALITY_MODE_EXPERIMENTAL -> {
                        REALITY_DNS_MODE_DOT
                    }
                    else -> {
                        REALITY_DNS_MODE_DOH
                    }
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
        val dnsServer = rawDnsServer ?: REALITY_DNS_DEFAULT_SERVER
        val dnsServerPort = rawDnsServerPort
        val dnsDohPath =
            normalizeDohPath(
                rawDnsDohPath ?: REALITY_DNS_DEFAULT_DOH_PATH,
            )
        val dnsServerName =
            normalizeRealityDnsServerName(
                rawValue = rawDnsServerName,
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
        val localBypassDomainKeywords =
            readStringListOption(args, "localBypassDomainKeywords", profileOptions, "localBypassDomainKeywords")
                .mapNotNull(::normalizeCdnRoutingKeyword)
                .ifEmpty { DEFAULT_LOCAL_BYPASS_DOMAIN_KEYWORDS }
                .distinct()
        val localBypassDomains =
            readStringListOption(args, "localBypassDomains", profileOptions, "localBypassDomains")
                .mapNotNull(::normalizeCdnRoutingDomain)
                .ifEmpty { DEFAULT_LOCAL_BYPASS_DOMAINS }
                .distinct()
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
            localBypassDomainKeywords = localBypassDomainKeywords,
            localBypassDomains = localBypassDomains,
        )
    }

    private fun appendLocalBypassRouteRules(
        routeRules: JSONArray,
        domainKeywords: List<String>,
        domains: List<String>,
    ) {
        if (domainKeywords.isNotEmpty()) {
            routeRules.put(
                JSONObject()
                    .put("domain_keyword", JSONArray(domainKeywords))
                    .put("outbound", "direct"),
            )
        }
        if (domains.isNotEmpty()) {
            routeRules.put(
                JSONObject()
                    .put("domain", JSONArray(domains))
                    .put("outbound", "direct"),
            )
        }
    }

    private fun normalizeRealityMode(value: String?): String =
        if (value?.trim()?.lowercase(Locale.ROOT) == REALITY_MODE_EXPERIMENTAL) {
            REALITY_MODE_EXPERIMENTAL
        } else {
            REALITY_MODE_STABLE
        }

    private fun normalizeCdnProvider(value: String?): String = value?.trim()?.lowercase(Locale.ROOT).orEmpty().ifBlank {
        CDN_PROVIDER_GENERIC
    }

    private fun normalizeCdnPort(
        rawValue: Int?,
        defaultPort: Int,
    ): Int =
        rawValue?.takeIf { it in 1..65535 } ?: defaultPort

    private fun normalizeCdnTlsServerName(
        rawValue: String?,
        frontHost: String?,
    ): String =
        rawValue?.trim()?.takeIf { it.isNotEmpty() }
            ?: frontHost?.trim()?.takeIf { it.isNotEmpty() }
            ?: ""

    private fun normalizeCdnConnectHost(
        rawValue: String?,
        frontHost: String?,
        serverHost: String? = null,
    ): String =
        rawValue?.trim()?.takeIf { it.isNotEmpty() }
            ?: frontHost?.trim()?.takeIf { it.isNotEmpty() }
            ?: serverHost?.trim()?.takeIf { it.isNotEmpty() }
            ?: ""

    private fun normalizeCdnConnectPort(
        rawValue: Int?,
        frontPort: Int,
    ): Int = normalizeCdnPort(rawValue, defaultPort = frontPort)

    private fun normalizePositiveIntOption(rawValue: Int?): Int? =
        rawValue?.takeIf { it > 0 }

    private fun normalizeCdnHttpHostHeader(
        rawValue: String?,
        frontHost: String?,
        tlsServerName: String?,
    ): String =
        rawValue?.trim()?.takeIf { it.isNotEmpty() }
            ?: frontHost?.trim()?.takeIf { it.isNotEmpty() }
            ?: tlsServerName?.trim()?.takeIf { it.isNotEmpty() }
            ?: ""

    private fun normalizeCdnTransport(value: String?): String =
        when (value?.trim()?.lowercase(Locale.ROOT)) {
            CDN_TRANSPORT_XHTTP -> CDN_TRANSPORT_XHTTP
            CDN_TRANSPORT_HTTP_UPGRADE -> CDN_TRANSPORT_HTTP_UPGRADE
            else -> CDN_TRANSPORT_WEBSOCKET
        }

    private fun normalizeCdnXhttpMode(value: String?): String? =
        when (value?.trim()?.lowercase(Locale.ROOT)) {
            CDN_XHTTP_MODE_PACKET_UP -> CDN_XHTTP_MODE_PACKET_UP
            CDN_XHTTP_MODE_STREAM_UP -> CDN_XHTTP_MODE_STREAM_UP
            CDN_XHTTP_MODE_STREAM_ONE -> CDN_XHTTP_MODE_STREAM_ONE
            else -> null
        }

    private fun resolveSafeCdnXmuxMaxConcurrency(
        transport: String,
        frontPort: Int,
        currentValue: Int?,
    ): Int? {
        if (transport != CDN_TRANSPORT_XHTTP || frontPort != 443) {
            return currentValue
        }
        val base = currentValue ?: 0
        return maxOf(base, 20).takeIf { it > 0 }
    }

    private fun normalizeRuntimeEngine(value: String?): String =
        when (value?.trim()?.lowercase(Locale.ROOT)) {
            ENGINE_XRAY_NATIVE -> ENGINE_XRAY_NATIVE
            else -> ENGINE_SING_BOX
        }

    private fun normalizeCdnMode(value: String?): String =
        when (value?.trim()?.lowercase(Locale.ROOT)) {
            CDN_MODE_LAB -> CDN_MODE_LAB
            else -> CDN_MODE_SCAFFOLD
        }

    private fun resolveCdnActivationState(
        mode: String,
        transport: String,
    ): String =
        if (
            mode == CDN_MODE_LAB &&
            (
                transport == CDN_TRANSPORT_WEBSOCKET ||
                    transport == CDN_TRANSPORT_XHTTP ||
                    transport == CDN_TRANSPORT_HTTP_UPGRADE
            )
        ) {
            ACTIVATION_STATE_ACTIVE
        } else {
            ACTIVATION_STATE_SCAFFOLD_ONLY
        }

    private fun normalizeCdnBootstrap(value: String?): String =
        when (value?.trim()?.lowercase(Locale.ROOT)) {
            CDN_BOOTSTRAP_DIRECT_REALITY -> CDN_BOOTSTRAP_DIRECT_REALITY
            else -> CDN_BOOTSTRAP_DIRECT_REALITY
        }

    private fun normalizeCdnRoutingDnsQueryStrategy(value: String?): String =
        when (value?.trim()?.lowercase(Locale.ROOT)?.replace("-", "_")) {
            "useip",
            CDN_ROUTING_DNS_QUERY_STRATEGY_USE_IP -> CDN_ROUTING_DNS_QUERY_STRATEGY_USE_IP
            else -> CDN_ROUTING_DNS_QUERY_STRATEGY_AUTO
        }

    private fun normalizeCdnRoutingDomainStrategy(value: String?): String =
        when (value?.trim()?.lowercase(Locale.ROOT)?.replace("-", "_")) {
            "ipifnonmatch",
            CDN_ROUTING_DOMAIN_STRATEGY_IP_IF_NON_MATCH -> CDN_ROUTING_DOMAIN_STRATEGY_IP_IF_NON_MATCH
            "asis",
            CDN_ROUTING_DOMAIN_STRATEGY_AS_IS -> CDN_ROUTING_DOMAIN_STRATEGY_AS_IS
            else -> CDN_ROUTING_DOMAIN_STRATEGY_IP_IF_NON_MATCH
        }

    private fun normalizeCdnRoutingDomainMatcher(value: String?): String =
        when (value?.trim()?.lowercase(Locale.ROOT)) {
            CDN_ROUTING_DOMAIN_MATCHER_HYBRID -> CDN_ROUTING_DOMAIN_MATCHER_HYBRID
            else -> CDN_ROUTING_DOMAIN_MATCHER_HYBRID
        }

    private fun normalizeCdnOriginScheme(value: String?): String =
        when (value?.trim()?.lowercase(Locale.ROOT)) {
            CDN_ORIGIN_SCHEME_HTTP -> CDN_ORIGIN_SCHEME_HTTP
            else -> CDN_ORIGIN_SCHEME_HTTPS
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

    private fun shouldUpgradeLegacyDefaultDnsToDoh(
        mode: String,
        rawDnsMode: String?,
        rawDnsServer: String?,
        rawDnsServerPort: Int?,
        rawDnsServerName: String?,
        rawDnsDohPath: String?,
    ): Boolean {
        if (mode == REALITY_MODE_EXPERIMENTAL) {
            return false
        }
        if (rawDnsMode?.trim()?.lowercase(Locale.ROOT) != REALITY_DNS_MODE_UDP) {
            return false
        }
        val server = rawDnsServer?.trim().takeUnless { it.isNullOrBlank() } ?: REALITY_DNS_DEFAULT_SERVER
        val port = rawDnsServerPort ?: 53
        val serverName =
            rawDnsServerName
                ?.trim()
                .takeUnless { it.isNullOrBlank() }
                ?: REALITY_DNS_DEFAULT_SERVER_NAME
        val dohPath =
            normalizeDohPath(
                rawDnsDohPath
                    ?.trim()
                    .takeUnless { it.isNullOrBlank() }
                    ?: REALITY_DNS_DEFAULT_DOH_PATH,
            )
        return server == REALITY_DNS_DEFAULT_SERVER &&
            port == 53 &&
            serverName.equals(REALITY_DNS_DEFAULT_SERVER_NAME, ignoreCase = true) &&
            dohPath == REALITY_DNS_DEFAULT_DOH_PATH
    }

    private fun normalizeRealityNetworkReloadDebounceMs(value: Long): Long =
        value.coerceIn(REALITY_NETWORK_RELOAD_DEBOUNCE_MIN_MS, REALITY_NETWORK_RELOAD_DEBOUNCE_MAX_MS)

    private fun normalizeDohPath(value: String): String =
        when {
            value.isBlank() -> REALITY_DNS_DEFAULT_DOH_PATH
            value.startsWith("/") -> value
            else -> "/$value"
        }

    private fun normalizeHttpPath(value: String): String =
        when {
            value.isBlank() -> CDN_DEFAULT_FRONT_PATH
            value.startsWith("/") -> value
            else -> "/$value"
        }

    private fun normalizeCdnRoutingKeyword(value: String): String? {
        val raw = value.trim()
        if (raw.isBlank()) {
            return null
        }
        val normalized = raw.removePrefix("keyword:").trim().lowercase(Locale.ROOT)
        return normalized.takeIf { it.isNotBlank() }
    }

    private fun normalizeCdnRoutingDomain(value: String): String? {
        val raw = value.trim()
        if (raw.isBlank()) {
            return null
        }
        val normalized =
            raw.removePrefix("full:")
                .removePrefix("domain:")
                .trim()
                .lowercase(Locale.ROOT)
        return normalized.takeIf { it.isNotBlank() }
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

    private fun profileFingerprintJson(
        rawProfileJson: String?,
        runtimeFamily: String,
    ): String {
        val original = rawProfileJson ?: "{}"
        val profile =
            runCatching { JSONObject(original) }
                .getOrElse { return original }
        val fingerprintProfile = JSONObject(profile.toString())
        pruneInactiveHiddenRuntimeBlocks(fingerprintProfile, runtimeFamily)
        return fingerprintProfile.toString()
    }

    private fun pruneInactiveHiddenRuntimeBlocks(
        profile: JSONObject,
        runtimeFamily: String,
    ) {
        when (runtimeFamily) {
            RUNTIME_FAMILY_CDN_ANTI_WHITELIST -> {
                pruneLegacyHiddenRuntimeBlock(profile, "androidCdnAntiWhitelist", keepEnabled = true)
                pruneNestedHiddenRuntimeBlock(profile, "androidRuntime", "cdnAntiWhitelist", keepEnabled = true)
                pruneNestedHiddenRuntimeBlock(profile, "runtimeOptions", "cdnAntiWhitelist", keepEnabled = true)
                pruneNestedHiddenRuntimeBlock(profile, "androidRuntime", "realityVpsLab", keepEnabled = false)
                pruneNestedHiddenRuntimeBlock(profile, "runtimeOptions", "realityVpsLab", keepEnabled = false)
                pruneLegacyHiddenRuntimeBlock(profile, "androidRealityWhitelistHints", keepEnabled = false)
                pruneNestedHiddenRuntimeBlock(profile, "androidRuntime", "realityWhitelistHints", keepEnabled = false)
                pruneNestedHiddenRuntimeBlock(profile, "runtimeOptions", "realityWhitelistHints", keepEnabled = false)
            }

            RUNTIME_FAMILY_REALITY_VPS_LAB -> {
                pruneLegacyHiddenRuntimeBlock(profile, "androidCdnAntiWhitelist", keepEnabled = false)
                pruneNestedHiddenRuntimeBlock(profile, "androidRuntime", "cdnAntiWhitelist", keepEnabled = false)
                pruneNestedHiddenRuntimeBlock(profile, "runtimeOptions", "cdnAntiWhitelist", keepEnabled = false)
                pruneNestedHiddenRuntimeBlock(profile, "androidRuntime", "realityVpsLab", keepEnabled = true)
                pruneNestedHiddenRuntimeBlock(profile, "runtimeOptions", "realityVpsLab", keepEnabled = true)
                pruneLegacyHiddenRuntimeBlock(profile, "androidRealityWhitelistHints", keepEnabled = false)
                pruneNestedHiddenRuntimeBlock(profile, "androidRuntime", "realityWhitelistHints", keepEnabled = false)
                pruneNestedHiddenRuntimeBlock(profile, "runtimeOptions", "realityWhitelistHints", keepEnabled = false)
            }

            RUNTIME_FAMILY_REALITY_WHITELIST_ASSISTED -> {
                pruneLegacyHiddenRuntimeBlock(profile, "androidCdnAntiWhitelist", keepEnabled = false)
                pruneNestedHiddenRuntimeBlock(profile, "androidRuntime", "cdnAntiWhitelist", keepEnabled = false)
                pruneNestedHiddenRuntimeBlock(profile, "runtimeOptions", "cdnAntiWhitelist", keepEnabled = false)
                pruneNestedHiddenRuntimeBlock(profile, "androidRuntime", "realityVpsLab", keepEnabled = false)
                pruneNestedHiddenRuntimeBlock(profile, "runtimeOptions", "realityVpsLab", keepEnabled = false)
                pruneLegacyHiddenRuntimeBlock(profile, "androidRealityWhitelistHints", keepEnabled = true)
                pruneNestedHiddenRuntimeBlock(profile, "androidRuntime", "realityWhitelistHints", keepEnabled = true)
                pruneNestedHiddenRuntimeBlock(profile, "runtimeOptions", "realityWhitelistHints", keepEnabled = true)
            }

            else -> {
                pruneLegacyHiddenRuntimeBlock(profile, "androidCdnAntiWhitelist", keepEnabled = false)
                pruneNestedHiddenRuntimeBlock(profile, "androidRuntime", "cdnAntiWhitelist", keepEnabled = false)
                pruneNestedHiddenRuntimeBlock(profile, "runtimeOptions", "cdnAntiWhitelist", keepEnabled = false)
                pruneNestedHiddenRuntimeBlock(profile, "androidRuntime", "realityVpsLab", keepEnabled = false)
                pruneNestedHiddenRuntimeBlock(profile, "runtimeOptions", "realityVpsLab", keepEnabled = false)
                pruneLegacyHiddenRuntimeBlock(profile, "androidRealityWhitelistHints", keepEnabled = false)
                pruneNestedHiddenRuntimeBlock(profile, "androidRuntime", "realityWhitelistHints", keepEnabled = false)
                pruneNestedHiddenRuntimeBlock(profile, "runtimeOptions", "realityWhitelistHints", keepEnabled = false)
            }
        }
    }

    private fun pruneLegacyHiddenRuntimeBlock(
        profile: JSONObject,
        key: String,
        keepEnabled: Boolean,
    ) {
        if (!profile.has(key)) {
            return
        }
        val block = profile.optJSONObject(key)
        if (block == null || !keepEnabled || !block.optBoolean("enabled", false)) {
            profile.remove(key)
        }
    }

    private fun pruneNestedHiddenRuntimeBlock(
        profile: JSONObject,
        parentKey: String,
        blockKey: String,
        keepEnabled: Boolean,
    ) {
        val parent = profile.optJSONObject(parentKey) ?: return
        val block = parent.optJSONObject(blockKey)
        if (block == null || !keepEnabled || !block.optBoolean("enabled", false)) {
            parent.remove(blockKey)
        }
        if (parent.length() == 0) {
            profile.remove(parentKey)
        }
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
                append(args.getString("runtimeFamily", "")?.trim().orEmpty())
                append('|')
                append(args.getString("activationState", "")?.trim().orEmpty())
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
                append(
                    profileFingerprintJson(
                        args.getString("profileJson", "{}"),
                        RUNTIME_FAMILY_DIRECT_REALITY,
                    ),
                )
            }
        return sha256Hex(digest)
    }

    private fun computeRealityWhitelistAssistedProfileHash(
        args: JSObject,
        baseOptions: RealityRuntimeOptions,
        options: RealityWhitelistHintRuntimeOptions,
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
                append(args.getString("runtimeFamily", "")?.trim().orEmpty())
                append('|')
                append(options.activationState)
                append('|')
                append(options.mode)
                append('|')
                append(options.selection)
                append('|')
                append(options.selectedSniHint)
                append('|')
                append(options.selectedCidrHint.orEmpty())
                append('|')
                append(options.whitelistHintSource.orEmpty())
                append('|')
                append(options.whitelistHintTag.orEmpty())
                append('|')
                append(options.hintPoolSize)
                options.hintPool.forEach { candidate ->
                    append('|')
                    append(candidate.serverName)
                    append('@')
                    append(candidate.cidrBucket.orEmpty())
                    append('@')
                    append(candidate.source.orEmpty())
                    append('@')
                    append(candidate.tag.orEmpty())
                }
                append('|')
                append(options.bootstrap)
                append('|')
                append(baseOptions.mode)
                append('|')
                append(baseOptions.dnsMode)
                append('|')
                append(baseOptions.strictRoute)
                append('|')
                append(baseOptions.disableMultiplex)
                append('|')
                append(baseOptions.tlsFragment)
                append('|')
                append(baseOptions.recordFragment)
                append('|')
                append(baseOptions.allowPrivateNetworkBypass)
                append('|')
                append(baseOptions.privateBypassCidrs.joinToString(","))
                append('|')
                append(baseOptions.networkReloadOnChange)
                append('|')
                append(baseOptions.networkReloadDebounceMs)
                append('|')
                append(baseOptions.dnsServer)
                append('|')
                append(baseOptions.dnsServerPort ?: 0)
                append('|')
                append(baseOptions.dnsServerName)
                append('|')
                append(baseOptions.dnsDohPath)
                append('|')
                append(baseOptions.dnsStrategy)
                append('|')
                append(baseOptions.dnsDisableCache)
                append('|')
                append(baseOptions.dnsIndependentCache)
                append('|')
                append(baseOptions.includePackages.joinToString(","))
                append('|')
                append(baseOptions.excludePackages.joinToString(","))
                append('|')
                append(
                    profileFingerprintJson(
                        args.getString("profileJson", "{}"),
                        RUNTIME_FAMILY_REALITY_WHITELIST_ASSISTED,
                    ),
                )
            }
        return sha256Hex(digest)
    }

    private fun computeRealityVpsLabProfileHash(
        args: JSObject,
        baseOptions: RealityRuntimeOptions,
        options: RealityVpsLabRuntimeOptions,
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
                append(args.getString("runtimeFamily", "")?.trim().orEmpty())
                append('|')
                append(options.activationState)
                append('|')
                append(options.mode)
                append('|')
                append(options.serverName)
                append('|')
                append(options.serverPort)
                append('|')
                append(options.connectHost)
                append('|')
                append(options.connectPort)
                append('|')
                append(options.transport)
                append('|')
                append(options.flow.orEmpty())
                append('|')
                append(options.fingerprint)
                append('|')
                append(options.grpcServiceName.orEmpty())
                append('|')
                append(options.grpcAuthority.orEmpty())
                append('|')
                append(options.source.orEmpty())
                append('|')
                append(options.tag.orEmpty())
                append('|')
                append(options.ownerRealityEgress)
                append('|')
                append(baseOptions.mode)
                append('|')
                append(baseOptions.dnsMode)
                append('|')
                append(baseOptions.strictRoute)
                append('|')
                append(baseOptions.disableMultiplex)
                append('|')
                append(baseOptions.tlsFragment)
                append('|')
                append(baseOptions.recordFragment)
                append('|')
                append(baseOptions.allowPrivateNetworkBypass)
                append('|')
                append(baseOptions.privateBypassCidrs.joinToString(","))
                append('|')
                append(baseOptions.networkReloadOnChange)
                append('|')
                append(baseOptions.networkReloadDebounceMs)
                append('|')
                append(baseOptions.dnsServer)
                append('|')
                append(baseOptions.dnsServerPort ?: 0)
                append('|')
                append(baseOptions.dnsServerName)
                append('|')
                append(baseOptions.dnsDohPath)
                append('|')
                append(baseOptions.dnsStrategy)
                append('|')
                append(baseOptions.dnsDisableCache)
                append('|')
                append(baseOptions.dnsIndependentCache)
                append('|')
                append(baseOptions.includePackages.joinToString(","))
                append('|')
                append(baseOptions.excludePackages.joinToString(","))
                append('|')
                append(
                    profileFingerprintJson(
                        args.getString("profileJson", "{}"),
                        RUNTIME_FAMILY_REALITY_VPS_LAB,
                    ),
                )
            }
        return sha256Hex(digest)
    }

    private fun computeCdnAntiWhitelistProfileHash(
        args: JSObject,
        options: CdnAntiWhitelistRuntimeOptions,
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
                append(args.getString("runtimeFamily", "")?.trim().orEmpty())
                append('|')
                append(options.activationState)
                append('|')
                append(options.mode)
                append('|')
                append(options.provider)
                append('|')
                append(options.transport)
                append('|')
                append(options.frontHost)
                append('|')
                append(options.frontPort)
                append('|')
                append(options.connectHost)
                append('|')
                append(options.connectPort)
                append('|')
                append(options.frontPath)
                append('|')
                append(options.tlsServerName)
                append('|')
                append(options.httpHostHeader)
                append('|')
                append(options.frontTag.orEmpty())
                append('|')
                append(options.frontSelection)
                append('|')
                append(options.frontPoolSize)
                options.frontPool.forEach { candidate ->
                    append('|')
                    append(candidate.host)
                    append('@')
                    append(candidate.port)
                    append('@')
                    append(candidate.connectHost)
                    append('@')
                    append(candidate.connectPort)
                    append('@')
                    append(candidate.path)
                    append('@')
                    append(candidate.tlsServerName)
                    append('@')
                    append(candidate.httpHostHeader)
                    append('@')
                    append(candidate.provider)
                    append('@')
                    append(candidate.tag.orEmpty())
                }
                append('|')
                append(options.originHost)
                append('|')
                append(options.originPort)
                append('|')
                append(options.originScheme)
                append('|')
                append(options.originPath)
                append('|')
                append(options.bootstrap)
                append('|')
                append(options.routingPolicy.dnsQueryStrategy)
                append('|')
                append(options.routingPolicy.domainStrategy)
                append('|')
                append(options.routingPolicy.domainMatcher)
                append('|')
                append(options.routingPolicy.directDomainKeywords.joinToString(","))
                append('|')
                append(options.routingPolicy.directDomains.joinToString(","))
                append('|')
                append(options.routingPolicy.blockedDomainKeywords.joinToString(","))
                append('|')
                append(options.routingPolicy.blockedDomains.joinToString(","))
                append('|')
                append(options.routingPolicy.blockSelectedFrontHost)
                append('|')
                append(
                    profileFingerprintJson(
                        args.getString("profileJson", "{}"),
                        RUNTIME_FAMILY_CDN_ANTI_WHITELIST,
                    ),
                )
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
        excludePackages: List<String>,
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
                "type": "https",
                "server": "1.1.1.1",
                "server_port": 443,
                "path": "/dns-query",
                "detour": "wg-ep",
                "tls": {
                  "server_name": "cloudflare-dns.com"
                }
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
              "strict_route": false${
                  if (excludePackages.isNotEmpty()) {
                      ",\n              \"exclude_package\": [${excludePackages.joinToString(",") { jsonString(it) }}]"
                  } else {
                      ""
                  }
              }
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
              },
              {
                "domain_keyword": [${DEFAULT_LOCAL_BYPASS_DOMAIN_KEYWORDS.joinToString(",") { jsonString(it) }}],
                "outbound": "direct"
              },
              {
                "domain": [${DEFAULT_LOCAL_BYPASS_DOMAINS.joinToString(",") { jsonString(it) }}],
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
        streamCount: Int,
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
            "-n",
            normalizeVkTurnStreamCount(streamCount).toString(),
            "-listen",
            "127.0.0.1:$bridgePort",
        )
    }

    private fun readVkTurnStreamCount(
        args: JSObject,
        profile: JSONObject,
    ): Int {
        val requested = args.optInt("vkTurnStreamCount", 0)
        if (requested > 0) {
            return normalizeVkTurnStreamCount(requested)
        }
        return normalizeVkTurnStreamCount(profile.optInt("vkTurnStreamCount", 0))
    }

    private fun normalizeVkTurnStreamCount(value: Int): Int =
        if (value in MIN_VK_TURN_STREAM_COUNT..MAX_VK_TURN_STREAM_COUNT) {
            value
        } else {
            DEFAULT_VK_TURN_STREAM_COUNT
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
