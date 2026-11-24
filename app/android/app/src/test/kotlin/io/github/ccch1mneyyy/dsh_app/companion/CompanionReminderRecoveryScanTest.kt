package io.github.ccch1mneyyy.dsh_app.companion

import org.junit.Assert.assertEquals
import org.junit.Test

class CompanionReminderRecoveryScanTest {
    @Test fun crossingTheDeadlineOrRollingTheClockBackDoesNotStealAPendingTask() {
        for (liveFirst in listOf(true, false)) {
            val live = CompanionReminderScan()
            val missed = CompanionReminderScan()
            val first = if (liveFirst) live else missed
            val second = if (liveFirst) missed else live
            val actions = mutableListOf<String>()
            first.advance(second, { "shared" }) { actions += "start:$it"; false }
            second.advance(first, { "shared" }) { error("cannot resume the other scan's task") }
            assertEquals(false, first.rewindWhenIdle())
            first.advance(second, { error("must resume the in-flight batch") }) { actions += "finish:$it"; true }
            second.advance(first, { cursor ->
                assertEquals("shared", cursor)
                "next"
            }) { actions += "next:$it"; true }
            assertEquals(true, first.rewindWhenIdle())
            first.advance(second, { cursor -> assertEquals("", cursor); null }) { error("empty scan") }
            assertEquals(true, first.done)
            assertEquals(listOf("start:shared", "finish:shared", "next:next"), actions)
        }
    }
}
