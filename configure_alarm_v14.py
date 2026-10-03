from pathlib import Path
import re

gradle = Path('android/app/build.gradle.kts')
if not gradle.exists():
    gradle = Path('android/app/build.gradle')
text = gradle.read_text()
match = re.search(r'namespace\s*[= ]\s*["\']([^"\']+)', text)
if not match:
    raise SystemExit('Cannot detect Android namespace from Gradle')
package = match.group(1)
package_path = Path('android/app/src/main/kotlin') / Path(*package.split('.'))
package_path.mkdir(parents=True, exist_ok=True)

kotlin = r'''package __PACKAGE__

import android.app.Activity
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.Ringtone
import android.media.RingtoneManager
import android.os.Build
import android.os.IBinder
import android.os.Handler
import android.os.Looper
import android.os.Bundle
import android.graphics.Color
import android.view.Gravity
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import java.util.Calendar
import java.util.TimeZone

private const val ALARM_PREFS = "rabay_daily_alarm"
private const val ALARM_ID = 48201
private const val CHANNEL_ID = "rabay_continuous_alarm"
private const val ACTION_FIRE = "__PACKAGE__.FIRE_DAILY_ALARM"
private const val ACTION_STOP = "__PACKAGE__.STOP_DAILY_ALARM"

object RabayAlarmScheduler {
    fun schedule(context: Context, hour: Int, minute: Int, message: String, soundEnabled: Boolean) {
        context.getSharedPreferences(ALARM_PREFS, Context.MODE_PRIVATE).edit()
            .putBoolean("enabled", true).putInt("hour", hour).putInt("minute", minute)
            .putString("message", message).putBoolean("sound", soundEnabled).apply()
        scheduleNext(context)
    }

    fun scheduleNext(context: Context) {
        val prefs = context.getSharedPreferences(ALARM_PREFS, Context.MODE_PRIVATE)
        if (!prefs.getBoolean("enabled", false)) return
        val calendar = Calendar.getInstance(TimeZone.getTimeZone("Asia/Jakarta")).apply {
            set(Calendar.HOUR_OF_DAY, prefs.getInt("hour", 22))
            set(Calendar.MINUTE, prefs.getInt("minute", 0))
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
            if (timeInMillis <= System.currentTimeMillis()) add(Calendar.DAY_OF_YEAR, 1)
        }
        val intent = Intent(context, RabayAlarmReceiver::class.java).setAction(ACTION_FIRE)
        val pending = PendingIntent.getBroadcast(context, ALARM_ID, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val manager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        // Replace the previous daily alarm when the owner edits and saves the reminder.
        manager.cancel(pending)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && !manager.canScheduleExactAlarms()) {
            throw SecurityException("Izin Alarm dan pengingat belum aktif")
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                manager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, calendar.timeInMillis, pending)
            } else {
                manager.setExact(AlarmManager.RTC_WAKEUP, calendar.timeInMillis, pending)
            }
        } catch (security: SecurityException) {
            throw security
        }
    }

    fun stop(context: Context) {
        // Stop only the current ringing. Keep the next daily alarm scheduled.
        context.stopService(Intent(context, RabayAlarmSoundService::class.java))
    }
}

class RabayAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action == ACTION_STOP) {
            RabayAlarmScheduler.stop(context)
            return
        }
        val prefs = context.getSharedPreferences(ALARM_PREFS, Context.MODE_PRIVATE)
        if (!prefs.getBoolean("enabled", false)) return
        RabayAlarmScheduler.scheduleNext(context)
        val serviceIntent = Intent(context, RabayAlarmSoundService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(serviceIntent)
        else context.startService(serviceIntent)
    }
}

class RabayAlarmBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action == Intent.ACTION_BOOT_COMPLETED || intent?.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            RabayAlarmScheduler.scheduleNext(context)
        }
    }
}

class RabayAlarmSoundService : Service() {
    private var ringtone: Ringtone? = null
    private val stopHandler = Handler(Looper.getMainLooper())
    private val autoStopRunnable = Runnable { stopSelf() }
    override fun onCreate() { super.onCreate(); createChannel() }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val prefs = getSharedPreferences(ALARM_PREFS, Context.MODE_PRIVATE)
        val message = prefs.getString("message", "Waktunya memproses tutup toko") ?: "Waktunya memproses tutup toko"
        val soundEnabled = prefs.getBoolean("sound", true)
        val stopIntent = Intent(this, RabayAlarmReceiver::class.java).setAction(ACTION_STOP)
        val stopPending = PendingIntent.getBroadcast(this, ALARM_ID + 1, stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val popupIntent = Intent(this, RabayAlarmActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        val popupPending = PendingIntent.getActivity(this, ALARM_ID + 2, popupIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(this, CHANNEL_ID)
                      else Notification.Builder(this)
        val notification = builder.setSmallIcon(applicationInfo.icon)
            .setContentTitle("RABAY CELL").setContentText(message)
            .setCategory(Notification.CATEGORY_ALARM).setVisibility(Notification.VISIBILITY_PUBLIC)
            .setFullScreenIntent(popupPending, true)
            .setContentIntent(popupPending)
            .setOngoing(true).setAutoCancel(false)
            .addAction(android.R.drawable.ic_media_pause, "BERHENTI", stopPending).build()
        startForeground(48202, notification)
        // Automatically stop this ringing session after a maximum of 3 minutes.
        // The next daily alarm remains scheduled independently by RabayAlarmReceiver.
        stopHandler.removeCallbacks(autoStopRunnable)
        stopHandler.postDelayed(autoStopRunnable, 3 * 60 * 1000L)
        if (soundEnabled && ringtone == null) {
            val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
            ringtone = RingtoneManager.getRingtone(applicationContext, uri)
            ringtone?.audioAttributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) ringtone?.isLooping = true
            ringtone?.play()
        }
        return START_STICKY
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, "Alarm Rabay Cell", NotificationManager.IMPORTANCE_HIGH)
            channel.description = "Alarm harian yang berbunyi sampai dihentikan"
            channel.setSound(null, null)
            channel.enableVibration(true)
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(channel)
        }
    }
    override fun onDestroy() {
        stopHandler.removeCallbacks(autoStopRunnable)
        ringtone?.stop()
        ringtone = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) stopForeground(STOP_FOREGROUND_REMOVE) else stopForeground(true)
        super.onDestroy()
    }
    override fun onBind(intent: Intent?): IBinder? = null
}

class RabayAlarmActivity : Activity() {
    private val popupTimeoutHandler = Handler(Looper.getMainLooper())
    private val popupTimeoutRunnable = Runnable { finish() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
        popupTimeoutHandler.removeCallbacks(popupTimeoutRunnable)
        popupTimeoutHandler.postDelayed(popupTimeoutRunnable, 3 * 60 * 1000L)
        val prefs = getSharedPreferences(ALARM_PREFS, Context.MODE_PRIVATE)
        val message = prefs.getString("message", "Waktunya memproses tutup toko") ?: "Waktunya memproses tutup toko"
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(48, 64, 48, 64)
            setBackgroundColor(Color.rgb(0, 143, 131))
        }
        val body = TextView(this).apply {
            text = message
            textSize = 21f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            setPadding(0, 32, 0, 48)
        }
        val stop = Button(this).apply {
            text = "BERHENTI"
            textSize = 20f
            setOnClickListener {
                stopService(Intent(this@RabayAlarmActivity, RabayAlarmSoundService::class.java))
                finish()
            }
        }
        layout.addView(body)
        layout.addView(stop)
        setContentView(layout)
    }

    override fun onDestroy() {
        popupTimeoutHandler.removeCallbacks(popupTimeoutRunnable)
        super.onDestroy()
    }
}
'''.replace('__PACKAGE__', package)
(package_path / 'RabayAlarmNative.kt').write_text(kotlin)

