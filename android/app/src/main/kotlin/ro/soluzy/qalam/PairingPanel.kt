package ro.soluzy.qalam

import android.content.Context
import android.graphics.Typeface
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView

/**
 * Shown over the pad until the phone is paired: the Macs found on the network (and the USB
 * cable), then the 6-digit code to compare with the Mac's.
 */
class PairingPanel(context: Context) : LinearLayout(context) {
    var onPick: ((Link.FoundMac) -> Unit)? = null
    var onAddress: (() -> Unit)? = null
    var onCancel: (() -> Unit)? = null

    private val dp = resources.displayMetrics.density
    private fun px(v: Int) = (v * dp).toInt()

    private val title = TextView(context).apply {
        textSize = 20f
        typeface = Typeface.DEFAULT_BOLD
        setTextColor(Palette.TEXT)
        gravity = Gravity.CENTER
    }
    private val code = TextView(context).apply {
        textSize = 44f
        typeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
        setTextColor(Palette.ACCENT)
        gravity = Gravity.CENTER
        letterSpacing = 0.08f
    }
    private val text = TextView(context).apply {
        textSize = 14f
        setTextColor(Palette.MUTED)
        gravity = Gravity.CENTER
        setLineSpacing(0f, 1.25f)
    }
    private val list = LinearLayout(context).apply { orientation = VERTICAL }
    private val address = Chip(context, "Enter the Mac's address…").apply { onTap { onAddress?.invoke() } }
    private val cancel = Chip(context, "Cancel").apply { onTap { onCancel?.invoke() } }
    private var shownMacs: List<String>? = null

    init {
        orientation = VERTICAL
        gravity = Gravity.CENTER_HORIZONTAL
        setPadding(px(20), px(16), px(20), px(16))
        addView(title)
        addView(code, LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = px(10) })
        addView(text, LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = px(10) })
        addView(list, LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = px(6) })
        addView(address, button())
        addView(cancel, button())
    }

    private fun button() = LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, px(42)).apply { topMargin = px(10) }

    /** Pick a Mac. [error] explains why the last attempt didn't work. */
    fun showChoose(macs: List<Link.FoundMac>, error: String? = null) {
        title.text = "Pair with your Mac"
        code.visibility = View.GONE
        text.text = error ?: "1. On the Mac, open Qalam's menu → Pair a phone…\n2. Tap your Mac below."
        text.setTextColor(if (error != null) 0xFFE0A030.toInt() else Palette.MUTED)
        list.visibility = View.VISIBLE
        address.visibility = View.VISIBLE
        cancel.visibility = View.GONE
        shownMacs = null
        updateMacs(macs)
    }

    /** Refreshes the list of Macs (only while choosing; rebuilt only when it changes). */
    fun updateMacs(macs: List<Link.FoundMac>) {
        if (list.visibility != View.VISIBLE) return
        val names = macs.map { it.name }
        if (names == shownMacs) return
        shownMacs = names
        list.removeAllViews()
        if (macs.isEmpty()) {
            list.addView(TextView(context).apply {
                text = "Looking for Macs running Qalam…"
                textSize = 13f
                setTextColor(Palette.MUTED)
                gravity = Gravity.CENTER
                setPadding(0, px(10), 0, 0)
            })
        }
        for (mac in macs) {
            list.addView(Chip(context, mac.name).apply { onTap { onPick?.invoke(mac) } }, button())
        }
    }

    fun showContacting(macName: String) {
        title.text = "Pairing…"
        code.visibility = View.GONE
        text.text = "Asking “$macName”. Keep its Pair a phone… window open."
        text.setTextColor(Palette.MUTED)
        list.visibility = View.GONE
        address.visibility = View.GONE
        cancel.visibility = View.VISIBLE
    }

    fun showCode(value: String, macName: String) {
        title.text = "Compare the code"
        code.text = "${value.take(3)} ${value.takeLast(3)}"
        code.visibility = View.VISIBLE
        text.text = "If “$macName” shows the same code, click Pair on the Mac."
        text.setTextColor(Palette.MUTED)
        list.visibility = View.GONE
        address.visibility = View.GONE
        cancel.visibility = View.VISIBLE
    }
}
