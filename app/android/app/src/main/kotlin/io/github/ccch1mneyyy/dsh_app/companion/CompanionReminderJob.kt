package io.github.ccch1mneyyy.dsh_app.companion

import android.app.AlarmManager
import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.database.sqlite.SQLiteDatabaseLockedException
import android.os.Handler
import android.os.Looper
import java.util.concurrent.Executors

internal object CompanionReminderWork {
    // Both Android components live in :companion_reminder. Only one physical
    // register/cancel/notify can run, even when a Job and an alarm arrive together.
    val executor = Executors.newSingleThreadExecutor { work ->
        Thread(work, "dsh-companion-reminder").apply { isDaemon = true }
    }
}

internal class CompanionReminderScan {
    private var cursor = ""
    private var pendingTask: String? = null
    var done = false
        private set

    fun rewindWhenIdle(): Boolean {
        if (pendingTask != null) return false
        cursor = ""
        done = false
        return true
    }

    fun advance(other: CompanionReminderScan, next: (String) -> String?, resume: (String) -> Boolean) {
        if (done) return
        val task = pendingTask ?: next(cursor)
        if (task == null) {
            done = true
        } else if (other.pendingTask == task || resume(task)) {
            // A time change may move the same id into both scans. The lane
            // already draining its revisions keeps ownership until it finishes.
            cursor = task
            pendingTask = null
        } else {
            pendingTask = task
        }
    }
}

/** One lifecycle recovery opportunity; no periodic timer, Flutter, network, or model. */
class CompanionReminderJob : JobService() {
    private class Run(val parameters: JobParameters) {
        @Volatile var stopped = false
        val live = CompanionReminderScan()
        val missed = CompanionReminderScan()
        var recheckMissed = false
    }
    @Volatile private var active: Run? = null
    private val main = Handler(Looper.getMainLooper())

    override fun onStartJob(params: JobParameters): Boolean {
        active?.stopped = true
        val run = Run(params)
        active = run
        next(run)
        return true
    }

    private fun next(run: Run) {
        CompanionReminderWork.executor.execute {
            if (run.stopped) return@execute
            try {
                val executorId = CompanionReminderPlatform.executorId(applicationContext)
                var exhausted = false
                CompanionReminderLedger.open(applicationContext).use { ledger ->
                    val runner = CompanionReminderRunner(ledger, CompanionReminderAndroid(applicationContext), executorId)
                    if (!run.live.done) {
                        run.live.advance(run.missed, { cursor ->
                            ledger.recoveryBatch(executorId, System.currentTimeMillis(), cursor, 1).firstOrNull()
                        }) { runner.resume(it) }
                        // A task behind the missed cursor may have expired while live work was draining.
                        if (run.live.done) run.recheckMissed = true
                    }
                    if (!run.stopped) {
                        if (run.recheckMissed && run.missed.rewindWhenIdle()) run.recheckMissed = false
                        run.missed.advance(run.live, { cursor ->
                            ledger.missedRecoveryBatch(executorId, System.currentTimeMillis(), cursor, 1).firstOrNull()
                        }) { runner.resume(it) }
                    }
                    exhausted = run.live.done && run.missed.done
                }
                if (run.stopped) return@execute
                if (exhausted) finish(run, false)
                else next(run) // Yield between bounded chunks so alarms can run.
            } catch (_: SQLiteDatabaseLockedException) {
                finish(run, true)
            } catch (_: Exception) {
                // Missing/old/corrupt databases do not create a perpetual retry job.
                // A committed effect claim remains; a foreground opportunity can retry.
                finish(run, false)
            }
        }
    }

    private fun finish(run: Run, retry: Boolean) {
        main.post {
            if (!run.stopped && active === run) {
                run.stopped = true
                active = null
                jobFinished(run.parameters, retry)
            }
        }
    }

    override fun onStopJob(params: JobParameters): Boolean {
        active?.stopped = true
        active = null
        return true
    }

    class Receiver : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action in setOf(Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED,
                    Intent.ACTION_TIME_CHANGED, Intent.ACTION_TIMEZONE_CHANGED,
                    AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED)) {
                try { schedule(context) } catch (_: Exception) { /* A later foreground opportunity can retry. */ }
            }
        }
    }

    companion object {
        private const val JOB_ID = 0x434d5001
        fun schedule(context: Context): Boolean {
            // Replacing this one Job restarts its cursor, including a task inserted
            // behind an in-progress scan. The old callback cannot finish the new Job.
            val job = JobInfo.Builder(JOB_ID, ComponentName(context, CompanionReminderJob::class.java))
                .setMinimumLatency(1).build()
            return context.getSystemService(JobScheduler::class.java).schedule(job) == JobScheduler.RESULT_SUCCESS
        }
    }
}
