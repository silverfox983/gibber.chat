importScripts('../lib/transformers.min.js');

let pipe = null;

async function init() {
  try {
    pipe = await transformers.pipeline(
      'automatic-speech-recognition',
      'Xenova/whisper-tiny.en',
      {
        device: 'wasm',
        progress_callback: (progress) => {
          let pct = 0;
          if (progress.status === 'initiate') pct = 0.05;
          else if (progress.status === 'loading' && progress.file) {
            pct = 0.05 + (progress.loaded / progress.total) * 0.7;
          }
          else if (progress.status === 'ready') pct = 1.0;
          self.postMessage(JSON.stringify({ type: 'progress', progress: pct }));
        },
      }
    );
    self.postMessage(JSON.stringify({ type: 'ready' }));
  } catch (err) {
    self.postMessage(JSON.stringify({ type: 'error', error: err.message }));
  }
}

init();

self.onmessage = async function(e) {
  let data;
  try {
    data = JSON.parse(e.data);
  } catch (err) {
    return;
  }

  if (data.type === 'transcribe' && pipe) {
    try {
      const audioData = data.audioData;
      if (!audioData || !Array.isArray(audioData)) return;

      const result = await pipe(audioData, {
        chunk_length_s: 30,
        stride_length_s: 5,
        return_timestamps: true,
        language: 'en',
      });

      if (result?.text) {
        self.postMessage(JSON.stringify({
          type: 'final',
          text: result.text.trim(),
        }));
      }
    } catch (err) {
      self.postMessage(JSON.stringify({ type: 'error', error: err.message }));
    }
  }
};
