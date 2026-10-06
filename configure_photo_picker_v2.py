#!/usr/bin/env python3
"""
Rabay Cell - Photo Picker fix v5.

Fixes the MethodChannel mismatch between Flutter/Dart and Android.

Dart uses:
    rabay_cell/photo_picker

Alarm continues to use:
    rabay_cell/alarm

This script:
- keeps the existing alarm scheduler
- keeps startActivityForResult photo picker
- creates a separate photo picker MethodChannel
- does not modify main.dart
"""

from pathlib import Path
import re

files = list(Path("android/app/src/main/kotlin").rglob("MainActivity.kt"))

if not files:
    raise SystemExit("MainActivity.kt tidak ditemukan.")

path = files[0]
text = path.read_text(encoding="utf-8")

print("Processing:", path)

# ---------------------------------------------------------
# 1. Required imports
# ---------------------------------------------------------

required_imports = [
    "import android.app.Activity",
    "import android.content.ActivityNotFoundException",
    "import android.content.Intent",
    "import android.net.Uri",
]

# Remove old Activity Result import if still present.
text = re.sub(
    r"^import androidx\.activity\.result\.contract\.ActivityResultContracts\s*\n",
    "",
    text,
    flags=re.MULTILINE,
)

lines = text.splitlines()

package_index = next(
    (i for i, line in enumerate(lines) if line.startswith("package ")),
    None,
)

if package_index is None:
    raise SystemExit("Baris package tidak ditemukan.")

existing = "\n".join(lines)

missing = [
    item for item in required_imports
    if item not in existing
]

if missing:
    lines[package_index + 1:package_index + 1] = [""] + missing

text = "\n".join(lines) + "\n"


# ---------------------------------------------------------
# 2. Find MainActivity and configureFlutterEngine
# ---------------------------------------------------------

class_marker = "class MainActivity : FlutterActivity() {"
configure_marker = "    override fun configureFlutterEngine"

class_start = text.find(class_marker)

if class_start == -1:
    raise SystemExit("class MainActivity tidak ditemukan.")

configure_start = text.find(configure_marker, class_start)

if configure_start == -1:
    raise SystemExit(
        "configureFlutterEngine tidak ditemukan."
    )


# ---------------------------------------------------------
# 3. Clean photo picker section before configureFlutterEngine
# ---------------------------------------------------------

photo_picker_code = """class MainActivity : FlutterActivity() {

    companion object {
        private const val PHOTO_PICKER_REQUEST_CODE = 19001
    }

    private var photoPickerResult: MethodChannel.Result? = null

    private fun launchPhotoPicker(result: MethodChannel.Result) {
        photoPickerResult = result

        try {
            val intent = Intent(Intent.ACTION_GET_CONTENT).apply {
                type = "image/*"
                addCategory(Intent.CATEGORY_OPENABLE)
            }

            startActivityForResult(
                intent,
                PHOTO_PICKER_REQUEST_CODE
            )
        } catch (e: ActivityNotFoundException) {
            photoPickerResult = null
            result.error(
                "PHOTO_PICKER_UNAVAILABLE",
                e.message,
                null
            )
        } catch (e: Exception) {
            photoPickerResult = null
            result.error(
                "PHOTO_PICKER_FAILED",
                e.message,
                null
            )
        }
    }

    @Deprecated(
        "Deprecated in Android API, kept for FlutterActivity compatibility."
    )
    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?
    ) {
        super.onActivityResult(
            requestCode,
            resultCode,
            data
        )

        if (requestCode != PHOTO_PICKER_REQUEST_CODE) {
            return
        }

        val result = photoPickerResult
        photoPickerResult = null

        if (result == null) {
            return
        }

        if (resultCode != Activity.RESULT_OK) {
            result.success(null)
            return
        }

        val uri: Uri? = data?.data

        if (uri == null) {
            result.success(null)
            return
        }

        try {
            val bytes = contentResolver
                .openInputStream(uri)
                ?.use { it.readBytes() }

            if (bytes == null) {
                result.error(
                    "PHOTO_READ_FAILED",
                    "Foto tidak dapat dibaca.",
                    null
                )
            } else {
                result.success(bytes)
            }
        } catch (e: Exception) {
            result.error(
                "PHOTO_READ_FAILED",
                e.message,
                null
            )
        }
    }

"""