# Connect the Flutter method channel to Android's AlarmManager implementation.
activity = package_path / 'MainActivity.kt'
if not activity.exists():
    raise SystemExit(f'MainActivity.kt not found at {activity}')
activity_text = activity.read_text()
if 'rabay_cell/alarm' not in activity_text:
    activity_text = activity_text.replace(
        'import io.flutter.embedding.android.FlutterActivity',
        'import io.flutter.embedding.android.FlutterActivity\nimport io.flutter.embedding.engine.FlutterEngine\nimport io.flutter.plugin.common.MethodChannel'
    )
    activity_text = activity_text.replace(
        'class MainActivity : FlutterActivity()'
        , '''class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "rabay_cell/alarm")
            .setMethodCallHandler { call, result ->
                if (call.method == "canScheduleExactAlarms") {
                    val manager = getSystemService(android.content.Context.ALARM_SERVICE) as android.app.AlarmManager
                    result.success(android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.S || manager.canScheduleExactAlarms())
                } else if (call.method == "scheduleDailyAlarm") {
                    val hour = call.argument<Int>("hour")
                    val minute = call.argument<Int>("minute")
                    val message = call.argument<String>("message")
                    val soundEnabled = call.argument<Boolean>("soundEnabled") ?: true
                    if (hour == null || minute == null || message.isNullOrBlank()) {
                        result.error("INVALID_ARGUMENT", "Jam atau pesan alarm tidak valid", null)
                    } else {
                        try {
                            RabayAlarmScheduler.schedule(this, hour, minute, message, soundEnabled)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("ALARM_SCHEDULE_FAILED", e.message, null)
                        }
                    }
                } else {
                    result.notImplemented()
                }
            }
    }
}'''
    )
    activity.write_text(activity_text)

manifest = Path('android/app/src/main/AndroidManifest.xml')
m = manifest.read_text()
permissions = [
    'android.permission.POST_NOTIFICATIONS', 'android.permission.VIBRATE',
    'android.permission.RECEIVE_BOOT_COMPLETED', 'android.permission.SCHEDULE_EXACT_ALARM',
    'android.permission.FOREGROUND_SERVICE', 'android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK',
    'android.permission.USE_FULL_SCREEN_INTENT'
]
for permission in permissions:
    if permission not in m:
        m = m.replace('<application', f'    <uses-permission android:name="{permission}"/>\n    <application', 1)
components = f'''
        <receiver android:name="{package}.RabayAlarmReceiver" android:exported="false" />
        <receiver android:name="{package}.RabayAlarmBootReceiver" android:enabled="true" android:exported="false">
            <intent-filter>
                <action android:name="android.intent.action.BOOT_COMPLETED" />
                <action android:name="android.intent.action.MY_PACKAGE_REPLACED" />
            </intent-filter>
        </receiver>
        <service android:name="{package}.RabayAlarmSoundService" android:exported="false" android:foregroundServiceType="mediaPlayback" />
        <activity android:name="{package}.RabayAlarmActivity" android:exported="false" android:excludeFromRecents="true" android:launchMode="singleTop" android:showWhenLocked="true" android:turnScreenOn="true" android:theme="@android:style/Theme.Material.Light.NoActionBar" />
'''
if 'RabayAlarmSoundService' not in m:
    m = m.replace('</application>', components + '\n    </application>', 1)
manifest.write_text(m)
print('Configured native repeating alarm for package', package)
