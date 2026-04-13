package com.odinone.desktop.vk

import android.app.Notification as AndroidNotification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.ProxyInfo
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.os.SystemClock
import android.provider.Settings
import android.util.Base64
import android.util.Log
import androidx.core.app.NotificationCompat
import app.tauri.plugin.JSObject
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.ConnectionOwner
import io.nekohasekai.libbox.InterfaceUpdateListener
import io.nekohasekai.libbox.LocalDNSTransport
import io.nekohasekai.libbox.NeighborUpdateListener
import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.Notification
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.SystemProxyStatus
import io.nekohasekai.libbox.TunOptions
import io.nekohasekai.libbox.WIFIState
import java.net.NetworkInterface
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

class VpnRuntimeService : VpnService(), PlatformInterface, CommandServerHandler {
    private var commandServer: CommandServer? = null
    private var tunDescriptor: ParcelFileDescriptor? = null
    private var vkProcess: Process? = null
    private var nativeProcess: Process? = null
    private var activeRuntime: PreparedRuntime? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var lastVkProcessLogLine: String? = null
    private var lastNativeProcessLogLine: String? = null
    private var pendingVkCaptchaUrl: String? = null
    private var lastOpenedVkCaptchaUrl: String? = null
    @Volatile
    private var vkTunnelStartPending = false
    @Volatile
    private var vkTunnelActivationInFlight = false
    @Volatile
    private var vkStartupStartedAtMs: Long = 0L

    @Volatile
    private var shuttingDown = false
    private val lifecycleLock = Any()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var pendingNetworkReload: Runnable? = null
    @Volatile
    private var networkReloadInFlight = false
    @Volatile
    private var queuedNetworkReloadTrigger: String? = null
    private var lastDeliveredUnderlyingNetworkHandle: Long? = null
    private var lastDeliveredUnderlyingInterfaceName: String? = null

    private var systemProxyAvailable = false
    private var systemProxyEnabled = false
    private val defaultInterfaceCallbacks = mutableMapOf<InterfaceUpdateListener, ConnectivityManager.NetworkCallback>()

    override fun onCreate() {
        super.onCreate()
        VpnRuntimeLibbox.ensureInitialized(this)
        ensureNotificationChannel()
        captureRuntimeState(VpnRuntimeStore.snapshot(this))
        appendDiagnostic("VpnRuntimeService created.")
    }

    override fun onRevoke() {
        appendDiagnostic("Android VPN permission was revoked by the system.")
        VpnRuntimeRestoreStore.markResumeEligible(this, false)
        thread(name = "odin-one-vpn-revoke", isDaemon = true) {
            handleStop(requestedByUser = false, reason = "VpnService permission revoked")
        }
        super.onRevoke()
    }

    override fun onStartCommand(
        intent: Intent?,
        flags: Int,
        startId: Int,
    ): Int {
        val action = intent?.action
        val currentSnapshot = VpnRuntimeStore.snapshot(this)
        appendDiagnostic(
            "onStartCommand action=${action ?: "<null>"} flags=$flags startId=$startId currentStatus=${currentSnapshot.status}",
        )
        when (action) {
            ACTION_START -> {
                appendDiagnostic("Received ACTION_START intent.")
                val rawArgs = intent.getStringExtra(EXTRA_START_ARGS)
                val encodedArgs = intent.getStringExtra(EXTRA_START_ARGS_BASE64)
                thread(name = "odin-one-vpn-start", isDaemon = true) {
                    handleStart(decodeStartArgs(rawArgs, encodedArgs))
                }
            }

            ACTION_STOP -> {
                appendDiagnostic("Received ACTION_STOP intent from app/plugin layer.")
                thread(name = "odin-one-vpn-stop", isDaemon = true) {
                    handleStop(requestedByUser = true, reason = "ACTION_STOP intent")
                }
            }

            null -> {
                val restoreDecision = classifySystemRestoreAvailability(
                    resumeEligible = VpnRuntimeRestoreStore.isResumeEligible(this),
                    request = VpnRuntimeRestoreStore.readStartRequest(this),
                )
                if (restoreDecision == "available") {
                    recordRestoreTelemetry(
                        source = "system",
                        action = "attempt",
                        detail = "available",
                        message = "Received system-driven onStartCommand without explicit action. Attempting REALITY restore.",
                    )
                    thread(name = "odin-one-vpn-system-start", isDaemon = true) {
                        handleStart(null)
                    }
                } else {
                    recordRestoreTelemetry(
                        source = "system",
                        action = "skip",
                        detail = restoreDecision,
                        message = "Ignoring null onStartCommand intent because no resume-eligible REALITY request is available. reason=$restoreDecision",
                    )
                }
            }

            else -> {
                appendDiagnostic("Ignoring unexpected onStartCommand action=$action to avoid accidental VPN shutdown.")
            }
        }
        val startMode =
            if (shouldKeepVpnServiceSticky(action, currentSnapshot)) {
                START_STICKY
            } else {
                START_NOT_STICKY
            }
        appendDiagnostic(
            "onStartCommand completed with ${if (startMode == START_STICKY) "START_STICKY" else "START_NOT_STICKY"}.",
        )
        return startMode
    }

    override fun onDestroy() {
        val current = VpnRuntimeStore.snapshot(this)
        appendDiagnostic(
            "onDestroy called. status=${current.status} commandServer=${commandServer != null} tun=${tunDescriptor != null} vkProcess=${vkProcess != null}",
        )
        closeRuntimeResources("onDestroy")
        val latest = VpnRuntimeStore.snapshot(this)
        if (current.status == "starting" || current.status == "running") {
            VpnRuntimeStore.write(
                this,
                latest.copy(
                    status = "stopped",
                    socksAddress = null,
                    bridgeAddress = null,
                    error = null,
                    logTail = trimLogTail(latest.logTail + "Android VpnService was destroyed."),
                ),
                sync = true,
            )
        }
        super.onDestroy()
    }

    override fun autoDetectInterfaceControl(fd: Int) {
        protect(fd)
    }

    override fun clearDNSCache() {
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        val callback = synchronized(defaultInterfaceCallbacks) { defaultInterfaceCallbacks.remove(listener) } ?: return
        val connectivity = getSystemService(ConnectivityManager::class.java)
        runCatching { connectivity.unregisterNetworkCallback(callback) }
            .onFailure { appendDiagnostic("Failed to unregister default interface monitor: ${it.message}") }
    }

    override fun closeNeighborMonitor(listener: NeighborUpdateListener) {
    }

    override fun findConnectionOwner(
        ipProtocol: Int,
        sourceAddress: String,
        sourcePort: Int,
        destinationAddress: String,
        destinationPort: Int,
    ): ConnectionOwner =
        VpnRuntimeLibbox.defaultConnectionOwner(
            this,
            ipProtocol,
            sourceAddress,
            sourcePort,
            destinationAddress,
            destinationPort,
        )

    override fun getInterfaces(): NetworkInterfaceIterator = VpnRuntimeLibbox.listPlatformInterfaces(this)

