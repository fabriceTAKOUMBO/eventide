package be.cinaf.eventide

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.temporal.ChronoUnit

/** One active schedule as synced by Dart (same keys as the API contract, § 2). */
data class StoredSchedule(
    val id: String,
    val hour: Int,
    val minute: Int,
    val days: Set<Int>,
    val rampMinutes: Int,
    val landscapeName: String,
    val reminder: String,
    val active: Boolean,
)

/**
 * Native side of scheduled starts. Dart owns the schedules and calls syncSchedules() after every
 * change; this object keeps a copy in SharedPreferences so that alarms can be re-armed without
 * the Flutter engine (boot, time change, alarm fire). Only one alarm is ever armed: the next one.
 */
object ScheduleStore {
    private const val PREFS = "eventide_native"
    private const val KEY_PAYLOAD = "schedules_payload"
    private const val KEY_ARMED_ID = "armed_schedule_id"
    private const val KEY_ARMED_AT = "armed_at_millis"
    private const val KEY_PENDING_ID = "pending_schedule_id"
    private const val KEY_PENDING_AT = "pending_at_millis"

    const val ACTION_FIRE = "be.cinaf.eventide.action.SCHEDULE_FIRE"
    private const val REQUEST_ALARM = 4201
    private const val REQUEST_SHOW = 4202

    /** A pending start older than this is ignored (the evening has passed). */
    private const val PENDING_TTL_MILLIS = 15L * 60L * 1000L

    /** An alarm delivered this late (phone off, Doze) is skipped instead of starting sound. */
    private const val LATE_FIRE_LIMIT_MILLIS = 60L * 60L * 1000L

    private fun prefs(context: Context): SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    // ---- Payload from Dart

    fun savePayload(context: Context, json: String) {
        prefs(context).edit().putString(KEY_PAYLOAD, json).apply()
    }

    private fun payload(context: Context): JSONObject {
        val raw = prefs(context).getString(KEY_PAYLOAD, null) ?: return JSONObject()
        return try {
            JSONObject(raw)
        } catch (e: Exception) {
            JSONObject()
        }
    }

    /** True for free users: the free tier needs a connection (dossier § 3, screen 9). */
    fun requiresNetwork(context: Context): Boolean = payload(context).optBoolean("requires_network", true)

    fun schedules(context: Context): List<StoredSchedule> {
        val array: JSONArray = payload(context).optJSONArray("schedules") ?: return emptyList()
        val result = ArrayList<StoredSchedule>()
        for (i in 0 until array.length()) {
            val o = array.optJSONObject(i) ?: continue
            val parsed = parse(o) ?: continue
            result.add(parsed)
        }
        return result
    }

    private fun parse(o: JSONObject): StoredSchedule? {
        val id = o.optString("id", "")
        val time = o.optString("heure", "")
        val parts = time.split(":")
        if (id.isEmpty() || parts.size != 2) return null
        val hour = parts[0].toIntOrNull() ?: return null
        val minute = parts[1].toIntOrNull() ?: return null
        if (hour !in 0..23 || minute !in 0..59) return null
        val daysArray = o.optJSONArray("jours") ?: return null
        val days = HashSet<Int>()
        for (i in 0 until daysArray.length()) {
            val d = daysArray.optInt(i, 0)
            if (d in 1..7) days.add(d)
        }
        if (days.isEmpty()) return null
        return StoredSchedule(
            id = id,
            hour = hour,
            minute = minute,
            days = days,
            rampMinutes = o.optInt("montee_minutes", 10),
            landscapeName = o.optString("paysage_nom", ""),
            reminder = o.optString("rappel", "dormir"),
            active = o.optBoolean("actif", true),
        )
    }

    // ---- Next occurrence (same semantics as Dart Schedule.nextOccurrence)

    /**
     * First local wall-clock time strictly after [now] at hour:minute on one of the [StoredSchedule.days]
     * (1 = Monday … 7 = Sunday). "22:00" stays 22:00 across DST changes; a time that does not
     * exist on a spring-forward day is shifted forward by the gap, like Dart's DateTime.
     */
    fun nextOccurrence(schedule: StoredSchedule, now: ZonedDateTime): ZonedDateTime? {
        val zone = now.zone
        val today = now.toLocalDate()
        val time = LocalTime.of(schedule.hour, schedule.minute)
        for (offset in 0L..7L) {
            val date = today.plusDays(offset)
            if (!schedule.days.contains(date.dayOfWeek.value)) continue
            val candidate = ZonedDateTime.of(date, time, zone)
            if (candidate.isAfter(now)) return candidate
        }
        return null
    }

