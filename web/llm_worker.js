importScripts('../lib/webllm.js');

let engine = null;
let modelId = 'Llama-3.2-1B-Instruct-q4f16_1-MLC';

async function init() {
  try {
    self.postMessage(JSON.stringify({ type: 'progress', progress: 0.0, text: 'Starting download...' }));

    engine = await webllm.CreateMLCEngine(modelId, {
      initProgressCallback: (report) => {
        let pct = 0.0;
        if (report.progress !== undefined) {
          pct = report.progress;
        }
        self.postMessage(JSON.stringify({
          type: 'progress',
          progress: pct,
          text: report.text || 'Loading model...'
        }));
      },
    });

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

  if (data.type === 'query' && engine) {
    try {
      const systemPrompt = data.context || 'You are a helpful AI assistant in a video call. Keep responses brief and helpful.';

      const messages = [
        { role: 'system', content: systemPrompt },
        { role: 'user', content: data.query }
      ];

      let completion = '';
      const lastMessage = messages[messages.length - 1];

      const chunkGenerator = await engine.chat.completions.create({
        messages: messages,
        temperature: 0.7,
        max_tokens: 256,
        stream: true,
      });

      for await (const chunk of chunkGenerator) {
        const content = chunk.choices[0]?.delta?.content;
        if (content) {
          completion += content;
          self.postMessage(JSON.stringify({ type: 'token', text: content }));
        }
      }

      self.postMessage(JSON.stringify({ type: 'done', text: completion }));
    } catch (err) {
      self.postMessage(JSON.stringify({ type: 'error', error: err.message }));
    }
  }
};
