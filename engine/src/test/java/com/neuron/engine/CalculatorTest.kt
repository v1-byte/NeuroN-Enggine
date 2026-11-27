package com.neuron.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class CalculatorTest {
    private fun ev(s: String) = Calculator.eval(s)

    @Test fun precedence() { assertEquals(14.0, ev("2+3*4"), 0.0) }
    @Test fun parentheses() { assertEquals(20.0, ev("(2+3)*4"), 0.0) }
    @Test fun whitespaceIgnored() { assertEquals(5.0, ev("2 + 3"), 0.0) }
    @Test fun powerIsRightAssociative() { assertEquals(512.0, ev("2^3^2"), 0.0) }
    @Test fun unaryMinusBindsLooserThanPower() { assertEquals(-4.0, ev("-2^2"), 0.0) }
    @Test fun modulo() { assertEquals(2.0, ev("10%4"), 0.0) }
    @Test fun decimals() { assertEquals(3.75, ev("1.5*2.5"), 1e-9) }

    @Test fun divisionByZeroRejected() { assertThrows(IllegalArgumentException::class.java) { ev("1/0") } }
    @Test fun danglingOperatorRejected() { assertThrows(IllegalStateException::class.java) { ev("2+") } }
    @Test fun garbageRejected() { assertThrows(IllegalArgumentException::class.java) { ev("abc") } }
    @Test fun unbalancedParenRejected() { assertThrows(IllegalArgumentException::class.java) { ev("(1+2") } }
}