    fun next(list: List<StoredSchedule>, now: ZonedDateTime): Pair<StoredSchedule, ZonedDateTime>? {
        var best: Pair<StoredSchedule, ZonedDateTime>? = null
        for (s in list) {
            if (!s.active) continue
            val at = nextOccurrence(s, now) ?: continue
            if (best == null || at.isBefore(best.second)) best = Pair(s, at)
        }
        return best
    }

    // ---- Alarm

    fun canScheduleExactAlarms(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        val am = context.getSystemService(AlarmManager::class.java) ?: return false
        return am.canScheduleExactAlarms()
    }

    private fun firePendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, ScheduleAlarmReceiver::class.java).setAction(ACTION_FIRE)
        return PendingIntent.getBroadcast(
            context,
            REQUEST_ALARM,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun showPendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(
            context,
            REQUEST_SHOW,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /**
     * Cancels the current alarm and arms the next occurrence after [after] (default: now).
     * Returns a map for Dart: mode = "exact" | "inexact" | "none", next_at = epoch millis.
     */
    fun arm(context: Context, after: ZonedDateTime? = null): Map<String, Any?> {
        val app = context.applicationContext
        val am = app.getSystemService(AlarmManager::class.java)
            ?: return mapOf("mode" to "none", "next_at" to null)
        val pi = firePendingIntent(app)
        am.cancel(pi)
        val reference = after ?: ZonedDateTime.now(ZoneId.systemDefault())
        val next = next(schedules(app), reference)
        if (next == null) {
            prefs(app).edit().remove(KEY_ARMED_ID).remove(KEY_ARMED_AT).apply()
            return mapOf("mode" to "none", "next_at" to null)
        }
        val triggerAt = next.second.toInstant().toEpochMilli()
        prefs(app).edit()
            .putString(KEY_ARMED_ID, next.first.id)
            .putLong(KEY_ARMED_AT, triggerAt)
            .apply()
        var mode = "inexact"
        if (canScheduleExactAlarms(app)) {
            try {
                am.setAlarmClock(AlarmManager.AlarmClockInfo(triggerAt, showPendingIntent(app)), pi)
                mode = "exact"
            } catch (e: SecurityException) {
                mode = "inexact"
            }
        }
        if (mode == "inexact") {
            // No exact-alarm permission: Android may deliver it several minutes late, and the
            // foreground service start will probably be refused (fallback notification).
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pi)
        }
        return mapOf("mode" to mode, "next_at" to triggerAt)
    }

    /** Re-arms after a fire: the occurrence that just fired is excluded. */
    fun rearmAfterFire(context: Context, firedAtMillis: Long) {
        val zone = ZoneId.systemDefault()
        val now = ZonedDateTime.now(zone)
        val fired = ZonedDateTime.ofInstant(Instant.ofEpochMilli(firedAtMillis), zone)
            .truncatedTo(ChronoUnit.MINUTES)
        arm(context, if (fired.isAfter(now)) fired else now)
    }

    fun armedScheduleId(context: Context): String? = prefs(context).getString(KEY_ARMED_ID, null)

    fun armedAtMillis(context: Context): Long = prefs(context).getLong(KEY_ARMED_AT, 0L)

    fun isTooLate(armedAtMillis: Long, nowMillis: Long): Boolean =
        armedAtMillis > 0L && nowMillis - armedAtMillis > LATE_FIRE_LIMIT_MILLIS

    // ---- Pending start (read by Dart in AudioHandler.play / on resume)

    fun setPendingStart(context: Context, scheduleId: String, atMillis: Long) {
        prefs(context).edit()
            .putString(KEY_PENDING_ID, scheduleId)
            .putLong(KEY_PENDING_AT, atMillis)
            .commit()
    }

    fun clearPendingStart(context: Context) {
        prefs(context).edit().remove(KEY_PENDING_ID).remove(KEY_PENDING_AT).commit()
    }

    /** Returns the pending schedule id (if fresh) and clears it. */
    fun consumePendingStart(context: Context, nowMillis: Long): String? {
        val p = prefs(context)
        val id = p.getString(KEY_PENDING_ID, null)
        val at = p.getLong(KEY_PENDING_AT, 0L)
        clearPendingStart(context)
        if (id == null) return null
        if (nowMillis - at > PENDING_TTL_MILLIS || at - nowMillis > PENDING_TTL_MILLIS) return null
        return id
    }

    fun find(context: Context, id: String): StoredSchedule? = schedules(context).firstOrNull { it.id == id }
}