text = (
    text[:class_start]
    + photo_picker_code
    + text[configure_start:]
)


# ---------------------------------------------------------
# 4. Replace the entire configureFlutterEngine body
#    while preserving the alarm logic.
# ---------------------------------------------------------

configure_start = text.find(configure_marker)

if configure_start == -1:
    raise SystemExit(
        "configureFlutterEngine tidak ditemukan setelah "
        "photo picker preparation."
    )

# Find the opening brace.
opening = text.find("{", configure_start)

if opening == -1:
    raise SystemExit("Pembuka configureFlutterEngine tidak ditemukan.")

# Find matching closing brace using brace counting.
depth = 0
closing = None

for i in range(opening, len(text)):
    if text[i] == "{":
        depth += 1
    elif text[i] == "}":
        depth -= 1
        if depth == 0:
            closing = i
            break

if closing is None:
    raise SystemExit(
        "Penutup configureFlutterEngine tidak ditemukan."
    )


configure_code = """    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // =================================================
        // PHOTO PICKER CHANNEL
        // =================================================

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "rabay_cell/photo_picker"
        ).setMethodCallHandler { call, result ->

            if (call.method == "pickImageBytes") {
                if (photoPickerResult != null) {
                    result.error(
                        "PHOTO_PICKER_BUSY",
                        "Pemilih foto sedang terbuka.",
                        null
                    )
                } else {
                    launchPhotoPicker(result)
                }
            } else {
                result.notImplemented()
            }
        }


        // =================================================
        // ALARM CHANNEL
        // =================================================

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "rabay_cell/alarm"
        ).setMethodCallHandler { call, result ->

            if (call.method == "canScheduleExactAlarms") {

                val manager =
                    getSystemService(
                        android.content.Context.ALARM_SERVICE
                    ) as android.app.AlarmManager

                result.success(
                    android.os.Build.VERSION.SDK_INT <
                        android.os.Build.VERSION_CODES.S ||
                        manager.canScheduleExactAlarms()
                )

            } else if (call.method == "scheduleDailyAlarm") {

                val hour = call.argument<Int>("hour")
                val minute = call.argument<Int>("minute")
                val message = call.argument<String>("message")
                val soundEnabled =
                    call.argument<Boolean>("soundEnabled") ?: true

                if (
                    hour == null ||
                    minute == null ||
                    message.isNullOrBlank()
                ) {
                    result.error(
                        "INVALID_ARGUMENT",
                        "Jam atau pesan alarm tidak valid",
                        null
                    )
                } else {
                    try {
                        RabayAlarmScheduler.schedule(
                            this,
                            hour,
                            minute,
                            message,
                            soundEnabled
                        )

                        result.success(null)

                    } catch (e: Exception) {
                        result.error(
                            "ALARM_SCHEDULE_FAILED",
                            e.message,
                            null
                        )
                    }
                }

            } else if (call.method == "cancelDailyAlarm") {

                try {
                    RabayAlarmScheduler.cancel(this)
                    result.success(null)

                } catch (e: Exception) {
                    result.error(
                        "ALARM_CANCEL_FAILED",
                        e.message,
                        null
                    )
                }

            } else {
                result.notImplemented()
            }
        }
    }"""

text = (
    text[:configure_start]
    + configure_code
    + text[closing + 1:]
)

path.write_text(text, encoding="utf-8")

print()
print("==============================================")
print("Photo picker v5 berhasil diterapkan.")
print("==============================================")
print("Dart channel : rabay_cell/photo_picker")
print("Alarm channel: rabay_cell/alarm")
print()
print("pickImageBytes sekarang terhubung ke:")
print("rabay_cell/photo_picker")
print()
print("Alarm scheduler tetap menggunakan:")
print("rabay_cell/alarm")
print()
print("Alarm code tidak dihapus.")
print("==============================================")
