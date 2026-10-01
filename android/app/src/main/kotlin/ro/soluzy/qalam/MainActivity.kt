package ro.soluzy.qalam

import android.app.Activity
import android.app.AlertDialog
import android.graphics.Typeface
import android.net.wifi.WifiManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import java.net.InetAddress
import java.net.InetSocketAddress
import kotlin.concurrent.thread

/**
 * The pen pad on the left, the strip on the right: link status, Cursor / Ink, the ink tools,
 * colours, size, undo and clear, and the target display. The Mac owns the state; the strip shows
 * a tap straight away and then follows what the Mac reports in its pongs. Until the phone is
 * paired, a pairing panel covers the pad.
 */
class MainActivity : Activity() {

    private lateinit var pad: PadView
    private lateinit var status: TextView
    private lateinit var footer: TextView
    private lateinit var cursorChip: Chip
    private lateinit var inkChip: Chip
    private lateinit var displayChip: Chip
    private lateinit var inkRows: List<View>
    private lateinit var controls: List<View>
    private lateinit var panel: PairingPanel
    private var pairing: Pairing? = null
    private var pairer: Pairer? = null
    private val tools = mutableListOf<IconButton>()
    private val swatches = mutableListOf<Swatch>()
    private val sizes = mutableListOf<Chip>()

    private var link: Link? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private val prefs by lazy { getSharedPreferences("qalam", MODE_PRIVATE) }

    private var state = Wire.PadState(mode = 0, tool = 0, color = 0, size = 1)
    private var localChangeAt = 0L // a tap wins over pongs for a moment, so the strip doesn't flicker back

    private val ui = Handler(Looper.getMainLooper())
    private var lastTick = 0L
    private val tick = object : Runnable {
        override fun run() {
            refresh()
            ui.postDelayed(this, 250)
        }
    }

    private val dp by lazy { resources.displayMetrics.density }
    private fun px(v: Int) = (v * dp).toInt()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        pad = PadView(this).apply { onFrame = { frame -> link?.sendPen(frame) } }

        status = TextView(this).apply { textSize = 12f; setTextColor(Palette.MUTED) }
        footer = TextView(this).apply {
            textSize = 11f
            setTextColor(Palette.MUTED)
            setPadding(0, px(6), 0, 0)
            setOnClickListener { if (pairing != null) showPairedMenu() else askForHost() }
        }

        cursorChip = Chip(this, "Cursor").apply { onTap { change(Wire.CMD_MODE, 0) { it.copy(mode = 0) } } }
        inkChip = Chip(this, "Ink").apply { onTap { change(Wire.CMD_MODE, 1) { it.copy(mode = 1) } } }

        Tool.entries.forEachIndexed { i, tool ->
            tools += IconButton(this, tool.icon).apply {
                contentDescription = tool.name.lowercase()
                onTap { change(Wire.CMD_TOOL, i) { it.copy(mode = 1, tool = i) } }
            }
        }
        Palette.colors.forEachIndexed { i, color ->
            swatches += Swatch(this, color).apply {
                // A colour means writing with it: back to the pen if the eraser or laser was on.
                onTap { change(Wire.CMD_COLOR, i) { it.copy(mode = 1, color = i, tool = if (it.tool >= 2) 0 else it.tool) } }
            }
        }
        Palette.sizes.forEachIndexed { i, label ->
            sizes += Chip(this, label).apply { onTap { change(Wire.CMD_SIZE, i) { it.copy(size = i) } } }
        }
        val undo = IconButton(this, Icon.UNDO).apply {
            contentDescription = "undo"
            onTap { pad.undoInk(); link?.control(Wire.CMD_UNDO) }
        }
        val clear = IconButton(this, Icon.CLEAR).apply {
            contentDescription = "clear"
            onTap { pad.clearInk(); link?.control(Wire.CMD_CLEAR) }
        }
        displayChip = Chip(this, "Display").apply { onTap { link?.nextDisplay() } }

        val toolRow = row(tools, 40)
        val colorRow = row(swatches, 30, gap = 2)
        val sizeRow = row(sizes, 30)
        inkRows = listOf(toolRow, colorRow, sizeRow)
        val modeRow = row(listOf(cursorChip, inkChip), 36)
        val editRow = row(listOf(undo, clear), 36)
        val displayRow = row(listOf(displayChip), 34)
        controls = listOf(modeRow, toolRow, colorRow, sizeRow, editRow, displayRow)

        panel = PairingPanel(this).apply {
            onPick = { mac -> pairWith(mac.name, mac.address) }
            onAddress = { askForHost(pairing = true) }
            onCancel = { cancelPairing() }
        }
        pairing = PairingStore.load(this)

