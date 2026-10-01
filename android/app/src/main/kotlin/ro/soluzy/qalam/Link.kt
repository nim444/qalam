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
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import javax.crypto.spec.SecretKeySpec
import kotlin.concurrent.thread

/**
 * The connection to the paired Mac. **Wi-Fi first:** UDP to the Mac found over Bonjour (matched
 * by its id), a typed address, or where it answered last time. **USB as the fallback:** TCP to
 * 127.0.0.1, which `adb reverse` (set up by the Mac app) carries over the cable. Both are pinged
 * every 250 ms; pen frames go to Wi-Fi while it answers, to USB when it doesn't.
 *
 * Every frame is sealed (docs/protocol.md, v1): each link gets its own random session, so its
 * own keys and counters. Without a pairing, the Link only looks for Macs to pair with.
 *
 * One Link per screen session: [start] in onResume, [close] in onPause.
 */
class Link(private val context: Context, private val pairing: Pairing?, private val manualHost: String?) {

    enum class Kind(val label: String) { WIFI("Wi-Fi"), USB("USB") }

    /** A Mac seen on the network (or on the USB cable), for pairing. */
    class FoundMac(val name: String, val address: InetSocketAddress)

    class Status(
        val active: Kind?,
        val wifiRttMs: Float?, // null = not answering
        val usbRttMs: Float?,
        val wifiTarget: String?,
        val displayW: Int,
        val displayH: Int,
        val displayIndex: Int, // == displayCount means "all displays"
        val displayCount: Int,
        val displayName: String,
        val state: Wire.PadState?,
        val macs: List<FoundMac>, // unpaired only
    )

    /** One link's keys and counters: a fresh random session per connection. */
    private class Session(key: ByteArray) {
        val id = Crypto.randomLong()
        private val salt = Wire.le(ByteArray(8)).putLong(id).array()
        val tx = SecretKeySpec(Crypto.hkdf(key, salt, "qalam v1 phone to mac"), "AES")
        val rx = SecretKeySpec(Crypto.hkdf(key, salt, "qalam v1 mac to phone"), "AES")
        val counter = AtomicLong()
        val window = ReplayWindow()
    }

    private val nsd = context.getSystemService(NsdManager::class.java)
    private val sendExec = Executors.newSingleThreadExecutor() // every socket write goes through here
    private val timer = Executors.newSingleThreadScheduledExecutor()
    @Volatile private var running = false
    private val startedAt = System.nanoTime()

    private val udp = DatagramSocket().apply { soTimeout = 500 }
    private val wifiSession = pairing?.let { Session(it.key) }
    @Volatile private var wifiTarget: InetSocketAddress? = null
    @Volatile private var wifiPongAt = 0L
    @Volatile private var wifiRttUs = 0
    @Volatile private var rememberedHost: String? = null

    @Volatile private var tcp: Socket? = null
    @Volatile private var usbSession: Session? = null
    @Volatile private var usbPongAt = 0L
    @Volatile private var usbRttUs = 0
    @Volatile private var usbOpen = false // something answers on 127.0.0.1 (for pairing over USB)

    @Volatile private var display: Wire.Pong? = null // the newest pong describes the target display
    private val found = ConcurrentHashMap<String, FoundMac>()
    private val resolvers = ConcurrentHashMap<String, NsdManager.ServiceInfoCallback>()

    fun start() {
        running = true
        thread(name = "qalam-wifi-rx", isDaemon = true) { wifiReceiveLoop() }
        thread(name = "qalam-usb", isDaemon = true) { usbLoop() }
        timer.scheduleAtFixedRate({ sendExec.execute { tick() } }, 0, 250, TimeUnit.MILLISECONDS)
        if (!manualHost.isNullOrBlank()) {
            sendExec.execute { runCatching { wifiTarget = InetSocketAddress(InetAddress.getByName(manualHost), Wire.PORT) } }
        }
        runCatching { nsd.discoverServices(Wire.SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discovery) }
    }