    override fun getSystemProxyStatus(): SystemProxyStatus = VpnRuntimeLibbox.makeSystemProxyStatus(
        VpnRuntimeStore.snapshot(this),
    )

    override fun includeAllNetworks(): Boolean = false

    override fun localDNSTransport(): LocalDNSTransport? = null

    override fun openTun(options: TunOptions): Int {
        if (prepare(this) != null) {
            error("android: missing vpn permission")
        }

        val builder =
            Builder()
                .setSession("Odin's Cat")
                .setMtu(options.mtu)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false)
        }

        addAddresses(builder, options.inet4Address)
        addAddresses(builder, options.inet6Address)

        if (options.autoRoute) {
            options.dnsServerAddress.value.takeIf { it.isNotBlank() }?.let { builder.addDnsServer(it) }
            addRoutes(builder, options.inet4RouteAddress, "0.0.0.0", 0, options.inet4Address.hasNext())
            addRoutes(builder, options.inet6RouteAddress, "::", 0, options.inet6Address.hasNext())
            excludeOwnPackageFromVpn(builder)
            addAllowedApps(builder, options.includePackage)
            addDisallowedApps(builder, options.excludePackage)
        }

        if (options.isHTTPProxyEnabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            systemProxyAvailable = true
            systemProxyEnabled = true
            builder.setHttpProxy(
                ProxyInfo.buildDirectProxy(
                    options.httpProxyServer,
                    options.httpProxyServerPort,
                    mutableListOf<String>().apply {
                        val bypass = options.httpProxyBypassDomain
                        while (bypass.hasNext()) {
                            add(bypass.next())
                        }
                    },
                ),
            )
        } else {
            systemProxyAvailable = false
            systemProxyEnabled = false
        }

        val descriptor = builder.establish() ?: error("android: the application is not prepared or is revoked")
        tunDescriptor = descriptor
        val next =
            captureRuntimeState { current ->
                current.copy(
                    status = "running",
                    error = null,
                    lastNetworkEvent = "tun:established",
                    logTail = trimLogTail(current.logTail + "Android VpnService established the system VPN interface."),
                )
            }
        runOnMainSync { updateNotification(next) }
        return descriptor.fd
    }

    override fun readWIFIState(): WIFIState? = VpnRuntimeLibbox.readWifiState(this)

    override fun registerMyInterface(name: String) {
    }

    override fun sendNotification(notification: Notification) {
        val title = notification.title.takeUnless { it.isNullOrBlank() } ?: "Odin's Cat"
        val body =
            notification.body.takeUnless { it.isNullOrBlank() }
                ?: notification.subtitle.takeUnless { it.isNullOrBlank() }
                ?: "Android VPN runtime is active"
        val next = appendLog(body)
        runOnMainSync {
            val manager = getSystemService(NotificationManager::class.java)
            manager.notify(NOTIFICATION_ID, buildNotification(next, titleOverride = title, bodyOverride = body))
        }
    }

    override fun serviceReload() {
        appendDiagnostic("libbox requested serviceReload callback.")
        captureRuntimeState { current ->
            current.copy(lastRecoveryAction = "libbox:serviceReload")
        }
        scheduleNetworkReloadIfEnabled("libbox:serviceReload")
    }

    override fun serviceStop() {
        if (shuttingDown) {
            appendDiagnostic("Ignoring libbox serviceStop callback because shutdown is already in progress.")
            return
        }
        appendDiagnostic("libbox requested serviceStop callback.")
        thread(name = "odin-one-vpn-stop", isDaemon = true) {
            handleStop(requestedByUser = false, reason = "libbox serviceStop callback")
        }
    }

    override fun setSystemProxyEnabled(enabled: Boolean) {
        systemProxyEnabled = enabled
    }

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        val connectivity = getSystemService(ConnectivityManager::class.java)
        closeDefaultInterfaceMonitor(listener)
        val callback =
            object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    notifyCurrentUnderlyingInterface(listener, connectivity, "available")
                }

                override fun onCapabilitiesChanged(
                    network: Network,
                    networkCapabilities: android.net.NetworkCapabilities,
                ) {
                    notifyCurrentUnderlyingInterface(listener, connectivity, "capabilities")
                }

                override fun onLinkPropertiesChanged(
                    network: Network,
                    linkProperties: android.net.LinkProperties,
                ) {
                    notifyCurrentUnderlyingInterface(listener, connectivity, "link-properties")
                }

                override fun onLost(network: Network) {
                    val replacement = VpnRuntimeLibbox.resolveUnderlyingDefaultNetwork(connectivity)
                    if (replacement != null) {
                        notifyDefaultInterfaceUpdate(listener, replacement, "lost-replaced")
                    } else {
                        appendDiagnostic("Default interface monitor observed non-VPN network loss without an active replacement.")
                    }
                }
            }
        synchronized(defaultInterfaceCallbacks) {
            defaultInterfaceCallbacks[listener] = callback
        }
        val request =
            NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                .build()
        runCatching { connectivity.registerNetworkCallback(request, callback) }
            .onFailure {
                synchronized(defaultInterfaceCallbacks) {
                    defaultInterfaceCallbacks.remove(listener)
                }
                appendDiagnostic("Failed to register default interface monitor: ${it.message}")
            }
        VpnRuntimeLibbox.resolveUnderlyingDefaultNetwork(connectivity)?.let { network ->
            notifyDefaultInterfaceUpdate(listener, network, "initial")
        }
    }

    override fun startNeighborMonitor(listener: NeighborUpdateListener) {
    }

    override fun systemCertificates(): StringIterator = VpnRuntimeLibbox.systemCertificates()

    override fun underNetworkExtension(): Boolean = false

    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true

    override fun useProcFS(): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q

    override fun writeDebugMessage(message: String) {
        val trimmed = message.trim()
        if (trimmed.isNotEmpty()) {
            appendLog(trimmed)
        }
    }

    private fun handleStart(rawArgs: String?) {
        synchronized(lifecycleLock) {
            val args = resolveStartArgs(rawArgs)
            VpnRuntimeRestoreStore.persistAttemptedStartRequest(this, args)
            val current = VpnRuntimeStore.snapshot(this)
            if (shouldReuseActiveRuntime(current, args)) {
                val reused =
                    VpnRuntimeStore.write(
                        this,
                        current.copy(
                            logTail = trimLogTail(current.logTail + "Reusing identical Android VPN runtime without restarting native resources."),
                        ),
                    )
                runOnMainSync { updateNotification(reused) }
                appendDiagnostic("handleStart reused the existing Android VPN runtime for an identical request.")
                return
            }
            val base = VpnRuntimeStore.write(
                this,
                applyRecoveryCounters(
                    current = current,
                    snapshot = startSnapshotFromArgs(args, "Android VPN permission granted. Preparing native runtime..."),
                    startSource = args.getString("startSource", null),
                ),
            )
            val baseWithState = captureRuntimeState(base.copy(lastNetworkEvent = "start:requested"))

            runOnMainSync { startForeground(baseWithState) }
            acquireWakeLock()

            try {
                var startupStage = "prepare_runtime"
                val startedAt = SystemClock.elapsedRealtime()
                updateStartupStage(startupStage)
                appendDiagnostic("handleStart entered.")
                closeRuntimeResources("handleStart")
                appendLog("Initializing libbox runtime.")
                val prepared = VpnRuntimeLibbox.prepareRuntime(this, args)
                startupStage = "config_ready"
                updateStartupStage(startupStage)
                activeRuntime = prepared
                pendingVkCaptchaUrl = null
                lastOpenedVkCaptchaUrl = null
                appendLog("Validated Android runtime config: ${prepared.configPath}")
                appendDiagnostic(
                    "Prepared Android VPN runtime. source=${args.getString("startSource", "unknown")} family=${prepared.runtimeFamily} activation=${prepared.activationState} mode=${prepared.configMode} profileHash=${prepared.profileHash ?: "n/a"} features=${prepared.activeFeatures.joinToString(",")}",
                )
                if (prepared.runtimeFamily == "cdn-anti-whitelist") {
                    appendDiagnostic(
                        "Selected CDN front for this start. tag=${prepared.frontTag ?: "n/a"} sni=${prepared.selectedSniHint ?: "n/a"} host=${prepared.frontHost ?: "n/a"} connect=${prepared.frontConnectHost ?: "n/a"}:${prepared.frontConnectPort ?: 0} path=${prepared.frontPath ?: "/"}",
                    )
                }
                prepared.remotePeer?.let { appendLog("VK relay remote peer: $it") }
                val vkWarmupOnly = !prepared.vkBinaryPath.isNullOrBlank()
                if (vkWarmupOnly) {
                    vkTunnelStartPending = true
                    vkTunnelActivationInFlight = false
                    vkStartupStartedAtMs = startedAt
                } else {
                    vkTunnelStartPending = false
                    vkTunnelActivationInFlight = false
                    vkStartupStartedAtMs = 0L
                }

                if (!prepared.vkBinaryPath.isNullOrBlank()) {
                    vkProcess = VpnRuntimeLibbox.startVkTurnProcess(prepared) { line ->
                        handleVkProcessLogLine(line)
                        maybePromoteVkRuntimeToRunning(line)
                    }.also { process ->
                        watchVkProcess(process)
                    }
                }
                if (!prepared.nativeBinaryPath.isNullOrBlank()) {
                    nativeProcess = VpnRuntimeLibbox.startNativeProcess(prepared) { line ->
                        handleNativeProcessLogLine(line)
                    }.also { process ->
                        watchNativeProcess(process)
                    }
                }

                if (vkWarmupOnly) {
                    val waiting =
                        captureRuntimeState(
                            VpnRuntimeLibbox.newVkWarmupSnapshot(VpnRuntimeStore.snapshot(this), prepared).copy(
                                lastNetworkEvent = "startup:waiting-for-relay",
                                lastStartupStage = "waiting_for_relay",
                                lastFailureStage = null,
                                lastFailureCode = null,
                            ),
                        )
                    runOnMainSync { updateNotification(waiting) }
                    appendDiagnostic("Android VPN runtime is waiting for VK relay warmup before establishing the system VPN tunnel.")
                } else {
                    val startupDurationMs = startPreparedRuntimeTunnel(prepared, startedAt)
                    maybePersistRestorableState(args)
                    val running =
                        captureRuntimeState(
                            VpnRuntimeLibbox.newRunningSnapshot(VpnRuntimeStore.snapshot(this), prepared).copy(
                                lastNetworkEvent = "startup:running",
                                lastStartupDurationMs = startupDurationMs,
                                lastStartupStage = "running",
                                lastFailureStage = null,
                                lastFailureCode = null,
                            ),
                        )
                    runOnMainSync { updateNotification(running) }
                    appendDiagnostic("Android VPN runtime transitioned to running state.")
                }
            } catch (error: Exception) {
                val failureCurrent = VpnRuntimeStore.snapshot(this)
                handleFailure(
                    message = error.message ?: "Android VPN runtime failed to start.",
                    extraLogLine = "Android VPN startup aborted before the tunnel became ready.",
                    stage = failureCurrent.lastStartupStage ?: "prepare_runtime",
                    identitySnapshot = baseWithState,
                )
            }
        }
    }

    private fun handleStop(
        requestedByUser: Boolean,
        reason: String,
    ) {
        synchronized(lifecycleLock) {
            appendDiagnostic("handleStop entered. requestedByUser=$requestedByUser reason=$reason")
            if (requestedByUser) {
                VpnRuntimeRestoreStore.markResumeEligible(this, false)
            }
            closeRuntimeResources("handleStop:$reason")
            val current = VpnRuntimeStore.snapshot(this)
            persistTerminalState(
                current.copy(
                    status = "stopped",
                    error = null,
                    lastTest = current.lastTest,
                    lastNetworkEvent = "stop:$reason",
                    lastStartupStage = "stopped",
                    lastFailureStage = null,
                    lastFailureCode = null,
                    logTail =
                        trimLogTail(
                            current.logTail +
                                if (requestedByUser) {
                                    "Android VPN runtime stop requested. reason=$reason"
                                } else {
                                    "Android VPN runtime stopped. reason=$reason"
                                },
                        ),
                ),
            )
            runCatching { runOnMainSync { stopForeground(STOP_FOREGROUND_REMOVE) } }
                .onFailure { appendDiagnostic("stopForeground failed during handleStop: ${it.message}") }
            runCatching {
                runOnMainSync {
                    getSystemService(NotificationManager::class.java).cancel(NOTIFICATION_ID)
                }
            }
                .onFailure { appendDiagnostic("notification cancel failed during handleStop: ${it.message}") }
            runOnMainSync { stopSelf() }
        }
    }

    private fun handleFailure(
        message: String,
        extraLogLine: String? = null,
        stage: String? = null,
        identitySnapshot: TunnelSnapshot? = null,
    ) {
        synchronized(lifecycleLock) {
            appendDiagnostic("handleFailure entered. message=$message")
            prepareNextCdnFrontRetryIfAvailable()
            closeRuntimeResources("handleFailure")
            val current = VpnRuntimeStore.snapshot(this)
            val failureBase =
                identitySnapshot?.let { applyFailureIdentitySeed(current, it) }
                    ?: current
            val next =
                persistTerminalState(
                    failedSnapshot(failureBase, message, extraLogLine).copy(
                        lastNetworkEvent = "failure",
                        lastFailureStage = stage,
                        lastFailureCode = classifyRuntimeFailureCode(
                            listOfNotNull(message, extraLogLine).joinToString("\n"),
                            stage,
                        ),
                    ),
                )
            runOnMainSync { updateNotification(next) }
            runCatching { runOnMainSync { stopForeground(STOP_FOREGROUND_REMOVE) } }
                .onFailure { appendDiagnostic("stopForeground failed during handleFailure: ${it.message}") }
            runOnMainSync { stopSelf() }
        }
    }

    private fun prepareNextCdnFrontRetryIfAvailable() {
        val attempted = VpnRuntimeRestoreStore.readAttemptedStartRequest(this) ?: return
        val runtimeFamily = attempted.getString("runtimeFamily", null)?.trim().orEmpty()
        if (runtimeFamily != "cdn-anti-whitelist") {
            return
        }
        val advanced = VpnRuntimeLibbox.advanceCdnFrontOverrideForRetry(attempted)
        val previousTag = attempted.getString("frontTag", attempted.getString("cdnFrontTag", null))?.trim().orEmpty()
        val nextTag = advanced.getString("frontTag", advanced.getString("cdnFrontTag", null))?.trim().orEmpty()
        if (nextTag.isBlank() || nextTag == previousTag) {
            return
        }
        val previousSni = attempted.getString("cdnTlsServerName", attempted.getString("tlsServerName", null))?.trim().orEmpty()
        val nextSni = advanced.getString("cdnTlsServerName", advanced.getString("tlsServerName", null))?.trim().orEmpty()
        val previousHost = attempted.getString("frontHost", attempted.getString("cdnFrontHost", null))?.trim().orEmpty()
        val nextHost = advanced.getString("frontHost", advanced.getString("cdnFrontHost", null))?.trim().orEmpty()
        VpnRuntimeRestoreStore.persistAttemptedStartRequest(this, advanced)
        VpnRuntimeRestoreStore.persistStartRequest(this, advanced)
        VpnRuntimeRestoreStore.markResumeEligible(this, false)
        appendDiagnostic(
            "Prepared next CDN front candidate for the next manual retry. previousTag=$previousTag previousSni=${previousSni.ifBlank { "n/a" }} previousHost=${previousHost.ifBlank { "n/a" }} nextTag=$nextTag nextSni=${nextSni.ifBlank { "n/a" }} nextHost=${nextHost.ifBlank { "n/a" }}",
        )
    }

    private fun startPreparedRuntimeTunnel(
        prepared: PreparedRuntime,
        startedAt: Long,
    ): Long {
        if (prepared.skipVpnTunnel) {
            updateStartupStage("native_process_started")
            appendDiagnostic("Native sidecar runtime started without libbox CommandServer.")
            VpnRuntimeLibbox.waitForLocalSocks(prepared.socksAddress, 20_000)
            updateStartupStage("socks_ready")
            appendDiagnostic("Local SOCKS endpoint became ready at ${prepared.socksAddress}.")
            val startupDurationMs = SystemClock.elapsedRealtime() - startedAt
            appendDiagnostic("Android native sidecar startup completed in ${startupDurationMs}ms.")
            return startupDurationMs
        }
        var startupStage = "command_server_ready"
        val server = CommandServer(this, this)
        server.start()
        updateStartupStage(startupStage)
        commandServer = server
        appendDiagnostic("CommandServer started.")

        server.startOrReloadService(
            prepared.configContent,
            OverrideOptions().apply {
                autoRedirect = false
            },
        )
        startupStage = "service_started"
        updateStartupStage(startupStage)
        appendDiagnostic("libbox startOrReloadService completed.")
        VpnRuntimeLibbox.waitForLocalSocks(prepared.socksAddress, 20_000)
        startupStage = "socks_ready"
        updateStartupStage(startupStage)
        appendDiagnostic("Local SOCKS endpoint became ready at ${prepared.socksAddress}.")
        val startupDurationMs = SystemClock.elapsedRealtime() - startedAt
        appendDiagnostic("Android VPN runtime startup completed in ${startupDurationMs}ms.")
        return startupDurationMs
    }

    private fun closeRuntimeResources(origin: String) {
        if (shuttingDown) {
            appendDiagnostic("closeRuntimeResources ignored because shutdown is already in progress. origin=$origin")
            return
        }
        shuttingDown = true
        try {
            appendDiagnostic(
                "Closing runtime resources. origin=$origin commandServer=${commandServer != null} vkProcess=${vkProcess != null} nativeProcess=${nativeProcess != null} tun=${tunDescriptor != null} wakeLock=${wakeLock?.isHeld == true}",
            )
            val process = vkProcess
            val sidecarProcess = nativeProcess
            vkProcess = null
            nativeProcess = null
            lastVkProcessLogLine = null
            lastNativeProcessLogLine = null
            pendingVkCaptchaUrl = null
            lastOpenedVkCaptchaUrl = null
            vkTunnelStartPending = false
            vkTunnelActivationInFlight = false
            vkStartupStartedAtMs = 0L

            appendDiagnostic("Stopping libbox service before tearing down Android tunnel resources. origin=$origin")
            runCatching { commandServer?.closeService() }
                .onFailure { appendDiagnostic("commandServer.closeService failed during $origin: ${it.message}") }
            runCatching { commandServer?.close() }
                .onFailure { appendDiagnostic("commandServer.close failed during $origin: ${it.message}") }
            commandServer = null

            appendDiagnostic("Closing Android TUN descriptor. origin=$origin")
            runCatching { tunDescriptor?.close() }
                .onFailure { appendDiagnostic("tunDescriptor.close failed during $origin: ${it.message}") }
            tunDescriptor = null

            if (process != null) {
                appendDiagnostic("Stopping vk-turn-proxy bridge after libbox shutdown. origin=$origin")
                runCatching {
                    process.destroy()
                    if (!process.waitFor(750, TimeUnit.MILLISECONDS)) {
                        appendDiagnostic("vk-turn-proxy bridge did not exit after destroy(); forcing termination during $origin")
                        process.destroyForcibly()
                        process.waitFor(250, TimeUnit.MILLISECONDS)
                    }
                }.onFailure { appendDiagnostic("vkProcess teardown failed during $origin: ${it.message}") }
            }
            if (sidecarProcess != null) {
                appendDiagnostic("Stopping native sidecar after Android tunnel shutdown. origin=$origin")
                runCatching {
                    sidecarProcess.destroy()
                    if (!sidecarProcess.waitFor(750, TimeUnit.MILLISECONDS)) {
                        appendDiagnostic("native sidecar did not exit after destroy(); forcing termination during $origin")
                        sidecarProcess.destroyForcibly()
                        sidecarProcess.waitFor(250, TimeUnit.MILLISECONDS)
                    }
                }.onFailure { appendDiagnostic("nativeProcess teardown failed during $origin: ${it.message}") }
            }

            activeRuntime = null
            pendingNetworkReload?.let { mainHandler.removeCallbacks(it) }
            pendingNetworkReload = null
            networkReloadInFlight = false
            queuedNetworkReloadTrigger = null
            lastDeliveredUnderlyingNetworkHandle = null
            lastDeliveredUnderlyingInterfaceName = null
            closeAllDefaultInterfaceMonitors()
            releaseWakeLock()
            appendDiagnostic("Runtime resources closed. origin=$origin")
        } finally {
            shuttingDown = false
        }
    }

    private fun watchVkProcess(process: Process) {
        thread(name = "odin-one-vk-watch", isDaemon = true) {
            val exitCode = runCatching { process.waitFor() }.getOrDefault(-1)
            appendDiagnostic(
                "vk-turn-proxy watcher observed process exit. exitCode=$exitCode shuttingDown=$shuttingDown sameProcess=${process === vkProcess}",
            )
            if (shuttingDown || process !== vkProcess) {
                return@thread
            }
            val lastLine = lastVkProcessLogLine?.takeIf { it.isNotBlank() }
            handleFailure(
                message = "vk-turn-proxy Android bridge exited with code $exitCode",
                extraLogLine = lastLine?.let { "Last vk-turn-proxy log: $it" },
            )
        }
    }

    private fun watchNativeProcess(process: Process) {
        thread(name = "odin-one-native-watch", isDaemon = true) {
            val exitCode = runCatching { process.waitFor() }.getOrDefault(-1)
            appendDiagnostic(
                "Native sidecar watcher observed process exit. exitCode=$exitCode shuttingDown=$shuttingDown sameProcess=${process === nativeProcess}",
            )
            if (shuttingDown || process !== nativeProcess) {
                return@thread
            }
            val lastLine = lastNativeProcessLogLine?.takeIf { it.isNotBlank() }
            handleFailure(
                message = "Native Android sidecar exited with code $exitCode",
                extraLogLine = lastLine?.let { "Last native sidecar log: $it" },
            )
        }
    }

    private fun maybePromoteVkRuntimeToRunning(line: String) {
        val runtime = activeRuntime ?: return
        if (runtime.vkBinaryPath.isNullOrBlank()) {
            return
        }
        if (!line.contains("Established DTLS connection!") && !line.contains("relayed-address=")) {
            return
        }
        if (vkTunnelStartPending) {
            pendingVkCaptchaUrl = null
            val ready =
                captureRuntimeState { current ->
                    current.copy(
                        pendingCaptchaUrl = null,
                        lastRecoveryAction = "vk-relay:warmup-confirmed",
                        lastStartupStage = "relay_ready",
                    )
                }
            runOnMainSync { updateNotification(ready) }
            appendDiagnostic("VK relay warmup confirmed before Android VPN tunnel start.")
            scheduleVkTunnelActivation()
            return
        }
        val current = VpnRuntimeStore.snapshot(this)
        if (current.status == "running") {
            return
        }
        val running =
            captureRuntimeState(
                VpnRuntimeLibbox.newRunningSnapshot(current, runtime).copy(
                    pendingCaptchaUrl = null,
                    lastRecoveryAction = "vk-relay:warmup-confirmed",
                    lastStartupStage = "running",
                ),
            )
        pendingVkCaptchaUrl = null
        VpnRuntimeStore.write(this, running)
        runOnMainSync { updateNotification(running) }
        appendDiagnostic("VK relay warmup confirmed; Android VPN runtime transitioned to running state.")
    }

    private fun scheduleVkTunnelActivation() {
        if (!vkTunnelStartPending || vkTunnelActivationInFlight) {
            return
        }
        vkTunnelActivationInFlight = true
        thread(name = "odin-one-vk-activate-tunnel", isDaemon = true) {
            completeVkTunnelActivation()
        }
    }

    private fun completeVkTunnelActivation() {
        synchronized(lifecycleLock) {
            val prepared = activeRuntime ?: run {
                vkTunnelActivationInFlight = false
                return
            }
            if (prepared.vkBinaryPath.isNullOrBlank() || !vkTunnelStartPending || shuttingDown) {
                vkTunnelActivationInFlight = false
                return
            }
            try {
                appendDiagnostic("Establishing Android VPN tunnel after VK relay warmup confirmation.")
                updateStartupStage("command_server_ready")
                val startedAt = vkStartupStartedAtMs.takeIf { it > 0L } ?: SystemClock.elapsedRealtime()
                val startupDurationMs = startPreparedRuntimeTunnel(prepared, startedAt)
                val running =
                    captureRuntimeState(
                        VpnRuntimeLibbox.newRunningSnapshot(VpnRuntimeStore.snapshot(this), prepared).copy(
                            pendingCaptchaUrl = null,
                            lastNetworkEvent = "startup:running",
                            lastStartupDurationMs = startupDurationMs,
                            lastStartupStage = "running",
                            lastFailureStage = null,
                            lastFailureCode = null,
                            lastRecoveryAction = "vk-relay:warmup-confirmed",
                        ),
                    )
                pendingVkCaptchaUrl = null
                vkTunnelStartPending = false
                vkTunnelActivationInFlight = false
                vkStartupStartedAtMs = 0L
                runOnMainSync { updateNotification(running) }
                appendDiagnostic("Android VPN runtime transitioned to running state after VK relay warmup.")
            } catch (error: Exception) {
                vkTunnelStartPending = false
                vkTunnelActivationInFlight = false
                vkStartupStartedAtMs = 0L
                val failureCurrent = VpnRuntimeStore.snapshot(this)
                handleFailure(
                    message = error.message ?: "Android VPN runtime failed to finish VK relay startup.",
                    extraLogLine = "Android VPN startup aborted while establishing the tunnel after VK relay warmup.",
                    stage = failureCurrent.lastStartupStage ?: "relay_ready",
                )
            }
        }
    }

    private fun handleVkProcessLogLine(line: String) {
        lastVkProcessLogLine = line
        appendLog(line)
        maybeHandleVkCaptchaPrompt(line)
    }

    private fun handleNativeProcessLogLine(line: String) {
        lastNativeProcessLogLine = line
        appendLog(line)
    }

    private fun maybeHandleVkCaptchaPrompt(line: String) {
        val url = extractVkCaptchaUrl(line) ?: return
        if (pendingVkCaptchaUrl == url) {
            return
        }

        pendingVkCaptchaUrl = url
        val snapshot =
            VpnRuntimeStore.update(this) { current ->
                current.copy(
                    pendingCaptchaUrl = url,
                    lastRecoveryAction = "vk_manual_captcha",
                )
            }
        runOnMainSync { updateNotification(snapshot) }
        appendDiagnostic("VK manual captcha is ready: $url")
        openVkCaptchaUrl(url, "runtime_log")
    }

    private fun extractVkCaptchaUrl(line: String): String? {
        val marker = "Open this URL in your browser:"
        val index = line.indexOf(marker, ignoreCase = true)
        if (index < 0) {
            return null
        }
        val raw = line.substring(index + marker.length).trim()
        val candidate = raw.substringBefore(' ').trim().trimEnd('.', ',', ';')
        return if (candidate.startsWith("http://") || candidate.startsWith("https://")) {
            candidate
        } else {
            null
        }
    }

    private fun openVkCaptchaUrl(
        url: String,
        source: String,
    ) {
        if (lastOpenedVkCaptchaUrl == url) {
            return
        }

        val viewIntent =
            Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                addCategory(Intent.CATEGORY_BROWSABLE)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }

        runCatching {
            lastOpenedVkCaptchaUrl = url
            startActivity(viewIntent)
            appendDiagnostic("Opened VK captcha in browser. source=$source")
        }.onFailure { error ->
            lastOpenedVkCaptchaUrl = null
            appendDiagnostic("Failed to open VK captcha in browser. source=$source error=${error.message}")
        }
    }

    private fun shouldReuseActiveRuntime(
        snapshot: TunnelSnapshot,
        args: JSObject,
    ): Boolean {
        if (!isActiveTunnelStatus(snapshot.status) || !matchesTunnelRequest(snapshot, args)) {
            return false
        }
        return activeRuntime != null || commandServer != null || vkProcess != null || nativeProcess != null || tunDescriptor != null
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) {
            return
        }
        val powerManager = getSystemService(PowerManager::class.java)
        wakeLock =
            powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "OdinOne::VpnRuntime").apply {
                setReferenceCounted(false)
                acquire()
            }
    }

    private fun releaseWakeLock() {
        if (wakeLock?.isHeld == true) {
            wakeLock?.release()
        }
        wakeLock = null
    }

    private fun appendLog(line: String): TunnelSnapshot {
        return VpnRuntimeStore.update(this) { current ->
            current.copy(logTail = trimLogTail(current.logTail + line))
        }
    }

    private fun appendDiagnostic(line: String): TunnelSnapshot {
        Log.i(TAG, line)
        return appendLog(line)
    }

    private fun resolveStartArgs(rawArgs: String?): JSObject {
        if (!rawArgs.isNullOrBlank()) {
            val parsed =
                try {
                    VpnRuntimeLibbox.normalizeRuntimeArgs(this, JSObject(rawArgs), refreshRelayAutoselect = true)
                } catch (_: Exception) {
                    JSObject()
                }
            if (parsed.getString("startSource", null).isNullOrBlank()) {
                parsed.put("startSource", "external")
            }
            return parsed
        }

        val restored = VpnRuntimeRestoreStore.readStartRequest(this)
        if (restored != null && VpnRuntimeRestoreStore.isResumeEligible(this)) {
            val normalized = VpnRuntimeLibbox.normalizeRuntimeArgs(this, restored, refreshRelayAutoselect = true)
            normalized.put("startSource", "system_restore")
            appendDiagnostic("Restored Android VPN runtime request from persisted state for system-driven startup.")
            return normalized
        }
        appendDiagnostic("No resume-eligible Android VPN runtime request was available for system-driven startup.")
        return JSObject()
    }

    private fun decodeStartArgs(
        rawArgs: String?,
        encodedArgs: String?,
    ): String? {
        if (!encodedArgs.isNullOrBlank()) {
            val decoded =
                runCatching {
                    String(Base64.decode(encodedArgs, Base64.DEFAULT), Charsets.UTF_8)
                }.getOrNull()
            if (!decoded.isNullOrBlank()) {
                return decoded
            }
        }
        return rawArgs
    }

    private fun maybePersistRestorableState(args: JSObject) {
        if (args.getString("protocol", "")?.trim() != "vless-reality") {
            return
        }
        if (args.getString("runtimeFamily", null)?.trim() == "reality-whitelist-assisted" ||
            args.getString("runtimeFamily", null)?.trim() == "reality-vps-lab"
        ) {
            VpnRuntimeRestoreStore.markResumeEligible(this, false)
            return
        }
        if (args.getString("activationState", null)?.trim() == "scaffold_only") {
            return
        }
        val effectiveArgs =
            if (args.getBoolean("bootRestoreEnabled", false) || VpnRuntimeRestoreStore.isBootRestoreEnabled(this)) {
                VpnRuntimeLibbox.normalizeRuntimeArgs(withBootRestoreEnabled(args, true))
            } else {
                args
            }
        val runtimeFamily = effectiveArgs.getString("runtimeFamily", null)?.trim().orEmpty()
        val allowResumeEligibility =
            runtimeFamily != "cdn-anti-whitelist" || effectiveArgs.getBoolean("bootRestoreEnabled", false)
        VpnRuntimeRestoreStore.persistStartRequest(this, effectiveArgs)
        VpnRuntimeRestoreStore.markResumeEligible(this, allowResumeEligibility)
    }

    private fun notifyDefaultInterfaceUpdate(
        listener: InterfaceUpdateListener,
        network: Network,
        reason: String,
    ) {
        val connectivity = getSystemService(ConnectivityManager::class.java)
        val interfaceName = connectivity.getLinkProperties(network)?.interfaceName
        if (interfaceName.isNullOrBlank()) {
            appendDiagnostic("Default interface monitor skipped update because the interface name was empty. reason=$reason")
            return
        }
        val interfaceIndex = runCatching { NetworkInterface.getByName(interfaceName)?.index ?: -1 }.getOrDefault(-1)
        val networkHandle = networkHandleForComparison(network)
        val shouldProcess =
            synchronized(lifecycleLock) {
                val process =
                    shouldProcessUnderlyingInterfaceUpdate(
                        previousNetworkHandle = lastDeliveredUnderlyingNetworkHandle,
                        previousInterfaceName = lastDeliveredUnderlyingInterfaceName,
                        currentNetworkHandle = networkHandle,
                        currentInterfaceName = interfaceName,
                        reason = reason,
                    )
                if (process) {
                    lastDeliveredUnderlyingNetworkHandle = networkHandle
                    lastDeliveredUnderlyingInterfaceName = interfaceName
                }
                process
            }
        if (!shouldProcess) {
            return
        }
        listener.updateDefaultInterface(interfaceName, interfaceIndex, false, false)
        val event = "default-interface:$reason:$interfaceName"
        captureRuntimeState { current ->
            current.copy(
                lastNetworkEvent = event,
                networkChangeCount = current.networkChangeCount + 1,
                sessionNetworkChangeCount = current.sessionNetworkChangeCount + 1,
            )
        }
        if (reason != "initial") {
            scheduleNetworkReloadIfEnabled(event)
        }
        appendDiagnostic("Default interface update delivered. reason=$reason interface=$interfaceName index=$interfaceIndex")
    }

    private fun notifyCurrentUnderlyingInterface(
        listener: InterfaceUpdateListener,
        connectivity: ConnectivityManager,
        reason: String,
    ) {
        val underlying = VpnRuntimeLibbox.resolveUnderlyingDefaultNetwork(connectivity)
        if (underlying == null) {
            appendDiagnostic("Default interface monitor skipped update because no eligible non-VPN network was available. reason=$reason")
            return
        }
        notifyDefaultInterfaceUpdate(listener, underlying, reason)
    }

    private fun captureRuntimeState(snapshot: TunnelSnapshot): TunnelSnapshot {
        val next =
            snapshot.copy(
                lastStartupStage = normalizeRunningStartupStage(snapshot.status, snapshot.lastStartupStage),
                alwaysOnEnabled = readAlwaysOnEnabled(),
                lockdownEnabled = readLockdownEnabled(),
                resumeEligible = VpnRuntimeRestoreStore.isResumeEligible(this),
            )
        return VpnRuntimeStore.write(this, next, sync = true)
    }

    private fun captureRuntimeState(update: (TunnelSnapshot) -> TunnelSnapshot): TunnelSnapshot =
        VpnRuntimeStore.update(this, sync = true) { current ->
            update(current).let { next ->
                next.copy(
                    lastStartupStage = normalizeRunningStartupStage(next.status, next.lastStartupStage),
                alwaysOnEnabled = readAlwaysOnEnabled(),
                lockdownEnabled = readLockdownEnabled(),
                resumeEligible = VpnRuntimeRestoreStore.isResumeEligible(this),
                )
            }
        }

    private fun persistTerminalState(snapshot: TunnelSnapshot): TunnelSnapshot =
        VpnRuntimeStore.write(
            this,
            snapshot.copy(
                resumeEligible = VpnRuntimeRestoreStore.isResumeEligible(this),
            ),
            sync = true,
        )

    private fun updateStartupStage(stage: String) {
        captureRuntimeState { current ->
            current.copy(
                lastStartupStage = stage,
                lastFailureStage = null,
                lastFailureCode = null,
            )
        }
    }

    private fun readAlwaysOnEnabled(): Boolean? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return null
        }
        val platformValue = runCatching { isAlwaysOn }.getOrNull()
        if (platformValue == true) {
            return true
        }
        return readAlwaysOnPackageSetting()?.let { it == packageName } ?: platformValue
    }

    private fun readLockdownEnabled(): Boolean? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return null
        }
        val platformValue = runCatching { isLockdownEnabled }.getOrNull()
        if (platformValue == true) {
            return true
        }
        return readAlwaysOnLockdownSetting() ?: platformValue
    }

    private fun readAlwaysOnPackageSetting(): String? =
        runCatching {
            Settings.Secure.getString(contentResolver, "always_on_vpn_app")
                ?.trim()
                ?.takeUnless { it.isBlank() || it.equals("null", ignoreCase = true) }
        }.getOrNull()

    private fun readAlwaysOnLockdownSetting(): Boolean? =
        runCatching {
            when (Settings.Secure.getString(contentResolver, "always_on_vpn_lockdown")?.trim()?.lowercase()) {
                "1", "true" -> true
                "0", "false" -> false
                else -> null
            }
        }.getOrNull()

    private fun applyRecoveryCounters(
        current: TunnelSnapshot,
        snapshot: TunnelSnapshot,
        startSource: String?,
    ): TunnelSnapshot {
        val restoreStart = startSource == "system_restore" || startSource == "boot_restore"
        return snapshot.copy(
            networkChangeCount = current.networkChangeCount,
            reloadCount = current.reloadCount,
            restoreCount = current.restoreCount + if (restoreStart) 1 else 0,
            lastRecoveryAction =
                if (restoreStart) {
                    "restore:$startSource"
                } else {
                    current.lastRecoveryAction
                },
        )
    }

    private fun applyFailureIdentitySeed(
        current: TunnelSnapshot,
        identity: TunnelSnapshot,
    ): TunnelSnapshot =
        current.copy(
            vkLink = identity.vkLink,
            serverHost = identity.serverHost,
            transport = identity.transport,
            engine = identity.engine,
            protocol = identity.protocol,
            runtimeFamily = identity.runtimeFamily,
            activationState = identity.activationState,
            frontHost = identity.frontHost,
            frontPath = identity.frontPath,
            frontProvider = identity.frontProvider,
            frontTag = identity.frontTag,
            cdnRoutingDnsQueryStrategy = identity.cdnRoutingDnsQueryStrategy,
            cdnRoutingDomainStrategy = identity.cdnRoutingDomainStrategy,
            cdnRoutingDomainMatcher = identity.cdnRoutingDomainMatcher,
            cdnRoutingDirectRuleCount = identity.cdnRoutingDirectRuleCount,
            cdnRoutingBlockRuleCount = identity.cdnRoutingBlockRuleCount,
            cdnRoutingBlockSelectedFrontHost = identity.cdnRoutingBlockSelectedFrontHost,
            cdnDnsLocalResolverEnabled = identity.cdnDnsLocalResolverEnabled,
            selectedSniHint = identity.selectedSniHint,
            selectedCidrHint = identity.selectedCidrHint,
            whitelistHintSource = identity.whitelistHintSource,
            whitelistHintTag = identity.whitelistHintTag,
            startSource = identity.startSource,
            profileHash = identity.profileHash,
            configMode = identity.configMode,
            sessionId = identity.sessionId ?: current.sessionId,
            sessionStartedAt = identity.sessionStartedAt ?: current.sessionStartedAt,
            activeFeatures = identity.activeFeatures,
        )

    private fun recordRestoreTelemetry(
        source: String,
        action: String,
        detail: String,
        message: String,
    ) {
        appendDiagnostic(message)
        captureRuntimeState { current ->
            current.copy(
                lastRecoveryAction = "restore:$action:$source:$detail",
                lastNetworkEvent = "restore:$source:$detail",
            )
        }
    }

    private fun scheduleNetworkReloadIfEnabled(trigger: String) {
        val runtime = activeRuntime ?: return
        if (!runtime.networkReloadOnChange) {
            return
        }
        if (networkReloadInFlight) {
            queuedNetworkReloadTrigger = trigger
            captureRuntimeState { current ->
                current.copy(lastRecoveryAction = "reload:queued:$trigger")
            }
            appendDiagnostic("Queued experimental REALITY reload while another reload is already running. trigger=$trigger")
            return
        }
        val current = VpnRuntimeStore.snapshot(this)
        if (!isActiveTunnelStatus(current.status)) {
            return
        }
        val delayMs = runtime.networkReloadDebounceMs.coerceAtLeast(250L)
        pendingNetworkReload?.let { mainHandler.removeCallbacks(it) }
        val task =
            Runnable {
                pendingNetworkReload = null
                thread(name = "odin-one-vpn-network-reload", isDaemon = true) {
                    performNetworkReload(trigger)
                }
            }
        pendingNetworkReload = task
        mainHandler.postDelayed(task, delayMs)
        captureRuntimeState { latest ->
            latest.copy(lastRecoveryAction = "reload:scheduled:$trigger")
        }
        appendDiagnostic("Scheduled experimental REALITY reload in ${delayMs}ms. trigger=$trigger")
    }

    private fun performNetworkReload(trigger: String) {
        var nextTrigger: String? = null
        synchronized(lifecycleLock) {
            val runtime = activeRuntime ?: return
            if (!runtime.networkReloadOnChange) {
                return
            }
            val server = commandServer ?: return
            val current = VpnRuntimeStore.snapshot(this)
            if (!isActiveTunnelStatus(current.status)) {
                return
            }
            networkReloadInFlight = true
            captureRuntimeState { latest ->
                latest.copy(lastRecoveryAction = "reload:attempt:$trigger")
            }
            appendDiagnostic("Reloading active Android REALITY runtime after network change. trigger=$trigger")
            runCatching {
                server.startOrReloadService(
                    runtime.configContent,
                    OverrideOptions().apply {
                        autoRedirect = false
                    },
                )
                VpnRuntimeLibbox.waitForLocalSocks(runtime.socksAddress, 5_000)
            }.onSuccess {
                captureRuntimeState { latest ->
                    latest.copy(
                        reloadCount = latest.reloadCount + 1,
                        sessionReloadCount = latest.sessionReloadCount + 1,
                        lastRecoveryAction = "reload:success:$trigger",
                        lastNetworkEvent = "reload:$trigger",
                    )
                }
                appendDiagnostic("Experimental REALITY network reload completed. trigger=$trigger")
            }.onFailure { error ->
                captureRuntimeState { latest ->
                    latest.copy(
                        lastRecoveryAction = "reload:failed:$trigger",
                        logTail =
                            trimLogTail(
                                latest.logTail +
                                    "Experimental REALITY reload failed. trigger=$trigger error=${error.message ?: error::class.java.simpleName}",
                            ),
                    )
                }
                appendDiagnostic("Experimental REALITY network reload failed. trigger=$trigger error=${error.message}")
            }.also {
                networkReloadInFlight = false
                nextTrigger = queuedNetworkReloadTrigger
                queuedNetworkReloadTrigger = null
            }
        }
        nextTrigger?.let { queuedTrigger ->
            scheduleNetworkReloadIfEnabled("$queuedTrigger:deferred")
        }
    }

    private fun networkHandleForComparison(network: Network): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            network.networkHandle
        } else {
            network.hashCode().toLong()
        }

    private fun closeAllDefaultInterfaceMonitors() {
        val callbacks =
            synchronized(defaultInterfaceCallbacks) {
                val values = defaultInterfaceCallbacks.values.toList()
                defaultInterfaceCallbacks.clear()
                values
            }
        if (callbacks.isEmpty()) {
            return
        }
        val connectivity = getSystemService(ConnectivityManager::class.java)
        callbacks.forEach { callback ->
            runCatching { connectivity.unregisterNetworkCallback(callback) }
                .onFailure { appendDiagnostic("Failed to unregister default interface callback during shutdown: ${it.message}") }
        }
    }

    private fun runOnMainSync(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            block()
            return
        }
        val latch = CountDownLatch(1)
        val error = arrayOfNulls<Throwable>(1)
        mainHandler.post {
            try {
                block()
            } catch (throwable: Throwable) {
                error[0] = throwable
            } finally {
                latch.countDown()
            }
        }
        latch.await()
        error[0]?.let { throw it }
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val manager = getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(NOTIFICATION_CHANNEL_ID) != null) {
            return
        }
        manager.createNotificationChannel(
            NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "Odin's Cat VPN",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Foreground status for the Odin's Cat Android VPN runtime"
            },
        )
    }

    private fun startForeground(snapshot: TunnelSnapshot) {
        val notification = buildNotification(snapshot)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun updateNotification(snapshot: TunnelSnapshot) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, buildNotification(snapshot))
    }

    private fun buildNotification(
        state: TunnelSnapshot,
        titleOverride: String? = null,
        bodyOverride: String? = null,
    ): AndroidNotification {
        val launchIntent =
            state.pendingCaptchaUrl
                ?.takeIf { it.isNotBlank() }
                ?.let { url ->
                    Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                        addCategory(Intent.CATEGORY_BROWSABLE)
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                }
                ?: packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent =
            launchIntent?.let {
                PendingIntent.getActivity(
                    this,
                    0,
                    it,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
            }

        return NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle(titleOverride ?: "Odin's Cat")
            .setContentText(
                bodyOverride
                    ?: when {
                        !state.pendingCaptchaUrl.isNullOrBlank() ->
                            "VK captcha is waiting for confirmation. Tap to continue."
                        else -> state.error ?: state.logTail.lastOrNull() ?: "Preparing Android VPN runtime"
                    },
            )
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .apply {
                pendingIntent?.let { setContentIntent(it) }
            }.build()
    }

    private fun addAddresses(
        builder: Builder,
        iterator: io.nekohasekai.libbox.RoutePrefixIterator,
    ) {
        while (iterator.hasNext()) {
            val prefix = iterator.next()
            builder.addAddress(prefix.address(), prefix.prefix())
        }
    }

    private fun addRoutes(
        builder: Builder,
        iterator: io.nekohasekai.libbox.RoutePrefixIterator,
        fallbackAddress: String,
        fallbackPrefix: Int,
        hasTunnelAddress: Boolean,
    ) {
        if (iterator.hasNext()) {
            while (iterator.hasNext()) {
                val prefix = iterator.next()
                builder.addRoute(prefix.address(), prefix.prefix())
            }
            return
        }
        if (hasTunnelAddress) {
            builder.addRoute(fallbackAddress, fallbackPrefix)
        }
    }

    private fun addAllowedApps(
        builder: Builder,
        iterator: StringIterator,
    ) {
        while (iterator.hasNext()) {
            val packageName = iterator.next()
            runCatching { builder.addAllowedApplication(packageName) }
                .onFailure { Log.w("VpnRuntimeService", "addAllowedApplication failed for $packageName", it) }
        }
    }

    private fun excludeOwnPackageFromVpn(builder: Builder) {
        runCatching { builder.addDisallowedApplication(packageName) }
            .onSuccess {
                appendDiagnostic("Excluded $packageName from the Android VPN to avoid runtime routing loops.")
            }
            .onFailure { Log.w("VpnRuntimeService", "addDisallowedApplication failed for own package $packageName", it) }
    }

    private fun addDisallowedApps(
        builder: Builder,
        iterator: StringIterator,
    ) {
        while (iterator.hasNext()) {
            val packageName = iterator.next()
            runCatching { builder.addDisallowedApplication(packageName) }
                .onFailure { Log.w("VpnRuntimeService", "addDisallowedApplication failed for $packageName", it) }
        }
    }

    companion object {
        private const val TAG = "VpnRuntimeService"
        const val ACTION_START = "com.odinone.desktop.vk.action.START_VPN_RUNTIME"
        const val ACTION_STOP = "com.odinone.desktop.vk.action.STOP_VPN_RUNTIME"
        const val EXTRA_START_ARGS = "start_args"
        const val EXTRA_START_ARGS_BASE64 = "start_args_base64"

        private const val NOTIFICATION_ID = 7301
        private const val NOTIFICATION_CHANNEL_ID = "odin_one_vpn_runtime"
    }
}

private fun shouldKeepVpnServiceSticky(
    action: String?,
    snapshot: TunnelSnapshot,
): Boolean =
    when (action) {
        VpnRuntimeService.ACTION_STOP -> false
        VpnRuntimeService.ACTION_START -> true
        null -> snapshot.resumeEligible == true
        else -> snapshot.resumeEligible == true || isActiveTunnelStatus(snapshot.status)
    }

internal fun shouldProcessUnderlyingInterfaceUpdate(
    previousNetworkHandle: Long?,
    previousInterfaceName: String?,
    currentNetworkHandle: Long,
    currentInterfaceName: String,
    reason: String,
): Boolean {
    if (reason == "initial" || reason == "lost-replaced") {
        return true
    }
    return previousNetworkHandle != currentNetworkHandle || previousInterfaceName != currentInterfaceName
}
