class VoiceProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.pitch = 1.0;
    this.robotDepth = 0.0;
    this.robotFrequency = 50.0;
    this.phoneEnabled = false;
    this.noiseGateEnabled = false;
    this.noiseGateThreshold = -55.0;
    this.enabled = true;

    // Granular synthesis state
    this.grainSize = 320;
    this.hopOut = 160;
    this.hopIn = 160;
    this.hopInFrac = 0.0;
    this.inputBuf = new Float32Array(4096);
    this.inCount = 0;
    this.outBuf = new Float32Array(16384);
    this.outHead = 0;
    this.outTail = 0;
    this.hannWindow = null;

    // Robot modulation state
    this.robotPhase = 0.0;

    // Noise gate state
    this.gateEnvelope = 1.0;

    // Phone filter state (biquad bandpass)
    this.phoneB0 = 0;
    this.phoneB1 = 0;
    this.phoneB2 = 0;
    this.phoneA1 = 0;
    this.phoneA2 = 0;
    this.phoneZ1 = 0;
    this.phoneZ2 = 0;
    this.phoneInitialized = false;

    this.port.onmessage = (e) => {
      const d = e.data;
      if (d.type === 'config') {
        this.pitch = d.pitch ?? this.pitch;
        this.robotDepth = d.robotDepth ?? this.robotDepth;
        this.robotFrequency = d.robotFrequency ?? this.robotFrequency;
        this.phoneEnabled = d.phoneEnabled ?? this.phoneEnabled;
        this.noiseGateEnabled = d.noiseGateEnabled ?? this.noiseGateEnabled;
        this.noiseGateThreshold = d.noiseGateThreshold ?? this.noiseGateThreshold;
        this.enabled = d.enabled ?? this.enabled;
        if (d.sampleRate) {
          this.grainSize = Math.max(128, Math.min(640, Math.floor(d.sampleRate * 0.02))) & 0xFFFE;
          this.hopOut = this.grainSize / 2;
          this._buildHann();
          this._buildPhoneFilter(d.sampleRate);
        }
        if (d.reset) {
          this.inCount = 0;
          this.outHead = 0;
          this.outTail = 0;
          this.hopInFrac = 0.0;
          this.robotPhase = 0.0;
          this.gateEnvelope = 1.0;
          this.phoneZ1 = 0;
          this.phoneZ2 = 0;
        }
      }
    };
  }

  _buildHann() {
    this.hannWindow = new Float32Array(this.grainSize);
    for (let i = 0; i < this.grainSize; i++) {
      this.hannWindow[i] = 0.5 * (1.0 - Math.cos(2.0 * Math.PI * i / (this.grainSize - 1)));
    }
  }

  _buildPhoneFilter(sr) {
    // 2nd-order Butterworth bandpass 300-3400Hz
    const fl = 300, fh = 3400;
    const f1 = 2 * Math.tan(Math.PI * fl / sr);
    const f2 = 2 * Math.tan(Math.PI * fh / sr);
    // Simple biquad bandpass
    const w0 = 2 * Math.PI * Math.sqrt(fl * fh) / sr;
    const Q = w0 / (f2 - f1) * Math.sqrt(fl * fh);
    const alpha = Math.sin(w0) / (2 * Q);
    const cosw0 = Math.cos(w0);
    const a0 = 1 + alpha;
    this.phoneB0 = alpha / a0;
    this.phoneB1 = 0;
    this.phoneB2 = -alpha / a0;
    this.phoneA1 = -2 * cosw0 / a0;
    this.phoneA2 = (1 - alpha) / a0;
    this.phoneInitialized = true;
  }

  _ensureInputCapacity(needed) {
    if (this.inputBuf.length >= needed) return;
    const newBuf = new Float32Array(Math.max(needed, this.inputBuf.length * 2));
    newBuf.set(this.inputBuf.subarray(0, this.inCount));
    this.inputBuf = newBuf;
  }

  _ensureOutputCapacity(needed) {
    if (this.outBuf.length >= needed) return;
    const newBuf = new Float32Array(Math.max(needed, this.outBuf.length * 2));
    const dataLen = this.outHead - this.outTail;
    if (dataLen > 0) newBuf.set(this.outBuf.subarray(this.outTail, this.outHead));
    this.outHead = dataLen;
    this.outTail = 0;
    this.outBuf = newBuf;
  }

  process(inputs, outputs, parameters) {
    const input = inputs[0];
    const output = outputs[0];
    if (!input || !input[0] || !output || !output[0]) return true;
    if (!this.enabled) {
      output[0].set(input[0]);
      return true;
    }

    const numFrames = input[0].length;
    const inData = input[0];
    const outData = output[0];

    // Push input into buffer
    this._ensureInputCapacity(this.inCount + numFrames);
    this.inputBuf.set(inData, this.inCount);
    this.inCount += numFrames;

    const pitchFactor = Math.max(0.5, Math.min(2.0, this.pitch));

    // Granular synthesis pitch shift
    if (pitchFactor !== 1.0 && this.hannWindow) {
      this.hopInFrac += this.hopOut * pitchFactor;
      this.hopIn = Math.max(1, Math.min(this.grainSize * 4, Math.floor(this.hopInFrac)));
      this.hopInFrac -= this.hopIn;

      while (this.inCount >= this.grainSize && (this.outHead - this.outTail) < 9600) {
        this._ensureOutputCapacity(this.outHead + this.grainSize);
        for (let i = 0; i < this.grainSize; i++) {
          this.outBuf[this.outHead + i] += this.inputBuf[i] * this.hannWindow[i];
        }
        this.outHead += this.hopOut;

        const consumed = Math.min(this.hopIn, this.inCount);
        this.inputBuf.copyWithin(0, consumed, this.inCount);
        this.inCount -= consumed;

        this.hopInFrac += this.hopOut * pitchFactor;
        this.hopIn = Math.max(1, Math.min(this.grainSize * 4, Math.floor(this.hopInFrac)));
        this.hopInFrac -= this.hopIn;
      }
    } else {
      // No pitch shift: pass through to output
      this._ensureOutputCapacity(this.outHead + numFrames);
      this.outBuf.set(inData, this.outHead);
      this.outHead += numFrames;
      this.inCount = 0;
    }

    // Read from output buffer
    const avail = this.outHead - this.outTail;
    const toRead = Math.min(numFrames, avail);

    // Process effects on output samples
    for (let i = 0; i < numFrames; i++) {
      let sample;
      if (i < toRead) {
        sample = this.outBuf[this.outTail + i];
        this.outBuf[this.outTail + i] = 0; // Clear for overlap-add
      } else {
        sample = i > 0 ? outData[i - 1] : 0;
      }

      // Robot modulation (ring mod)
      if (this.robotDepth > 0) {
        const mod = Math.sin(2.0 * Math.PI * this.robotPhase);
        this.robotPhase += this.robotFrequency / sampleRate;
        if (this.robotPhase >= 1.0) this.robotPhase -= 1.0;
        sample = sample * (1.0 - this.robotDepth + this.robotDepth * mod);
      }

      // Phone filter (biquad bandpass direct form II)
      if (this.phoneEnabled && this.phoneInitialized) {
        const x = sample;
        const y = this.phoneB0 * x + this.phoneZ1;
        this.phoneZ1 = this.phoneB1 * x - this.phoneA1 * y + this.phoneZ2;
        this.phoneZ2 = this.phoneB2 * x - this.phoneA2 * y;
        sample = y;
      }

      // Noise gate
      if (this.noiseGateEnabled) {
        // Simple envelope-based gate
        const absSample = Math.abs(sample);
        const dbfs = absSample > 0 ? 20 * Math.log10(absSample / 32768.0) : -96.0;
        const target = dbfs < this.noiseGateThreshold ? 0.05 : 1.0;
        const attackCoeff = 1.0 - 1.0 / (1.0 + 48000 / numFrames * 0.005);
        const releaseCoeff = 1.0 - 1.0 / (1.0 + 48000 / numFrames * 0.05);
        const coeff = target > this.gateEnvelope ? attackCoeff : releaseCoeff;
        this.gateEnvelope += (target - this.gateEnvelope) * coeff;
        this.gateEnvelope = Math.max(0.05, Math.min(1.0, this.gateEnvelope));
        sample *= this.gateEnvelope;
      }

      outData[i] = sample;
    }

    this.outTail += toRead;

    // Compact output buffer if needed
    if (this.outTail > this.grainSize * 8) {
      const dataLen = this.outHead - this.outTail;
      if (dataLen > 0) {
        this.outBuf.copyWithin(0, this.outTail, this.outHead);
      }
      this.outHead = dataLen;
      this.outTail = 0;
    }

    return true;
  }
}

registerProcessor('voice-processor', VoiceProcessor);