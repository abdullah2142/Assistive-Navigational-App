# Wake-word models (placeholder)

Downloaded from [openWakeWord](https://github.com/dscripka/openWakeWord) release
`v0.5.1`:

- `melspectrogram.tflite`, `embedding_model.tflite` — the shared feature
  extractor. Reusable regardless of which wake phrase is detected; keep these
  even after a custom "Hey ANT" model exists.
- `hey_jarvis_v0.1.tflite` — a **placeholder** wake-word classifier. This app
  wants "Hey ANT", not "Hey Jarvis" — no custom model exists yet because
  training one needs real ML infrastructure (PyTorch, thousands of synthetic
  Piper-TTS clips, realistically a GPU) that isn't available in the sandbox
  this was built in. Swapping it for a real "Hey ANT" model later is a
  one-file change in `WakeWordService` — no other code needs to change.

## License — read before shipping to real users

The openWakeWord **code**/training pipeline is Apache 2.0. These **pretrained
weight files** are **CC-BY-NC-SA-4.0 — non-commercial only**
(https://huggingface.co/davidscripka/openwakeword). Fine for development/a
demo/portfolio build; swap `hey_jarvis_v0.1.tflite` for a self-trained "Hey
ANT" model (trained on your own synthetic data via openWakeWord's own
Apache-2.0 pipeline) before any commercial release — a model you train
yourself doesn't inherit this restriction.

## Training the real "Hey ANT" model later

1. Open openWakeWord's `notebooks/automatic_model_training.ipynb` in Google
   Colab (free GPU tier is enough — the repo's own docs cite under an hour).
2. Set the target phrase to "Hey ANT" (or a Bangla phrase, once Piper voice
   quality for Bangla is confirmed — see task.md).
3. Download the resulting `.tflite` file and replace `hey_jarvis_v0.1.tflite`
   in this folder (and the filename in `WakeWordService`/`pubspec.yaml`).
