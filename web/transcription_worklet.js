class TranscriptionProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.bufferSize = 16000;
    this.buffer = new Float32Array(this.bufferSize);
    this.bufferIndex = 0;
  }

  static get parameterDescriptors() {
    return [];
  }

  process(inputs, outputs, parameters) {
    const input = inputs[0];
    if (!input || !input[0]) return true;

    const inputData = input[0];
    const blockSize = inputData.length;

    for (let i = 0; i < blockSize; i++) {
      this.buffer[this.bufferIndex++] = inputData[i];

      if (this.bufferIndex >= this.bufferSize) {
        const chunk = new Float32Array(this.buffer);
        this.port.postMessage({ type: 'chunk', data: chunk.buffer }, [chunk.buffer]);

        this.buffer = new Float32Array(this.bufferSize);
        this.bufferIndex = 0;
      }
    }

    return true;
  }
}

registerProcessor('transcription-processor', TranscriptionProcessor);
