//
//  BiquadFilter.swift
//  Audioo
//
//  Created by Yifan Deng on 2025/11/20.
//

import Foundation
import Accelerate

class BiquadFilter {
    private var b0: Float = 1.0
    private var b1: Float = 0.0
    private var b2: Float = 0.0
    private var a1: Float = 0.0
    private var a2: Float = 0.0
    
    private var x1: Float = 0.0
    private var x2: Float = 0.0
    private var y1: Float = 0.0
    private var y2: Float = 0.0
    
    func setPeakingEQ(frequency: Float, sampleRate: Float, q: Float, gainDB: Float) {
        // Clamp parameters to safe ranges
        let freq = max(20, min(frequency, sampleRate / 2.5))
        let qVal = max(0.1, min(q, 10.0))
        let gain = max(-24, min(gainDB, 24))
        
        let omega = 2.0 * Float.pi * freq / sampleRate
        let sinOmega = sin(omega)
        let cosOmega = cos(omega)
        let alpha = sinOmega / (2.0 * qVal)
        let A = pow(10.0, gain / 40.0)
        
        b0 = 1.0 + alpha * A
        b1 = -2.0 * cosOmega
        b2 = 1.0 - alpha * A
        let a0 = 1.0 + alpha / A
        a1 = -2.0 * cosOmega
        a2 = 1.0 - alpha / A
        
        // Normalize coefficients
        b0 /= a0
        b1 /= a0
        b2 /= a0
        a1 /= a0
        a2 /= a0
        
        // Check for valid coefficients
        if !b0.isFinite || !b1.isFinite || !b2.isFinite || !a1.isFinite || !a2.isFinite {
            // Reset to bypass state
            b0 = 1.0
            b1 = 0.0
            b2 = 0.0
            a1 = 0.0
            a2 = 0.0
        }
    }
    
    func process(input: Float) -> Float {
        // Check for invalid input
        guard input.isFinite else { return 0 }
        
        let output = b0 * input + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        
        // Update state variables
        x2 = x1
        x1 = input
        y2 = y1
        y1 = output
        
        // Check for NaN or infinity and reset if needed
        if !output.isFinite {
            reset()
            return input
        }
        
        return output
    }
    
    func reset() {
        x1 = 0
        x2 = 0
        y1 = 0
        y2 = 0
    }
}

class MultiChannelBiquadFilter {
    private var leftFilter: BiquadFilter
    private var rightFilter: BiquadFilter
    
    init() {
        leftFilter = BiquadFilter()
        rightFilter = BiquadFilter()
    }
    
    func setPeakingEQ(frequency: Float, sampleRate: Float, q: Float, gainDB: Float) {
        leftFilter.setPeakingEQ(frequency: frequency, sampleRate: sampleRate, q: q, gainDB: gainDB)
        rightFilter.setPeakingEQ(frequency: frequency, sampleRate: sampleRate, q: q, gainDB: gainDB)
    }
    
    func processLeft(_ sample: Float) -> Float {
        return leftFilter.process(input: sample)
    }
    
    func processRight(_ sample: Float) -> Float {
        return rightFilter.process(input: sample)
    }
    
    func reset() {
        leftFilter.reset()
        rightFilter.reset()
    }
}