    /** Sends a pen frame payload on the active link. */
    fun sendPen(payload: ByteArray) = sendOnActive(Wire.PEN, payload)

    /** Moves the pad to the next Mac display; the next pong (within 250 ms) brings its shape. */
    fun nextDisplay() = sendOnActive(Wire.DISPLAY, Wire.nextDisplay())

    /** A strip command (Wire.CMD_*). The Mac applies it and reports the result in its pongs. */
    fun control(cmd: Int, value: Int = 0) = sendOnActive(Wire.CONTROL, Wire.control(cmd, value))

    private fun sendOnActive(type: Int, payload: ByteArray) {
        if (!running || pairing == null) return
        sendExec.execute {
            when (active()) {
                Kind.WIFI -> sendWifi(type, payload)
                Kind.USB -> sendUsb(type, payload)
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
            wifiTarget = wifiTarget?.address?.hostAddress,
            displayW = display?.displayW ?: 0,
            displayH = display?.displayH ?: 0,
            displayIndex = display?.displayIndex ?: 0,
            displayCount = display?.displayCount ?: 0,
            displayName = display?.displayName ?: "",
            state = display?.state,
            macs = found.values.sortedBy { it.name } +
                (if (usbOpen) listOf(FoundMac("Mac on the USB cable", InetSocketAddress("127.0.0.1", Wire.PORT))) else emptyList()),
        )
    }

    /** Lets queued frames (e.g. the final "pen gone") go out, then shuts everything down. */
    fun close() {
        runCatching { nsd.stopServiceDiscovery(discovery) }
        resolvers.values.forEach { runCatching { nsd.unregisterServiceInfoCallback(it) } }
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

    private fun tick() {
        if (pairing == null) return
        // Bonjour hasn't found the Mac after 2 s: try where it answered last time.
        if (wifiTarget == null && System.nanoTime() - startedAt > 2_000_000_000L) {
            pairing.hosts.firstOrNull()?.let { h -> runCatching { wifiTarget = InetSocketAddress(InetAddress.getByName(h), Wire.PORT) } }
        }
        if (wifiTarget != null) sendWifi(Wire.PING, Wire.ping(System.nanoTime(), wifiRttUs))
        if (tcp != null) sendUsb(Wire.PING, Wire.ping(System.nanoTime(), usbRttUs))
    }

    private fun seal(s: Session, type: Int, payload: ByteArray): ByteArray {
        val c = s.counter.incrementAndGet()
        val h = Wire.header(type, pairing!!.id, s.id, c)
        return h + Crypto.seal(s.tx, Crypto.nonce(c), payload, h)
    }

    /** The payload of a sealed frame from the Mac on session [s], or null if it doesn't check out. */
    private fun open(s: Session, bytes: ByteArray, len: Int): Pair<Int, ByteArray>? {
        val h = Wire.parseHeader(bytes, len) ?: return null
        if (h.pairing != pairing?.id || h.session != s.id) return null
        val payload = Crypto.open(s.rx, Crypto.nonce(h.counter), bytes.copyOfRange(Wire.HEADER, len), bytes.copyOf(Wire.HEADER))
            ?: return null
        if (!s.window.accept(h.counter)) return null
        return h.type to payload
    }

    private fun onPong(payload: ByteArray, usb: Boolean, from: InetAddress?) {
        val pong = Wire.parsePong(payload) ?: return
        val now = System.nanoTime()
        if (usb) {
            usbRttUs = ((now - pong.tNs) / 1000).toInt()
            usbPongAt = now
        } else {
            wifiRttUs = ((now - pong.tNs) / 1000).toInt()
            wifiPongAt = now
            val host = from?.hostAddress
            if (host != null && host != rememberedHost) {
                rememberedHost = host
                PairingStore.rememberHost(context, host)
            }
        }
        display = pong
    }

    // MARK: Wi-Fi (UDP)

    private fun sendWifi(type: Int, payload: ByteArray) {
        val target = wifiTarget ?: return
        val s = wifiSession ?: return
        val frame = seal(s, type, payload)
        runCatching { udp.send(DatagramPacket(frame, frame.size, target)) }
    }

    private fun wifiReceiveLoop() {
        val buf = ByteArray(512)
        val packet = DatagramPacket(buf, buf.size)
        while (running) {
            try {
                udp.receive(packet)
            } catch (_: Exception) {
                continue // timeout, or closed (then running is false)
            }
            val s = wifiSession ?: continue
            val (type, payload) = open(s, buf, packet.length) ?: continue
            if (type == Wire.PONG) onPong(payload, usb = false, from = packet.address)
        }
    }

    // MARK: USB (TCP to 127.0.0.1, forwarded by adb reverse)

    private fun sendUsb(type: Int, payload: ByteArray) {
        val sock = tcp ?: return
        val s = usbSession ?: return
        val frame = seal(s, type, payload)
        val out = ByteArray(2 + frame.size)
        out[0] = (frame.size and 0xFF).toByte()
        out[1] = (frame.size shr 8).toByte()
        System.arraycopy(frame, 0, out, 2, frame.size)
        try {
            sock.getOutputStream().write(out)
        } catch (_: Exception) {
            runCatching { sock.close() }
        }
    }

    private fun usbLoop() {
        while (running) {
            try {
                Socket().use { sock ->
                    sock.tcpNoDelay = true
                    sock.connect(InetSocketAddress("127.0.0.1", Wire.PORT), 300)
                    usbOpen = true
                    if (pairing == null) {
                        // Unpaired: only note that a Mac is on the cable, so pairing can use it.
                        Thread.sleep(2000)
                        return@use
                    }
                    val s = Session(pairing.key)
                    usbSession = s
                    tcp = sock
                    val input = DataInputStream(sock.getInputStream())
                    val buf = ByteArray(1024)
                    while (running) {
                        val len = input.readUnsignedByte() or (input.readUnsignedByte() shl 8)
                        if (len > buf.size) break
                        input.readFully(buf, 0, len)
                        val (type, payload) = open(s, buf, len) ?: continue
                        if (type == Wire.PONG) onPong(payload, usb = true, from = null)
                    }
                }
            } catch (_: Exception) {
                // Nothing on 127.0.0.1 (no cable / no adb reverse) or the link dropped.
                usbOpen = false
            }
            tcp = null
            usbSession = null
            if (running) Thread.sleep(1000)
        }
    }

    // MARK: Bonjour

    private fun resolverFor(serviceName: String) = object : NsdManager.ServiceInfoCallback {
        override fun onServiceUpdated(info: NsdServiceInfo) {
            val addr = info.hostAddresses.firstOrNull { it is Inet4Address } ?: info.hostAddresses.firstOrNull() ?: return
            val target = InetSocketAddress(addr, info.port)
            val id = info.attributes["id"]?.let { String(it) }
            if (pairing == null) {
                found[serviceName] = FoundMac(info.serviceName, target)
            } else if (id == pairing.macId && manualHost.isNullOrBlank()) {
                wifiTarget = target // our Mac (by id), wherever it is now
            }
        }
        override fun onServiceLost() {
            found.remove(serviceName)
        }
        override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) {
            Log.w(TAG, "Bonjour resolve failed: $errorCode")
            resolvers.remove(serviceName)
        }
        override fun onServiceInfoCallbackUnregistered() {}
    }

    private val discovery = object : NsdManager.DiscoveryListener {
        override fun onServiceFound(info: NsdServiceInfo) {
            val name = info.serviceName
            if (resolvers.containsKey(name)) return
            val cb = resolverFor(name)
            resolvers[name] = cb
            // On the main thread, which outlives this Link: NsdManager still delivers a last
            // callback after close(), and a shut-down executor would reject it and crash the app.
            runCatching { nsd.registerServiceInfoCallback(info, context.mainExecutor, cb) }
        }
        override fun onServiceLost(info: NsdServiceInfo) {
            found.remove(info.serviceName)
        }
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
