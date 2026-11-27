package io.github.ccch1mneyyy.dsh_app.window

import org.junit.Assert.*
import org.junit.Test

class FloatingChatPlacementTest {
    @Test fun portraitOpensAtBottomRightAtAboutHalfTheArea() {
        val p = FloatingChatPlacement.inArea(1200, 2400, 36)
        assertEquals(FloatingChatPlacement(264, 924, 1164, 2364), p)
        assertEquals(0.45, (p.right - p.left).toDouble() * (p.bottom - p.top) / (1200 * 2400), 0.001)
    }

    @Test fun landscapeStaysInsideTheUsableScreen() {
        val p = FloatingChatPlacement.inArea(2400, 1000, 36)
        assertEquals(FloatingChatPlacement(564, 364, 2364, 964), p)
    }

    @Test fun largeInsetsDoNotInvertTheWindow() {
        val p = FloatingChatPlacement.inArea(300, 500, 160)
        assertTrue(p.left >= 0)
        assertTrue(p.top >= 0)
        assertTrue(p.right > p.left)
        assertTrue(p.bottom > p.top)
        assertTrue(p.right <= 300)
        assertTrue(p.bottom <= 500)
    }
}
