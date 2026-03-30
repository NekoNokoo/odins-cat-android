package com.odinone.desktop.vk

import android.app.Notification as AndroidNotification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.ProxyInfo
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.util.Log
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
    private var activeRuntime: PreparedRuntime? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var lastVkProcessLogLine: String? = null

    @Volatile
    private var shuttingDown = false
    private val lifecycleLock = Any()
    private val mainHandler = Handler(Looper.getMainLooper())

    private var systemProxyAvailable = false
    private var systemProxyEnabled = false

    override fun onCreate() {
        super.onCreate()
        VpnRuntimeLibbox.ensureInitialized(this)
        ensureNotificationChannel()
        appendDiagnostic("VpnRuntimeService created.")
    }

    override fun onStartCommand(
        intent: Intent?,
        flags: Int,
        startId: Int,
    ): Int {
        val action = intent?.action
        appendDiagnostic(
            "onStartCommand action=${action ?: "<null>"} flags=$flags startId=$startId currentStatus=${VpnRuntimeStore.snapshot(this).status}",
        )
        when (action) {
            ACTION_START -> {
                appendDiagnostic("Received ACTION_START intent.")
                val rawArgs = intent.getStringExtra(EXTRA_START_ARGS)
                thread(name = "odin-one-vpn-start", isDaemon = true) {
                    handleStart(rawArgs)
                }
            }

            ACTION_STOP -> {
                appendDiagnostic("Received ACTION_STOP intent from app/plugin layer.")
                thread(name = "odin-one-vpn-stop", isDaemon = true) {
                    handleStop(requestedByUser = true, reason = "ACTION_STOP intent")
                }
            }

            null -> {
                appendDiagnostic("Ignoring null onStartCommand intent to avoid accidental VPN shutdown.")
            }

            else -> {
                appendDiagnostic("Ignoring unexpected onStartCommand action=$action to avoid accidental VPN shutdown.")
            }
        }
        return START_NOT_STICKY
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
                    error = null,
                    logTail = trimLogTail(latest.logTail + "Android VpnService was destroyed."),
                ),
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
                .setSession("Odin One")
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
        val current = VpnRuntimeStore.snapshot(this)
        val next =
            VpnRuntimeStore.write(
                this,
                current.copy(
                    status = "running",
                    error = null,
                    logTail = trimLogTail(current.logTail + "Android VpnService established the system VPN interface."),
                ),
            )
        runOnMainSync { updateNotification(next) }
        return descriptor.fd
    }

    override fun readWIFIState(): WIFIState? = VpnRuntimeLibbox.readWifiState(this)

    override fun registerMyInterface(name: String) {
    }

    override fun sendNotification(notification: Notification) {
        val title = notification.title.takeUnless { it.isNullOrBlank() } ?: "Odin One"
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
        val network = connectivity.activeNetwork ?: return
        val interfaceName = connectivity.getLinkProperties(network)?.interfaceName ?: return
        val interfaceIndex = runCatching { NetworkInterface.getByName(interfaceName)?.index ?: -1 }.getOrDefault(-1)
        listener.updateDefaultInterface(interfaceName, interfaceIndex, false, false)
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
            val args = try {
                JSObject(rawArgs ?: "{}")
            } catch (_: Exception) {
                JSObject()
            }
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
                startSnapshotFromArgs(args, "Android VPN permission granted. Preparing native runtime..."),
            )

            runOnMainSync { startForeground(base) }
            acquireWakeLock()

            try {
                appendDiagnostic("handleStart entered.")
                closeRuntimeResources("handleStart")
                appendLog("Initializing libbox runtime.")
                val prepared = VpnRuntimeLibbox.prepareRuntime(this, args)
                activeRuntime = prepared
                appendLog("Validated Android runtime config: ${prepared.configPath}")
                prepared.remotePeer?.let { appendLog("VK relay remote peer: $it") }

                val server = CommandServer(this, this)
                server.start()
                commandServer = server
                appendDiagnostic("CommandServer started.")

                if (!prepared.vkBinaryPath.isNullOrBlank()) {
                    vkProcess = VpnRuntimeLibbox.startVkTurnProcess(prepared) { line ->
                        lastVkProcessLogLine = line
                        appendLog(line)
                        maybePromoteVkRuntimeToRunning(line)
                    }.also { process ->
                        watchVkProcess(process)
                    }
                }

                server.startOrReloadService(
                    prepared.configContent,
                    OverrideOptions().apply {
                        autoRedirect = false
                    },
                )
                appendDiagnostic("libbox startOrReloadService completed.")
                VpnRuntimeLibbox.waitForLocalSocks(prepared.socksAddress, 20_000)
                appendDiagnostic("Local SOCKS endpoint became ready at ${prepared.socksAddress}.")

                if (!prepared.vkBinaryPath.isNullOrBlank()) {
                    val waiting = VpnRuntimeLibbox.newVkWarmupSnapshot(VpnRuntimeStore.snapshot(this), prepared)
                    VpnRuntimeStore.write(this, waiting)
                    runOnMainSync { updateNotification(waiting) }
                    appendDiagnostic("Android VPN runtime is waiting for VK relay warmup.")
                } else {
                    val running = VpnRuntimeLibbox.newRunningSnapshot(VpnRuntimeStore.snapshot(this), prepared)
                    VpnRuntimeStore.write(this, running)
                    runOnMainSync { updateNotification(running) }
                    appendDiagnostic("Android VPN runtime transitioned to running state.")
                }
            } catch (error: Exception) {
                handleFailure(
                    message = error.message ?: "Android VPN runtime failed to start.",
                    extraLogLine = "Android VPN startup aborted before the tunnel became ready.",
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
            closeRuntimeResources("handleStop:$reason")
            val current = VpnRuntimeStore.snapshot(this)
            VpnRuntimeStore.write(
                this,
                current.copy(
                    status = "stopped",
                    error = null,
                    lastTest = current.lastTest,
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
    ) {
        synchronized(lifecycleLock) {
            appendDiagnostic("handleFailure entered. message=$message")
            closeRuntimeResources("handleFailure")
            val next = VpnRuntimeStore.write(
                this,
                failedSnapshot(VpnRuntimeStore.snapshot(this), message, extraLogLine),
            )
            runOnMainSync { updateNotification(next) }
            runCatching { runOnMainSync { stopForeground(STOP_FOREGROUND_REMOVE) } }
                .onFailure { appendDiagnostic("stopForeground failed during handleFailure: ${it.message}") }
            runOnMainSync { stopSelf() }
        }
    }

    private fun closeRuntimeResources(origin: String) {
        if (shuttingDown) {
            appendDiagnostic("closeRuntimeResources ignored because shutdown is already in progress. origin=$origin")
            return
        }
        shuttingDown = true
        try {
            appendDiagnostic(
                "Closing runtime resources. origin=$origin commandServer=${commandServer != null} vkProcess=${vkProcess != null} tun=${tunDescriptor != null} wakeLock=${wakeLock?.isHeld == true}",
            )
            val process = vkProcess
            vkProcess = null
            lastVkProcessLogLine = null

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

            activeRuntime = null
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

    private fun maybePromoteVkRuntimeToRunning(line: String) {
        val runtime = activeRuntime ?: return
        if (runtime.vkBinaryPath.isNullOrBlank()) {
            return
        }
        if (!line.contains("Established DTLS connection!") && !line.contains("relayed-address=")) {
            return
        }
        val current = VpnRuntimeStore.snapshot(this)
        if (current.status == "running") {
            return
        }
        val running = VpnRuntimeLibbox.newRunningSnapshot(current, runtime)
        VpnRuntimeStore.write(this, running)
        runOnMainSync { updateNotification(running) }
        appendDiagnostic("VK relay warmup confirmed; Android VPN runtime transitioned to running state.")
    }

    private fun shouldReuseActiveRuntime(
        snapshot: TunnelSnapshot,
        args: JSObject,
    ): Boolean {
        if (!isActiveTunnelStatus(snapshot.status) || !matchesTunnelRequest(snapshot, args)) {
            return false
        }
        return activeRuntime != null || commandServer != null || vkProcess != null || tunDescriptor != null
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
        val current = VpnRuntimeStore.snapshot(this)
        val next = current.copy(logTail = trimLogTail(current.logTail + line))
        return VpnRuntimeStore.write(this, next)
    }

    private fun appendDiagnostic(line: String): TunnelSnapshot {
        Log.i(TAG, line)
        return appendLog(line)
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
                "Odin One VPN",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Foreground status for the Odin One Android VPN runtime"
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
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent =
            launchIntent?.let {
                PendingIntent.getActivity(
                    this,
                    0,
                    it,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
            }

        val builder =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                AndroidNotification.Builder(this, NOTIFICATION_CHANNEL_ID)
            } else {
                AndroidNotification.Builder(this)
            }

        builder
            .setContentTitle(titleOverride ?: "Odin One")
            .setContentText(bodyOverride ?: state.error ?: state.logTail.lastOrNull() ?: "Preparing Android VPN runtime")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
        pendingIntent?.let { builder.setContentIntent(it) }
        return builder.build()
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

        private const val NOTIFICATION_ID = 7301
        private const val NOTIFICATION_CHANNEL_ID = "odin_one_vpn_runtime"
    }
}
