package com.cybersight.sharefilevialan

import android.annotation.TargetApi
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Context
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaPlayer
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.PowerManager
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.util.Locale

class MainActivity : FlutterActivity() {
    private val channelName = "lancom/platform"
    private val localNetworkPermission = "android.permission.ACCESS_LOCAL_NETWORK"
    private val localNetworkRequestCode = 4107
    private val pickFilesRequestCode = 4108
    private val installPermissionRequestCode = 4109
    private val pendingApkStateKey = "lancom.pendingApkPath"
    private var multicastLock: WifiManager.MulticastLock? = null
    private var transferWakeLock: PowerManager.WakeLock? = null
    private var pendingLocalNetworkResult: MethodChannel.Result? = null
    private var pendingPickFilesResult: MethodChannel.Result? = null
    private var pendingApkPath: String? = null
    private var pendingOpenFileResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "androidSdkInt" -> result.success(Build.VERSION.SDK_INT)
                "checkLocalNetworkPermission" -> {
                    result.success(checkLocalNetworkPermission())
                }
                "requestLocalNetworkPermission" -> {
                    requestLocalNetworkPermission(result)
                }
                "acquireMulticastLock" -> result.success(acquireMulticastLock())
                "releaseMulticastLock" -> result.success(releaseMulticastLock())
                "isMulticastLockHeld" -> {
                    result.success(multicastLock?.isHeld == true)
                }
                "isIgnoringBatteryOptimizations" -> {
                    result.success(isIgnoringBatteryOptimizations())
                }
                "openBatteryOptimizationSettings" -> {
                    result.success(openBatteryOptimizationSettings())
                }
                "acquireTransferWakeLock" -> {
                    result.success(acquireTransferWakeLock())
                }
                "releaseTransferWakeLock" -> {
                    result.success(releaseTransferWakeLock())
                }
                "openAppSettings" -> {
                    openAppSettings()
                    result.success(null)
                }
                "openExternalVideo" -> {
                    val source = call.argument<String>("source") ?: ""
                    result.success(openExternalVideo(source))
                }
                "openFile" -> {
                    openFile(call.argument<String>("path") ?: "", result)
                }
                "playSound" -> {
                    val sound = call.argument<String>("sound") ?: ""
                    result.success(playSound(sound))
                }
                "publicDownloadPath" -> {
                    val fileName = call.argument<String>("fileName") ?: "file"
                    result.success(publicDownloadPath(fileName))
                }
                "publishDownload" -> {
                    val sourcePath = call.argument<String>("sourcePath") ?: ""
                    val fileName = call.argument<String>("fileName") ?: "file"
                    result.success(publishDownload(sourcePath, fileName))
                }
                "pickFiles" -> {
                    val allowMultiple =
                        call.argument<Boolean>("allowMultiple") ?: true
                    pickFiles(result, allowMultiple)
                }
                "cachePickedFile" -> {
                    val identifier = call.argument<String>("identifier") ?: ""
                    val fileName = call.argument<String>("fileName") ?: "file"
                    result.success(cachePickedFile(identifier, fileName))
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Flutter supplies the window insets to Dart. Do not consume them or
        // add native view padding, which would double-pad Flutter's SafeAreas.
        WindowCompat.enableEdgeToEdge(window)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            isAppearanceLightStatusBars = false
            isAppearanceLightNavigationBars = false
        }
        pendingApkPath = savedInstanceState?.getString(pendingApkStateKey)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        pendingApkPath?.let { outState.putString(pendingApkStateKey, it) }
        super.onSaveInstanceState(outState)
    }

    override fun onDestroy() {
        releaseTransferWakeLock()
        releaseMulticastLock()
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != localNetworkRequestCode) return

        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingLocalNetworkResult?.success(granted)
        pendingLocalNetworkResult = null
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == installPermissionRequestCode) {
            val path = pendingApkPath
            val result = pendingOpenFileResult
            pendingApkPath = null
            pendingOpenFileResult = null
            // Settings' resultCode is unreliable; check the actual permission.
            val response = if (!canInstallPackages()) {
                fileOpenResult(-3, "Installation permission was not granted. Open the APK again and enable Allow from this source.")
            } else if (path != null) {
                launchFile(path)
            } else {
                fileOpenResult(-4, "Open the APK again to continue installation.")
            }
            result?.success(response)
            return
        }
        if (requestCode == pickFilesRequestCode) {
            val result = pendingPickFilesResult ?: return
            pendingPickFilesResult = null
            if (resultCode != Activity.RESULT_OK || data == null) {
                result.success(null)
                return
            }
            result.success(pickedFilesFromResult(data))
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun checkLocalNetworkPermission(): Boolean {
        if (Build.VERSION.SDK_INT < 37) return true
        return checkSelfPermission(localNetworkPermission) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun requestLocalNetworkPermission(result: MethodChannel.Result) {
        if (checkLocalNetworkPermission()) {
            result.success(true)
            return
        }

        if (Build.VERSION.SDK_INT < 37) {
            result.success(true)
            return
        }

        pendingLocalNetworkResult?.success(false)
        pendingLocalNetworkResult = result
        requestPermissions(arrayOf(localNetworkPermission), localNetworkRequestCode)
    }

    private fun acquireMulticastLock(): Boolean {
        val existing = multicastLock
        if (existing?.isHeld == true) return true

        val wifiManager = applicationContext.getSystemService(
            Context.WIFI_SERVICE
        ) as WifiManager
        val lock = wifiManager.createMulticastLock("ShareViaLANDiscovery")
        lock.setReferenceCounted(false)
        return try {
            lock.acquire()
            multicastLock = lock
            true
        } catch (_: RuntimeException) {
            false
        }
    }

    private fun releaseMulticastLock(): Boolean {
        return try {
            multicastLock?.let { lock ->
                if (lock.isHeld) lock.release()
            }
            multicastLock = null
            true
        } catch (_: RuntimeException) {
            false
        }
    }

    private fun acquireTransferWakeLock(): Boolean {
        val existing = transferWakeLock
        if (existing?.isHeld == true) return true

        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        val lock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "ShareViaLAN::ActiveTransfer"
        )
        lock.setReferenceCounted(false)
        return try {
            lock.acquire()
            transferWakeLock = lock
            true
        } catch (_: RuntimeException) {
            false
        }
    }

    private fun releaseTransferWakeLock(): Boolean {
        return try {
            transferWakeLock?.let { lock ->
                if (lock.isHeld) lock.release()
            }
            transferWakeLock = null
            true
        } catch (_: RuntimeException) {
            false
        }
    }

    private fun pickFiles(
        result: MethodChannel.Result,
        allowMultiple: Boolean
    ) {
        if (pendingPickFilesResult != null) {
            result.error(
                "pick_in_progress",
                "A file picker is already open.",
                null
            )
            return
        }

        clearOldPickedFileCache()
        pendingPickFilesResult = result
        val action = Intent.ACTION_OPEN_DOCUMENT
        val intent = Intent(action).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, allowMultiple)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }

        try {
            startActivityForResult(intent, pickFilesRequestCode)
        } catch (_: ActivityNotFoundException) {
            pendingPickFilesResult = null
            result.error(
                "picker_unavailable",
                "No file picker is available on this device.",
                null
            )
        }
    }

    private fun pickedFilesFromResult(data: Intent): List<Map<String, Any>> {
        val uris = linkedSetOf<Uri>()
        val clipData = data.clipData
        if (clipData != null) {
            for (index in 0 until clipData.itemCount) {
                clipData.getItemAt(index).uri?.let { uris.add(it) }
            }
        }
        data.data?.let { uris.add(it) }

        val hasReadGrant =
            data.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0
        if (hasReadGrant) {
            for (uri in uris) {
                try {
                    contentResolver.takePersistableUriPermission(
                        uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION
                    )
                } catch (_: SecurityException) {
                    // The transient picker grant is enough for immediate sends.
                }
            }
        }

        return uris.map { uri ->
            val info = openableInfo(uri)
            mapOf(
                "identifier" to uri.toString(),
                "name" to cleanFileName(info.name ?: uri.lastPathSegment ?: "file"),
                "size" to if (info.size < 0L) 0L else info.size
            )
        }
    }

    private fun cachePickedFile(identifier: String, fileName: String): Map<String, Any>? {
        if (identifier.isBlank()) return null

        val uri = try {
            Uri.parse(identifier)
        } catch (_: RuntimeException) {
            return null
        }
        val resolvedName = cleanFileName(
            fileName.ifBlank { openableInfo(uri).name ?: "file" }
        )
        val directory = File(
            pickedFileCacheDirectory(),
            "${System.currentTimeMillis()}-${System.nanoTime()}"
        )
        if (!directory.mkdirs()) return null

        val destination = File(directory, resolvedName)
        return try {
            contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(destination).use { output ->
                    input.copyTo(output)
                }
            } ?: run {
                destination.delete()
                directory.delete()
                return null
            }

            mapOf(
                "path" to destination.absolutePath,
                "name" to resolvedName,
                "size" to destination.length()
            )
        } catch (_: IOException) {
            destination.delete()
            directory.delete()
            null
        } catch (_: SecurityException) {
            destination.delete()
            directory.delete()
            null
        }
    }

    private fun openableInfo(uri: Uri): OpenableInfo {
        var name: String? = null
        var size = -1L
        val projection = arrayOf(
            OpenableColumns.DISPLAY_NAME,
            OpenableColumns.SIZE
        )
        try {
            contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIndex =
                        cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (nameIndex >= 0 && !cursor.isNull(nameIndex)) {
                        name = cursor.getString(nameIndex)
                    }

                    val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                        size = cursor.getLong(sizeIndex)
                    }
                }
            }
        } catch (_: RuntimeException) {
            // Some providers expose streams but not metadata queries.
        }

        if (size < 0L) {
            try {
                contentResolver.openFileDescriptor(uri, "r")?.use { descriptor ->
                    if (descriptor.statSize >= 0L) {
                        size = descriptor.statSize
                    }
                }
            } catch (_: Exception) {
                // Size is optional; the cached file length is authoritative later.
            }
        }
        return OpenableInfo(name, size)
    }

    private fun pickedFileCacheDirectory(): File {
        return File(cacheDir, "lancom_picked")
    }

    private fun clearOldPickedFileCache() {
        val root = pickedFileCacheDirectory()
        val cutoff = System.currentTimeMillis() - 24L * 60L * 60L * 1000L
        root.listFiles()?.forEach { file ->
            if (file.lastModified() < cutoff) {
                file.deleteRecursively()
            }
        }
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        return powerManager.isIgnoringBatteryOptimizations(packageName)
    }

    private fun openBatteryOptimizationSettings(): Boolean {
        val intents = listOf(
            Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS),
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))
        )
        for (intent in intents) {
            try {
                startActivity(intent)
                return true
            } catch (_: RuntimeException) {
                // OEM devices may not provide the standard battery settings.
            }
        }
        return false
    }

    private fun openAppSettings() {
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
        intent.data = Uri.parse("package:$packageName")
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
    }

    private fun fileOpenResult(type: Int, message: String): Map<String, Any> {
        return mapOf("type" to type, "message" to message)
    }

    private fun canInstallPackages(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            packageManager.canRequestPackageInstalls()
    }

    private fun openFile(path: String, result: MethodChannel.Result) {
        if (pendingApkPath != null) {
            result.success(fileOpenResult(-4, "Finish the current installation permission request first."))
            return
        }
        val file = File(path)
        if (path.isBlank() || !file.isFile) {
            result.success(fileOpenResult(-2, "This file was moved or deleted. Receive it again to open it."))
            return
        }
        if (!file.canRead()) {
            result.success(fileOpenResult(-3, "ShareViaLAN can no longer read this file. Receive it again."))
            return
        }
        if (file.extension.equals("apk", ignoreCase = true) && !canInstallPackages()) {
            pendingApkPath = path
            pendingOpenFileResult = result
            try {
                val intent = Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName")
                )
                startActivityForResult(intent, installPermissionRequestCode)
            } catch (_: RuntimeException) {
                pendingApkPath = null
                pendingOpenFileResult = null
                result.success(fileOpenResult(-3, "Enable Allow from this source for ShareViaLAN in Android Settings, then open the APK again. This option may be blocked by your device administrator."))
            }
            return
        }
        result.success(launchFile(path))
    }

    private fun launchFile(path: String): Map<String, Any> {
        val file = File(path)
        if (!file.isFile) {
            return fileOpenResult(-2, "This file was moved or deleted. Receive it again to open it.")
        }
        return try {
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mimeTypeFor(file.name))
                clipData = ClipData.newRawUri(file.name, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(intent)
            fileOpenResult(0, "Opened")
        } catch (_: ActivityNotFoundException) {
            fileOpenResult(-1, "No installed app can open this file type.")
        } catch (_: SecurityException) {
            fileOpenResult(-3, "Android blocked access to this file. Check your device restrictions or receive it again.")
        } catch (_: RuntimeException) {
            fileOpenResult(-4, "Could not open this file. Open it from Downloads/ShareViaLAN or receive it again.")
        }
    }

    private fun openExternalVideo(source: String): Boolean {
        if (source.isBlank()) return false

        val uri = try {
            if (source.startsWith("http://") || source.startsWith("https://")) {
                Uri.parse(source)
            } else {
                val file = File(source)
                if (!file.exists()) return false
                FileProvider.getUriForFile(
                    this,
                    "$packageName.fileprovider",
                    file
                )
            }
        } catch (_: RuntimeException) {
            return false
        }

        val mimeType = videoMimeTypeFor(source)
        val viewIntent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mimeType)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val chooser = Intent.createChooser(viewIntent, "Open with installed player")
        chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

        return try {
            startActivity(chooser)
            true
        } catch (_: ActivityNotFoundException) {
            false
        } catch (_: RuntimeException) {
            false
        }
    }

    private fun playSound(sound: String): Boolean {
        val resourceId = when (sound) {
            "openChat" -> R.raw.foropenchat
            "notification" -> R.raw.fornotification
            else -> return false
        }

        return try {
            val player = MediaPlayer.create(this, resourceId) ?: return false
            player.setOnCompletionListener { completed ->
                completed.release()
            }
            player.setOnErrorListener { failed, _, _ ->
                failed.release()
                true
            }
            player.start()
            true
        } catch (_: RuntimeException) {
            false
        }
    }

    private fun publicDownloadPath(fileName: String): String {
        val displayName = uniqueDownloadName(cleanFileName(fileName))
        return File(publicDownloadDirectory(), displayName).absolutePath
    }

    private fun publishDownload(sourcePath: String, fileName: String): String? {
        val source = File(sourcePath)
        if (!source.exists() || !source.isFile) return null

        val displayName = uniqueDownloadName(cleanFileName(fileName))
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            publishDownloadWithMediaStore(source, displayName)
        } else {
            publishDownloadWithPublicFile(source, displayName)
        }
    }

    @TargetApi(Build.VERSION_CODES.Q)
    private fun publishDownloadWithMediaStore(
        source: File,
        displayName: String
    ): String? {
        val preferredMimeType = mimeTypeFor(displayName)
        val fallbackMimeType = "application/octet-stream"
        val mimeTypes = if (preferredMimeType == fallbackMimeType) {
            listOf(preferredMimeType)
        } else {
            listOf(preferredMimeType, fallbackMimeType)
        }

        for (mimeType in mimeTypes) {
            publishDownloadWithMediaStore(
                source,
                displayName,
                mimeType
            )?.let { return it }
        }
        return null
    }

    @TargetApi(Build.VERSION_CODES.Q)
    private fun publishDownloadWithMediaStore(
        source: File,
        displayName: String,
        mimeType: String
    ): String? {
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            put(MediaStore.MediaColumns.RELATIVE_PATH, downloadsRelativePath())
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }

        val resolver = applicationContext.contentResolver
        val uri = try {
            resolver.insert(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                values
            )
        } catch (_: IllegalArgumentException) {
            null
        } catch (_: SecurityException) {
            null
        } ?: return null

        return try {
            resolver.openOutputStream(uri)?.use { output ->
                FileInputStream(source).use { input ->
                    input.copyTo(output)
                }
            } ?: throw IOException("Could not open MediaStore output stream")

            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            File(publicDownloadDirectory(), displayName).absolutePath
        } catch (_: IOException) {
            resolver.delete(uri, null, null)
            null
        } catch (_: IllegalArgumentException) {
            resolver.delete(uri, null, null)
            null
        } catch (_: SecurityException) {
            resolver.delete(uri, null, null)
            null
        }
    }

    private fun publishDownloadWithPublicFile(
        source: File,
        displayName: String
    ): String? {
        return try {
            val directory = publicDownloadDirectory()
            if (!directory.exists() && !directory.mkdirs()) return null
            val destination = File(directory, displayName)
            FileInputStream(source).use { input ->
                destination.outputStream().use { output ->
                    input.copyTo(output)
                }
            }
            sendBroadcast(
                Intent(
                    Intent.ACTION_MEDIA_SCANNER_SCAN_FILE,
                    Uri.fromFile(destination)
                )
            )
            destination.absolutePath
        } catch (_: IOException) {
            null
        } catch (_: SecurityException) {
            null
        }
    }

    private fun uniqueDownloadName(fileName: String): String {
        val dotIndex = fileName.lastIndexOf('.')
        val base = if (dotIndex <= 0) fileName else fileName.substring(0, dotIndex)
        val extension = if (dotIndex <= 0) "" else fileName.substring(dotIndex)
        var counter = 0
        while (true) {
            val suffix = if (counter == 0) "" else " ($counter)"
            val candidate = "$base$suffix$extension"
            if (!downloadNameExists(candidate)) return candidate
            counter += 1
        }
    }

    private fun downloadNameExists(displayName: String): Boolean {
        val publicFile = File(publicDownloadDirectory(), displayName)
        if (publicFile.exists()) return true

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false

        val projection = arrayOf(MediaStore.MediaColumns._ID)
        val selection =
            "${MediaStore.MediaColumns.DISPLAY_NAME}=? AND ${MediaStore.MediaColumns.RELATIVE_PATH}=?"
        val args = arrayOf(displayName, downloadsRelativePath())
        applicationContext.contentResolver.query(
            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
            projection,
            selection,
            args,
            null
        )?.use { cursor ->
            return cursor.moveToFirst()
        }
        return false
    }

    private fun publicDownloadDirectory(): File {
        return File(
            Environment.getExternalStoragePublicDirectory(
                Environment.DIRECTORY_DOWNLOADS
            ),
            "ShareViaLAN"
        )
    }

    private fun downloadsRelativePath(): String {
        return "${Environment.DIRECTORY_DOWNLOADS}/ShareViaLAN/"
    }

    private fun cleanFileName(fileName: String): String {
        val name = fileName
            .split('/', '\\')
            .lastOrNull { it.trim().isNotEmpty() }
            ?.replace(Regex("[<>:\"|?*\\p{Cntrl}]"), "_")
            ?.replace(Regex("\\s+"), " ")
            ?.trim()
            ?: "file"

        val cleaned = if (name.isEmpty() || name == "." || name == "..") {
            "file"
        } else {
            name
        }
        if (cleaned.length <= 180) return cleaned

        val dotIndex = cleaned.lastIndexOf('.')
        if (dotIndex <= 0 || dotIndex > cleaned.length - 2) {
            return cleaned.substring(0, 180).trim()
        }

        val extension = cleaned.substring(dotIndex)
        if (extension.length > 40) return cleaned.substring(0, 180).trim()
        val maxBaseLength = maxOf(1, 180 - extension.length)
        return "${cleaned.substring(0, maxBaseLength).trim()}$extension"
    }

    private fun mimeTypeFor(fileName: String): String {
        val extension = fileName.substringAfterLast('.', "")
            .lowercase(Locale.US)
        if (extension.isEmpty()) return "application/octet-stream"
        if (extension == "apk") return "application/vnd.android.package-archive"
        if (extension == "pkg") return "application/octet-stream"
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
            ?: "application/octet-stream"
    }

    private fun videoMimeTypeFor(source: String): String {
        val mimeType = mimeTypeFor(source)
        return if (mimeType.startsWith("video/")) mimeType else "video/*"
    }

    private data class OpenableInfo(
        val name: String?,
        val size: Long
    )
}
