package be.cinaf.eventide

import android.annotation.TargetApi
import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import java.io.InputStream

/**
 * Problem report (docs/app/architecture.md « Rapport de problème »): why Android ended the app's
 * processes (crash, native crash, ANR, low memory, excessive resource use, killed by the system
 * or the user…), read from ActivityManager.getHistoricalProcessExitReasons (Android 11+), each
 * exit given to Dart once (the newest timestamp seen is kept). Nothing leaves the phone unless
 * the user shares the report. Called off the main thread (trace streams can be large).
 */
object ExitReports {
    private const val TAG = "EventideDiagnostics"
    private const val PREFS = "eventide_diagnostics"
    private const val KEY_LAST_SEEN = "exit_last_seen_ms"
    private const val MAX_RECORDS = 16

    /** ANR traces start with the main thread: the head is what matters. */
    private const val MAX_TRACE_BYTES = 24 * 1024

    /** Native crash tombstones are protobuf (Android 12+): only their printable strings are kept. */
    private const val MAX_TOMBSTONE_BYTES = 256 * 1024
    private const val MAX_TRACE_CHARS = 24 * 1024

    fun takeNew(context: Context): List<Map<String, Any?>> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return emptyList()
        return takeNewApi30(context)
    }

    @TargetApi(Build.VERSION_CODES.R)
    private fun takeNewApi30(context: Context): List<Map<String, Any?>> {
        val manager = context.getSystemService(ActivityManager::class.java) ?: return emptyList()
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val lastSeen = prefs.getLong(KEY_LAST_SEEN, 0L)
        val infos = try {
            manager.getHistoricalProcessExitReasons(context.packageName, 0, MAX_RECORDS)
        } catch (e: Exception) {
            Log.w(TAG, "exit reasons unavailable: $e")
            return emptyList()
        }
        val fresh = infos.filter { it.timestamp > lastSeen }
        if (fresh.isEmpty()) return emptyList()
        prefs.edit().putLong(KEY_LAST_SEEN, fresh.maxOf { it.timestamp }).commit()
        return fresh.map { toMap(it) }
    }

    @TargetApi(Build.VERSION_CODES.R)
    private fun toMap(info: ApplicationExitInfo): Map<String, Any?> {
        val trace = readTrace(info)
        return mapOf(
            "reason" to info.reason,
            "status" to info.status,
            "timestamp" to info.timestamp,
            "importance" to info.importance,
            "pss_kb" to info.pss,
            "rss_kb" to info.rss,
            "description" to info.description,
            "process" to info.processName,
            "trace" to trace?.first,
            "trace_truncated" to (trace?.second ?: false),
        )
    }

    /** ANR traces as text; native crash tombstones reduced to their printable strings. */
    @TargetApi(Build.VERSION_CODES.R)
    private fun readTrace(info: ApplicationExitInfo): Pair<String, Boolean>? {
        val anr = info.reason == ApplicationExitInfo.REASON_ANR
        val nativeCrash = info.reason == ApplicationExitInfo.REASON_CRASH_NATIVE
        if (!anr && !nativeCrash) return null
        return try {
            val stream = info.traceInputStream ?: return null
            stream.use { input ->
                val limit = if (anr) MAX_TRACE_BYTES else MAX_TOMBSTONE_BYTES
                val bytes = readAtMost(input, limit + 1)
                val truncated = bytes.size > limit
                val kept = if (truncated) bytes.copyOf(limit) else bytes
                if (anr) {
                    Pair(String(kept, Charsets.UTF_8), truncated)
                } else {
                    val text = printableStrings(kept)
                    Pair(text, truncated || text.length >= MAX_TRACE_CHARS)
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "trace unreadable: $e")
            null
        }
    }

    private fun readAtMost(input: InputStream, max: Int): ByteArray {
        val buffer = ByteArray(max)
        var total = 0
        while (total < max) {
            val n = input.read(buffer, total, max - total)
            if (n < 0) break
            total += n
        }
        return buffer.copyOf(total)
    }

    /** Runs of at least 4 printable ASCII characters (like `strings`), one per line. */
    private fun printableStrings(bytes: ByteArray): String {
        val out = StringBuilder()
        val run = StringBuilder()
        fun flush() {
            if (run.length >= 4 && out.length < MAX_TRACE_CHARS) out.append(run).append('\n')
            run.setLength(0)
        }
        for (b in bytes) {
            val c = b.toInt() and 0xFF
            if (c in 0x20..0x7E) run.append(c.toChar()) else flush()
            if (out.length >= MAX_TRACE_CHARS) break
        }
        flush()
        return if (out.length > MAX_TRACE_CHARS) out.substring(0, MAX_TRACE_CHARS) else out.toString()
    }

    /** App and phone, without any identifier (no serial, no Android id). */
    fun deviceDetails(context: Context): Map<String, Any?> {
        val info = packageInfo(context)
        val versionCode: Long = when {
            info == null -> 0L
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.P -> info.longVersionCode
            else -> legacyVersionCode(info)
        }
        val manager = context.getSystemService(ActivityManager::class.java)
        val memory = ActivityManager.MemoryInfo()
        try {
            manager?.getMemoryInfo(memory)
        } catch (e: Exception) {
            // Unknown memory: 0 in the report.
        }
        return mapOf(
            "app_version" to (info?.versionName ?: ""),
            "build_number" to versionCode.toString(),
            "package" to context.packageName,
            "android_release" to Build.VERSION.RELEASE,
            "sdk_int" to Build.VERSION.SDK_INT,
            "manufacturer" to Build.MANUFACTURER,
            "model" to Build.MODEL,
            "total_memory_mb" to (memory.totalMem / (1024L * 1024L)).toInt(),
            "low_ram" to (manager?.isLowRamDevice ?: false),
        )
    }

    @Suppress("DEPRECATION")
    private fun legacyVersionCode(info: PackageInfo): Long = info.versionCode.toLong()

    private fun packageInfo(context: Context): PackageInfo? =
        try {
            val pm = context.packageManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                pm.getPackageInfo(context.packageName, PackageManager.PackageInfoFlags.of(0L))
            } else {
                @Suppress("DEPRECATION")
                pm.getPackageInfo(context.packageName, 0)
            }
        } catch (e: Exception) {
            null
        }
}
