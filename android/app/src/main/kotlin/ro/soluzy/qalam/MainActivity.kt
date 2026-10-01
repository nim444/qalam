package ro.soluzy.qalam

import android.app.Activity
import android.app.AlertDialog
import android.graphics.Typeface
import android.net.wifi.WifiManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.view.Gravity
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView

/**
 * M0 feel test: a full-screen pen pad on the left, a status strip on the right. The pen drives
 * the Mac cursor through [Link]; the strip shows which link is live and how fast it answers.
 */
class MainActivity : Activity() {

    private lateinit var pad: PadView
    private lateinit var linkLine: TextView
    private lateinit var details: TextView
    private lateinit var penLine: TextView
    private var link: Link? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private val prefs by lazy { getSharedPreferences("qalam", MODE_PRIVATE) }

    private val ui = Handler(Looper.getMainLooper())
    private var lastTick = 0L
    private val tick = object : Runnable {
        override fun run() {
            refresh()
            ui.postDelayed(this, 500)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val dp = resources.displayMetrics.density

        pad = PadView(this).apply { onFrame = { frame -> link?.sendPen(frame) } }

        fun text(size: Float, color: Long, bold: Boolean = false) = TextView(this).apply {
            textSize = size
            setTextColor(color.toInt())
            if (bold) typeface = Typeface.DEFAULT_BOLD
            setPadding(0, (6 * dp).toInt(), 0, 0)
        }
        linkLine = text(17f, 0xFFECECEC, bold = true)
        details = text(12f, 0xFF9A9AA2)
        penLine = text(12f, 0xFF9A9AA2)

        val side = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(0xFF111114.toInt())
            setPadding((14 * dp).toInt(), (18 * dp).toInt(), (14 * dp).toInt(), (14 * dp).toInt())
            addView(text(20f, 0xFFECECEC, bold = true).apply { text = "Qalam" })
            addView(text(12f, 0xFF4FD1C5).apply { text = "M0 feel test · cursor" })
            addView(linkLine)
            addView(details)
            addView(penLine)
            addView(LinearLayout(context), LinearLayout.LayoutParams(0, 0, 1f)) // spacer
            addView(Button(context).apply {
                text = "Mac IP…"
                setOnClickListener { askForHost() }
            })
        }

        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(pad, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f))
            addView(side, LinearLayout.LayoutParams((190 * dp).toInt(), ViewGroup.LayoutParams.MATCH_PARENT))
        })
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
        link = Link(this, prefs.getString(PREF_HOST, null)).also { it.start() }
    }

    private fun refresh() {
        val s = link?.status() ?: return
        if (s.displayW > 0 && s.displayH > 0) pad.aspect = s.displayW.toFloat() / s.displayH

        val now = System.nanoTime()
        val seconds = if (lastTick == 0L) 0.5 else (now - lastTick) / 1e9
        lastTick = now
        val rate = pad.takeSampleCount() / seconds

        val rtt = when (s.active) {
            Link.Kind.WIFI -> s.wifiRttMs
            Link.Kind.USB -> s.usbRttMs
            null -> null
        }
        linkLine.text = when {
            s.active != null && rtt != null -> "● ${s.active.label}  %.1f ms".format(rtt)
            s.wifiTarget != null -> "● trying Wi-Fi…"
            else -> "● looking for the Mac…"
        }
        linkLine.setTextColor(
            when {
                rtt == null -> 0xFFE0A030
                s.active == Link.Kind.WIFI -> 0xFF4FD1C5
                else -> 0xFF7AA2F7
            }.toInt()
        )
        details.text = buildString {
            append("Mac: ${s.macName ?: "—"}\n")
            append("Wi-Fi: ${s.wifiRttMs?.let { "%.1f ms".format(it) } ?: "no answer"}")
            s.wifiTarget?.let { append("  ($it)") }
            append("\nUSB: ${s.usbRttMs?.let { "%.1f ms".format(it) } ?: "not connected"}")
            if (s.displayW > 0) append("\nDisplay: ${s.displayW}×${s.displayH} pt")
        }
        penLine.text = "Pen: ${pad.penState}\n%.0f samples/s · pressure %.2f".format(rate, pad.lastPressure)
    }

    private fun askForHost() {
        val input = EditText(this).apply {
            hint = "blank = find it automatically"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
            setText(prefs.getString(PREF_HOST, ""))
            gravity = Gravity.CENTER
        }
        AlertDialog.Builder(this)
            .setTitle("Mac IP address")
            .setMessage("qalam-m0 prints it when it starts.")
            .setView(input)
            .setPositiveButton("Save") { _, _ ->
                prefs.edit().putString(PREF_HOST, input.text.toString().trim()).apply()
                link?.close()
                startLink()
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
