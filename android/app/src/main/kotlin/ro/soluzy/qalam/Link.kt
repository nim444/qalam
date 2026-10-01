package ro.soluzy.qalam

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import java.io.DataInputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

/**
 * The connection to the Mac. **Wi-Fi first:** UDP to the Mac found over Bonjour (or a typed IP).
 * **USB as the fallback:** TCP to 127.0.0.1, which `adb reverse` (set up by qalam-m0 on the Mac)
 * carries over the cable. Both are pinged every 250 ms. Pen frames go to Wi-Fi while it answers,
 * to USB when it doesn't, and back to Wi-Fi as soon as it answers again.
 *
 * One Link per screen session: [start] in onResume, [close] in onPause.
 */
class Link(context: Context, private val manualHost: String?) {

    enum class Kind(val label: String) { WIFI("Wi-Fi"), USB("USB") }

    class Status(
        val active: Kind?,
        val wifiRttMs: Float?, // null = not answering
        val usbRttMs: Float?,
        val macName: String?,
        val wifiTarget: String?,
        val displayW: Int,
        val displayH: Int,
        val displayIndex: Int, // == displayCount means "all displays"
        val displayCount: Int,
        val displayName: String,
        val state: Wire.PadState?,
    )

    private val nsd = context.getSystemService(NsdManager::class.java)
    private val sendExec = Executors.newSingleThreadExecutor() // every socket write goes through here
    private val timer = Executors.newSingleThreadScheduledExecutor()
    @Volatile private var running = false

    private val udp = DatagramSocket().apply { soTimeout = 500 }
    @Volatile private var wifiTarget: InetSocketAddress? = null
    @Volatile private var macName: String? = null
    private val wifiCounter = AtomicInteger()
    @Volatile private var wifiPongAt = 0L
    @Volatile private var wifiRttUs = 0

    @Volatile private var tcp: Socket? = null
    private val usbCounter = AtomicInteger()
    @Volatile private var usbPongAt = 0L
    @Volatile private var usbRttUs = 0

    @Volatile private var display: Wire.Pong? = null // the newest pong describes the target display

    fun start() {
        running = true
        thread(name = "qalam-wifi-rx", isDaemon = true) { wifiReceiveLoop() }
        thread(name = "qalam-usb", isDaemon = true) { usbLoop() }
        timer.scheduleAtFixedRate({ sendExec.execute { pingAll() } }, 0, 250, TimeUnit.MILLISECONDS)
        if (manualHost.isNullOrBlank()) {
            nsd.discoverServices(Wire.SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discovery)
        } else {
            sendExec.execute {
                runCatching { wifiTarget = InetSocketAddress(InetAddress.getByName(manualHost), Wire.PORT) }
                macName = manualHost
            }
        }
    }

    /** Sends a pen frame on the active link. Its 8-byte header is filled in here. */
    fun sendPen(frame: ByteArray) {
        if (!running) return
        sendExec.execute {
            when (active()) {
                Kind.WIFI -> sendWifi(frame, Wire.PEN)
                Kind.USB -> sendUsb(frame, Wire.PEN)
                null -> {}
            }
        }
    }

    /** Moves the pad to the next Mac display; the next pong (within 250 ms) brings its shape. */
    fun nextDisplay() = sendOnActive(Wire.nextDisplay(), Wire.DISPLAY)

    /** A strip command (Wire.CMD_*). The Mac applies it and reports the result in its pongs. */
    fun control(cmd: Int, value: Int = 0) = sendOnActive(Wire.control(cmd, value), Wire.CONTROL)

    private fun sendOnActive(frame: ByteArray, type: Int) {
        if (!running) return
        sendExec.execute {
            when (active()) {
                Kind.WIFI -> sendWifi(frame, type)
                Kind.USB -> sendUsb(frame, type)
                null -> {}
            }
        }
    }

    fun status(): Status {
        val now = System.nanoTime()
        return Status(
            active = active(now),
            wifiRttMs = if (alive(wifiPongAt, now)) wifiRttUs / 1000f else null,
            usbRttMs = if (tcp != null && alive(usbPongAt, now)) usbRttUs / 1000f else null,
            macName = macName,
            wifiTarget = wifiTarget?.address?.hostAddress,
            displayW = display?.displayW ?: 0,
            displayH = display?.displayH ?: 0,
            displayIndex = display?.displayIndex ?: 0,
            displayCount = display?.displayCount ?: 0,
            displayName = display?.displayName ?: "",
            state = display?.state,
        )
    }

    /** Lets queued frames (e.g. the final "pen gone") go out, then shuts everything down. */
    fun close() {
        if (manualHost.isNullOrBlank()) runCatching { nsd.stopServiceDiscovery(discovery) }
        if (resolving) runCatching { nsd.unregisterServiceInfoCallback(resolver) }
        timer.shutdownNow()
        sendExec.execute {
            running = false
            udp.close()
            runCatching { tcp?.close() }
        }
        sendExec.shutdown()
    }

