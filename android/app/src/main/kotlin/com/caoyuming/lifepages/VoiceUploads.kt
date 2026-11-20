package com.caoyuming.lifepages

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.content.pm.ApplicationInfo
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.util.Base64
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.security.KeyStore
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal object VoiceUploads {
    private val ids = Regex("[a-f0-9]{32}")
    private const val alias = "lifepages.voice.upload.v1"
    private const val maxAudio = 6_000_000L
    private val disk = Executors.newSingleThreadExecutor()
    private val ui = Handler(Looper.getMainLooper())

    fun register(context: Context, messenger: BinaryMessenger) {
        MethodChannel(messenger, "life_pages/voice_uploads").setMethodCallHandler { call, result ->
            if (call.method !in setOf("enqueue", "pending", "retry", "pause")) {
                result.notImplemented()
                return@setMethodCallHandler
            }
            disk.execute {
                try {
                    val base = base(context, checkNotNull(call.argument<String>("base")))
                    val book = id(call.argument<String>("book"))
                    val value: Any? = when (call.method) {
                        "pending" -> pending(context, base, book)
                        "enqueue" -> {
                            val message = id(call.argument<String>("message"))
                            val request = id(call.argument<String>("request"))
                            val audio = source(context, checkNotNull(call.argument<String>("path")))
                            enqueue(context, base, book, message, request, audio,
                                checkNotNull(call.argument<String>("token")))
                            wave(context, message).path
                        }
                        "pause" -> {
                            pause(context, base, book)
                            null
                        }
                        else -> {
                            val message = id(call.argument<String>("message"))
                            retry(context, base, book, message, checkNotNull(call.argument<String>("token")))
                            null
                        }
                    }
                    ui.post { result.success(value) }
                } catch (_: Exception) {
                    ui.post { result.error("voice_upload", "暂时无法安排原声上传，录音已保留", null) }
                }
            }
        }
    }

    private fun id(value: String?): String = checkNotNull(value).also { require(ids.matches(it)) }

    private fun base(context: Context, value: String): String {
        val uri = URI(value)
        val debugLoopback = (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0 &&
            uri.scheme == "http" && uri.host == "127.0.0.1"
        require(value == "https://onesay.top/lifepages" ||
            (debugLoopback && uri.rawUserInfo == null && uri.rawQuery == null &&
                uri.rawFragment == null && uri.path.isEmpty()))
        return value
    }

    private fun source(context: Context, path: String): File {
        val file = File(path).canonicalFile
        val documents = File(context.applicationInfo.dataDir, "app_flutter").canonicalFile
        require(file.parentFile == documents && file.name.endsWith(".wav") &&
            file.isFile && file.length() in 44L..maxAudio)
        return file
    }

    private fun directory(context: Context) = File(context.noBackupFilesDir, "voice-uploads")
        .also { if (!it.isDirectory) check(it.mkdirs() || it.isDirectory) }

    private fun entry(context: Context, message: String) = AtomicFile(File(directory(context), "$message.json"))
    private fun wave(context: Context, message: String) = File(directory(context), "$message.wav")
    private fun scheduler(context: Context) = context.getSystemService(JobScheduler::class.java)

    @Synchronized
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build())
            generateKey()
        }
    }

    private fun seal(token: String): String {
        require(token.isNotEmpty() && '\r' !in token && '\n' !in token)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        return Base64.encodeToString(cipher.iv + cipher.doFinal(token.toByteArray()), Base64.NO_WRAP)
    }

    private fun open(secret: String): String {
        val bytes = Base64.decode(secret, Base64.NO_WRAP)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes, 0, 12))
        return cipher.doFinal(bytes, 12, bytes.size - 12).decodeToString()
    }

    private fun AtomicFile.write(fill: (java.io.FileOutputStream) -> Unit) {
        val output = startWrite()
        try {
            fill(output)
            finishWrite(output)
        } catch (e: Exception) {
            failWrite(output)
            throw e
        }
    }

    private fun save(context: Context, message: String, job: JSONObject) =
        entry(context, message).write { it.write(job.toString().toByteArray()) }

    @Synchronized
    private fun enqueue(context: Context, base: String, book: String, message: String,
                        request: String, source: File, token: String) {
        val record = entry(context, message)
        if (!record.baseFile.exists()) {
            AtomicFile(wave(context, message)).write { output -> source.inputStream().use { it.copyTo(output) } }
            val used = scheduler(context).allPendingJobs.mapTo(mutableSetOf()) { it.id }
            // Also reserve the ids of blocked uploads retained for manual retry.
            for (file in directory(context).listFiles().orEmpty().filter { it.extension == "json" }) {
                runCatching { used.add(JSONObject(file.readText()).getInt("job")) }
            }
            var jobId = message.hashCode() and Int.MAX_VALUE
            while (jobId in used) jobId = if (jobId == Int.MAX_VALUE) 0 else jobId + 1
            save(context, message, JSONObject().put("base", base).put("book", book)
                .put("request", request).put("token", seal(token)).put("job", jobId))
        }
        val job = JSONObject(record.readFully().decodeToString())
        check(job.getString("base") == base && job.getString("book") == book &&
            job.getString("request") == request)
        schedule(context, message, job)
    }

    private fun schedule(context: Context, message: String, job: JSONObject) {
        val scheduler = scheduler(context)
        val jobId = job.getInt("job")
        if (job.optBoolean("blocked") || scheduler.getPendingJob(jobId) != null) return
        val builder = JobInfo.Builder(jobId, ComponentName(context, VoiceUploadService::class.java))
            .setMinimumLatency(2500)
            .setBackoffCriteria(30_000, JobInfo.BACKOFF_POLICY_EXPONENTIAL)
            .setPersisted(true)
            .setExtras(PersistableBundle().apply { putString("message", message) })
        if (Build.VERSION.SDK_INT >= 28) {
            // The Android validation probe can be blocked even when our server is reachable.
            builder.setRequiredNetwork(NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET).build())
        } else {
            builder.setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
        }
        if (Build.VERSION.SDK_INT >= 33) builder.setPriority(JobInfo.PRIORITY_LOW)
        check(scheduler.schedule(builder.build()) == JobScheduler.RESULT_SUCCESS)
    }

    @Synchronized
    private fun inBook(context: Context, base: String, book: String): List<Pair<String, JSONObject>> = buildList {
        for (file in directory(context).listFiles().orEmpty()) {
            val message = file.nameWithoutExtension
            if (file.extension != "json" || !ids.matches(message)) continue
            val job = runCatching { JSONObject(entry(context, message).readFully().decodeToString()) }.getOrNull() ?: continue
            if (job.optString("base") != base || job.optString("book") != book) continue
            add(message to job)
        }
    }

    @Synchronized
    private fun pending(context: Context, base: String, book: String): Map<String, Any> = buildMap {
        for ((message, job) in inBook(context, base, book)) {
            val scheduled = runCatching { schedule(context, message, job) }.isSuccess
            put(message, mapOf("path" to wave(context, message).path,
                "blocked" to (job.optBoolean("blocked") || !scheduled)))
        }
    }

    @Synchronized
    private fun pause(context: Context, base: String, book: String) {
        for ((message, job) in inBook(context, base, book)) {
            job.put("blocked", true).remove("token")
            save(context, message, job)
            scheduler(context).cancel(job.getInt("job"))
        }
    }

    @Synchronized
    private fun retry(context: Context, base: String, book: String, message: String, token: String) {
        val record = entry(context, message)
        if (!record.baseFile.exists()) return
        val job = JSONObject(record.readFully().decodeToString())
        check(job.getString("base") == base && job.getString("book") == book)
        job.put("token", seal(token)).remove("blocked")
        save(context, message, job)
        schedule(context, message, job)
    }

    @Synchronized
    fun read(context: Context, message: String, jobId: Int): JSONObject? {
        val record = entry(context, id(message))
        if (!record.baseFile.exists()) return null
        return JSONObject(record.readFully().decodeToString())
            .takeIf { it.getInt("job") == jobId && !it.optBoolean("blocked") }
    }

    fun connect(context: Context, message: String, job: JSONObject,
                network: android.net.Network?): HttpURLConnection {
        val base = base(context, job.getString("base"))
        val book = id(job.getString("book"))
        val request = id(job.getString("request"))
        val url = URI("$base/api/people/$book/voice-turns/$request/audio").toURL()
        val file = wave(context, message)
        if (!file.exists()) throw IOException("Original audio is unavailable")
        return ((network?.openConnection(url) ?: url.openConnection()) as HttpURLConnection).apply {
            requestMethod = "PUT"
            connectTimeout = 15_000
            readTimeout = 60_000
            instanceFollowRedirects = false
            doOutput = true
            setRequestProperty("Content-Type", "audio/wav")
            setRequestProperty("Authorization", "Bearer ${open(job.getString("token"))}")
            setFixedLengthStreamingMode(file.length())
        }
    }

    fun send(context: Context, message: String, connection: HttpURLConnection): Int {
        wave(context, message).inputStream().use { file ->
            connection.outputStream.use { file.copyTo(it) }
        }
        return connection.responseCode
    }

    @Synchronized
    fun finish(context: Context, message: String, job: JSONObject, uploaded: Boolean): Boolean {
        val current = read(context, message, job.getInt("job")) ?: return false
        if (uploaded) {
            entry(context, message).delete()
            AtomicFile(wave(context, message)).delete()
            return false
        }
        // A manual retry may already have supplied fresh credentials.
        if (current.getString("token") != job.getString("token")) return true
        current.put("blocked", true).remove("token")
        save(context, message, current)
        return false
    }
}

