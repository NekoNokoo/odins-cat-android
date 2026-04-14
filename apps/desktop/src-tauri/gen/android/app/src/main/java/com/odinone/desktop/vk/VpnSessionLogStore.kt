package com.odinone.desktop.vk

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.File
import java.io.IOException
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

object VpnSessionLogStore {
    private const val PREFS_NAME = "odin_one_vpn_session_log"
    private const val PREF_KEY_RECORD_NEXT_SESSION = "record_next_session"
    private const val DOWNLOAD_FOLDER = "Odin's log"
    private val fileNameFormatter: DateTimeFormatter =
        DateTimeFormatter.ofPattern("yyyy-MM-dd_HH-mm-ss", Locale.US)

    data class SavedLogFile(
        val exportPath: String,
    )

    fun isArmed(context: Context): Boolean =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getBoolean(PREF_KEY_RECORD_NEXT_SESSION, false)

    fun setArmed(
        context: Context,
        enabled: Boolean,
    ) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(PREF_KEY_RECORD_NEXT_SESSION, enabled)
            .apply()
    }

    fun saveSessionLog(
        context: Context,
        contents: String,
        timestampMs: Long = System.currentTimeMillis(),
    ): SavedLogFile {
        val fileName =
            "runtime-session-${
                fileNameFormatter.format(
                    Instant.ofEpochMilli(timestampMs).atZone(ZoneId.systemDefault()),
                )
            }.log.txt"
        val relativePath = "${Environment.DIRECTORY_DOWNLOADS}/$DOWNLOAD_FOLDER"
        val bytes = contents.toByteArray(Charsets.UTF_8)
        val mimeType = "text/plain"

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = context.contentResolver
            val values =
                ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, fileName)
                    put(MediaStore.Downloads.MIME_TYPE, mimeType)
                    put(MediaStore.Downloads.RELATIVE_PATH, relativePath)
                    put(MediaStore.Downloads.IS_PENDING, 1)
                }
            val uri =
                resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                    ?: throw IOException("Failed to create session log file in public Downloads.")
            try {
                resolver.openOutputStream(uri, "wt")?.use { output ->
                    output.write(bytes)
                    output.flush()
                } ?: throw IOException("Failed to open session log output stream.")
                values.clear()
                values.put(MediaStore.Downloads.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            } catch (error: Exception) {
                resolver.delete(uri, null, null)
                throw error
            }
            return SavedLogFile(
                exportPath = "${Environment.DIRECTORY_DOWNLOADS}/$DOWNLOAD_FOLDER/$fileName",
            )
        }

        val downloadsDir =
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        val exportDir = File(downloadsDir, DOWNLOAD_FOLDER).apply { mkdirs() }
        val outputFile = File(exportDir, fileName)
        outputFile.writeText(contents, Charsets.UTF_8)
        return SavedLogFile(exportPath = outputFile.absolutePath)
    }
}