        val strip = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(0xFF111114.toInt())
            setPadding(px(12), px(14), px(12), px(10))
            addView(TextView(context).apply {
                text = "Qalam"
                textSize = 18f
                typeface = Typeface.DEFAULT_BOLD
                setTextColor(Palette.TEXT)
            })
            addView(status)
            addView(modeRow)
            addView(toolRow)
            addView(colorRow)
            addView(sizeRow)
            addView(editRow)
            addView(View(context), LinearLayout.LayoutParams(0, 0, 1f)) // spacer
            addView(displayRow)
            addView(footer)
        }

        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(FrameLayout(context).apply {
                addView(pad)
                addView(panel, FrameLayout.LayoutParams(px(400), ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER))
            }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f))
            addView(strip, LinearLayout.LayoutParams(px(196), ViewGroup.LayoutParams.MATCH_PARENT))
        })
        render()
        showPairingState()
    }

    /** A row of equal-width views, [heightDp] tall, with [gap] dp between them. */
    private fun row(views: List<View>, heightDp: Int, gap: Int = 6) = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, px(heightDp)).apply { topMargin = px(8) }
        views.forEachIndexed { i, v ->
            addView(v, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f).apply {
                if (i > 0) marginStart = px(gap)
            })
        }
    }

    private fun change(cmd: Int, value: Int, update: (Wire.PadState) -> Wire.PadState) {
        state = update(state)
        localChangeAt = SystemClock.uptimeMillis()
        render()
        link?.control(cmd, value)
    }

    override fun onResume() {
        super.onResume()
        hideSystemBars()
        // Wi-Fi power saving adds 50–200 ms spikes; low-latency mode keeps the radio awake.
        wifiLock = getSystemService(WifiManager::class.java)
            .createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "qalam")
            .apply { acquire() }
        startLink()
        ui.post(tick)
    }

    override fun onPause() {
        ui.removeCallbacks(tick)
        cancelPairing()
        pad.penGone() // releases anything held on the Mac before the link closes
        link?.close()
        link = null
        wifiLock?.release()
        wifiLock = null
        super.onPause()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemBars()
    }

    private fun startLink() {
        link = Link(this, pairing, prefs.getString(PREF_HOST, null)).also { it.start() }
    }

    private fun restartLink() {
        link?.close()
        startLink()
    }

    // MARK: Pairing

    /** Shows the pairing panel and greys the strip until there's a pairing. */
    private fun showPairingState() {
        val paired = pairing != null
        panel.visibility = if (paired) View.GONE else View.VISIBLE
        if (!paired) panel.showChoose(link?.status()?.macs ?: emptyList())
        controls.forEach { row ->
            row.alpha = if (paired) 1f else 0.3f
            (row as ViewGroup).let { g -> for (i in 0 until g.childCount) g.getChildAt(i).isEnabled = paired }
        }
        render()
    }

    private fun pairWith(name: String, address: InetSocketAddress) {
        cancelPairing()
        panel.showContacting(name)
        pairer = Pairer(address, phoneName(), object : Pairer.Listener {
            override fun onCode(code: String, macName: String) = runOnUiThread { panel.showCode(code, macName) }
            override fun onFailed(why: String) = runOnUiThread {
                pairer = null
                panel.showChoose(link?.status()?.macs ?: emptyList(), why)
            }
            override fun onPaired(pairing: Pairing) = runOnUiThread {
                pairer = null
                PairingStore.save(this@MainActivity, pairing)
                this@MainActivity.pairing = pairing
                Toast.makeText(this@MainActivity, "Paired with ${pairing.macName}", Toast.LENGTH_SHORT).show()
                showPairingState()
                restartLink()
            }
        }).also { it.start() }
    }

    private fun cancelPairing() {
        pairer?.cancel()
        pairer = null
        if (pairing == null && ::panel.isInitialized) panel.showChoose(link?.status()?.macs ?: emptyList())
    }

    /** The name the Mac shows, e.g. "Galaxy S26 Ultra". */
    private fun phoneName(): String =
        Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME)?.takeIf { it.isNotBlank() } ?: android.os.Build.MODEL

    private fun showPairedMenu() {
        val p = pairing ?: return
        AlertDialog.Builder(this)
            .setTitle("Paired with ${p.macName}")
            .setItems(arrayOf("Mac address…", "Forget this Mac")) { _, which ->
                if (which == 0) askForHost() else confirmForget()
            }
            .show()
    }

    private fun confirmForget() {
        AlertDialog.Builder(this)
            .setTitle("Forget ${pairing?.macName}?")
            .setMessage("You'll have to pair again before the pen works. Also forget the phone in the Mac's menu (Paired phones).")
            .setPositiveButton("Forget") { _, _ ->
                PairingStore.clear(this)
                pairing = null
                pad.clearInk()
                showPairingState()
                restartLink()
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun refresh() {
        val s = link?.status() ?: return
        if (pairing == null) {
            panel.updateMacs(s.macs)
            status.text = "● not paired"
            status.setTextColor(0xFFE0A030.toInt())
            footer.text = "Mac address…"
            return
        }
        pad.setDisplay(s.displayIndex, s.displayW, s.displayH)
        if (s.state != null && SystemClock.uptimeMillis() - localChangeAt > 800 && s.state != state) {
            state = s.state
            render()
        }
        val ink = s.state
        if (ink?.inkStrokes != null && ink.inkHistory != null) pad.reconcile(ink.inkStrokes, ink.inkHistory)

        val now = System.nanoTime()
        val seconds = if (lastTick == 0L) 0.25 else (now - lastTick) / 1e9
        lastTick = now
        val rate = pad.takeSampleCount() / seconds

        val rtt = when (s.active) {
            Link.Kind.WIFI -> s.wifiRttMs
            Link.Kind.USB -> s.usbRttMs
            null -> null
        }
        status.text = when {
            s.active != null && rtt != null -> "● ${s.active.label} · %.1f ms".format(rtt)
            s.wifiTarget != null -> "● trying Wi-Fi…"
            else -> "● looking for the Mac…"
        }
        status.setTextColor(
            when {
                rtt == null -> 0xFFE0A030.toInt()
                s.active == Link.Kind.WIFI -> Palette.ACCENT
                else -> 0xFF7AA2F7.toInt()
            }
        )
        displayChip.setText(
            when {
                s.displayCount == 0 -> "Display"
                s.displayIndex >= s.displayCount -> "All displays"
                else -> "${s.displayName} ${s.displayIndex + 1}/${s.displayCount}"
            }
        )
        displayChip.isEnabled = s.displayCount > 1
        footer.text = "${pairing?.macName ?: "Mac"} ⋯  ·  %.0f samples/s".format(rate)
    }

    private fun render() {
        val ink = state.mode == 1
        cursorChip.isSelected = !ink
        inkChip.isSelected = ink
        tools.forEachIndexed { i, b -> b.isSelected = ink && state.tool == i }
        swatches.forEachIndexed { i, b -> b.isSelected = state.color == i }
        sizes.forEachIndexed { i, b -> b.isSelected = state.size == i }
        inkRows.forEach { it.alpha = if (ink) 1f else 0.45f } // still tappable: a tool switches to Ink

        pad.inkMode = ink
        pad.inkTool = state.tool
        pad.inkColor = state.color
        pad.inkSize = state.size
        val tool = Tool.entries.getOrElse(state.tool) { Tool.PEN }
        pad.label = if (ink) "Ink · ${tool.name.lowercase().replaceFirstChar { it.uppercase() }}" else "Cursor"
        pad.edgeColor = when {
            !ink -> null
            tool == Tool.LASER -> 0xFFFF2D55.toInt()
            tool == Tool.ERASER -> Palette.TEXT
            state.color == 4 -> Palette.MUTED // black would vanish on the dark pad
            else -> Palette.colors.getOrElse(state.color) { Palette.ACCENT }
        }
    }

    /** A typed Mac address: saved for the link, and (with [pairing]) paired with straight away. */
    private fun askForHost(pairing: Boolean = false) {
        val input = EditText(this).apply {
            hint = if (pairing) "e.g. 192.168.1.20" else "blank = find it automatically"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
            setText(prefs.getString(PREF_HOST, ""))
            gravity = Gravity.CENTER
        }
        AlertDialog.Builder(this)
            .setTitle("Mac address")
            .setMessage(if (pairing) "For when your Mac isn't listed. On the Mac, its address is in System Settings → Wi-Fi → Details."
                        else "Only needed if the phone can't find the Mac by itself (Bonjour).")
            .setView(input)
            .setPositiveButton(if (pairing) "Pair" else "Save") { _, _ ->
                val host = input.text.toString().trim()
                prefs.edit().putString(PREF_HOST, host).apply()
                if (pairing && host.isNotEmpty()) {
                    thread { // the name lookup can't run on the UI thread
                        val address = runCatching { InetSocketAddress(InetAddress.getByName(host), Wire.PORT) }.getOrNull()
                        runOnUiThread {
                            if (address != null) pairWith(host, address)
                            else panel.showChoose(link?.status()?.macs ?: emptyList(), "Couldn't find “$host”.")
                        }
                    }
                }
                restartLink()
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun hideSystemBars() {
        window.insetsController?.let {
            it.hide(WindowInsets.Type.systemBars())
            it.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }

    private companion object {
        const val PREF_HOST = "mac_host"
    }
}