class VoiceUploadService : JobService() {
    private class Upload {
        @Volatile var stopped = false
        @Volatile var connection: HttpURLConnection? = null
    }

    private val active = mutableMapOf<Int, Upload>()
    private val ui = Handler(Looper.getMainLooper())

    override fun onStartJob(params: JobParameters): Boolean {
        val message = params.extras.getString("message") ?: return false
        val upload = Upload()
        active[params.jobId] = upload
        worker.execute {
            var retry = false
            try {
                val job = VoiceUploads.read(this, message, params.jobId)
                if (job != null && !upload.stopped) {
                    val connection = VoiceUploads.connect(this, message, job,
                        if (Build.VERSION.SDK_INT >= 28) params.network else null)
                    upload.connection = connection
                    if (!upload.stopped) {
                        val status = VoiceUploads.send(this, message, connection)
                        retry = when (status) {
                            204 -> VoiceUploads.finish(this, message, job, uploaded = true)
                            400, 401, 403, 409, 413, 422 -> VoiceUploads.finish(this, message, job, uploaded = false)
                            else -> true
                        }
                    }
                }
            } catch (_: Exception) {
                retry = true
            } finally {
                upload.connection?.disconnect()
                ui.post {
                    if (active[params.jobId] === upload) {
                        active.remove(params.jobId)
                        jobFinished(params, retry)
                    }
                }
            }
        }
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean {
        active.remove(params.jobId)?.let { upload ->
            upload.stopped = true
            // Disconnect outside the main thread and wake a blocked socket write.
            Thread { upload.connection?.disconnect() }.start()
        }
        return true
    }

    private companion object {
        val worker = Executors.newSingleThreadExecutor()
    }
}