    private fun alive(pongAt: Long, now: Long) = pongAt != 0L && now - pongAt < ALIVE_NS

    private fun active(now: Long = System.nanoTime()): Kind? = when {
        alive(wifiPongAt, now) -> Kind.WIFI
        tcp != null && alive(usbPongAt, now) -> Kind.USB
        wifiTarget != null -> Kind.WIFI // nothing answering yet: keep trying Wi-Fi
        else -> null
    }

    private fun pingAll() {
        val t = System.nanoTime()
        if (wifiTarget != null) sendWifi(Wire.ping(0, t, wifiRttUs), Wire.PING)
        if (tcp != null) sendUsb(Wire.ping(0, t, usbRttUs), Wire.PING)
    }

    // MARK: Wi-Fi (UDP)

    private fun sendWifi(frame: ByteArray, type: Int) {
        val target = wifiTarget ?: return
        Wire.header(frame, type, wifiCounter.incrementAndGet())
        runCatching { udp.send(DatagramPacket(frame, frame.size, target)) }
    }

    private fun wifiReceiveLoop() {
        val buf = ByteArray(256)
        val packet = DatagramPacket(buf, buf.size)
        while (running) {
            try {
                udp.receive(packet)
            } catch (_: Exception) {
                continue // timeout, or closed (then running is false)
            }
            val pong = Wire.parsePong(buf, packet.length) ?: continue
            val now = System.nanoTime()
            wifiRttUs = ((now - pong.tNs) / 1000).toInt()
            wifiPongAt = now
            display = pong
        }
    }

    // MARK: USB (TCP to 127.0.0.1, forwarded by adb reverse)

    private fun sendUsb(frame: ByteArray, type: Int) {
        val s = tcp ?: return
        Wire.header(frame, type, usbCounter.incrementAndGet())
        val out = ByteArray(2 + frame.size)
        out[0] = (frame.size and 0xFF).toByte()
        out[1] = (frame.size shr 8).toByte()
        System.arraycopy(frame, 0, out, 2, frame.size)
        try {
            s.getOutputStream().write(out)
        } catch (_: Exception) {
            runCatching { s.close() }
        }
    }

    private fun usbLoop() {
        while (running) {
            try {
                Socket().use { s ->
                    s.tcpNoDelay = true
                    s.connect(InetSocketAddress("127.0.0.1", Wire.PORT), 300)
                    usbCounter.set(0)
                    tcp = s
                    val input = DataInputStream(s.getInputStream())
                    val buf = ByteArray(1024)
                    while (running) {
                        val len = input.readUnsignedByte() or (input.readUnsignedByte() shl 8)
                        if (len > buf.size) break
                        input.readFully(buf, 0, len)
                        val pong = Wire.parsePong(buf, len) ?: continue
                        val now = System.nanoTime()
                        usbRttUs = ((now - pong.tNs) / 1000).toInt()
                        usbPongAt = now
                        display = pong
                    }
                }
            } catch (_: Exception) {
                // Nothing on 127.0.0.1 (no cable / no adb reverse) or the link dropped.
            }
            tcp = null
            if (running) Thread.sleep(1000)
        }
    }

    // MARK: Bonjour

    @Volatile private var resolving = false

    private val resolver = object : NsdManager.ServiceInfoCallback {
        override fun onServiceUpdated(info: NsdServiceInfo) {
            val addr = info.hostAddresses.firstOrNull { it is Inet4Address } ?: info.hostAddresses.firstOrNull() ?: return
            wifiTarget = InetSocketAddress(addr, info.port)
            macName = info.serviceName
        }
        override fun onServiceLost() {}
        override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) {
            Log.w(TAG, "Bonjour resolve failed: $errorCode")
            resolving = false
        }
        override fun onServiceInfoCallbackUnregistered() {}
    }

    private val discovery = object : NsdManager.DiscoveryListener {
        override fun onServiceFound(info: NsdServiceInfo) {
            if (resolving) return // first Mac wins (M0); pairing picks the right one in M2
            resolving = true
            nsd.registerServiceInfoCallback(info, Executors.newSingleThreadExecutor(), resolver)
        }
        override fun onServiceLost(info: NsdServiceInfo) {}
        override fun onDiscoveryStarted(serviceType: String) {}
        override fun onDiscoveryStopped(serviceType: String) {}
        override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
            Log.w(TAG, "Bonjour discovery failed: $errorCode")
        }
        override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
    }

    private companion object {
        const val TAG = "QalamLink"
        const val ALIVE_NS = 1_000_000_000L // a link is "up" if it answered within the last second
    }
}
