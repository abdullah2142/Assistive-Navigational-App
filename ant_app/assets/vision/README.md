# Edge vision model

`ssd_mobilenet_v1.tflite` — SSD MobileNet v1, COCO, uint8-quantized, 4.1 MB.
Source: `download.tensorflow.org/models/tflite/task_library/object_detection/android/lite-model_ssd_mobilenet_v1_1_metadata_2.tflite`.
`labelmap.txt` is the 90-line label file extracted from that model's own
embedded metadata, so the two cannot drift apart.

## Signature

Verified by loading the model, not assumed:

| | Shape | Type |
| --- | --- | --- |
| input | `[1, 300, 300, 3]` | uint8 |
| output 0 — boxes | `[1, 10, 4]` | float32 |
| output 1 — classes | `[1, 10]` | float32 |
| output 2 — scores | `[1, 10]` | float32 |
| output 3 — count | `[1]` | float32 |

Boxes are `[ymin, xmin, ymax, xmax]`, normalized 0-1 — **not** `[x, y, w, h]`.
Getting that wrong produces boxes that still land on screen, just transposed,
which is the kind of bug that survives a casual look at a debug overlay.

Non-maximum suppression happens **inside** the model, in the
`TFLite_Detection_PostProcess` op. That is the main reason this model was
chosen over EfficientDet-Lite0, whose raw `[1, 19206, 90]` output would need
anchor decoding and NMS written by hand in Dart, on the critical path of a
safety alarm. It is also 4.1 MB against 13.8 MB, and integer rather than
float32, which matters on the Adreno-class budget hardware this app targets.

## What this model cannot do

COCO has 90 classes and **none of them is a rickshaw, a CNG auto-rickshaw, an
open manhole, a fire, or broken pavement.** In practice a cycle-rickshaw
detects as `bicycle` and a CNG as `car` or `truck`.

This is a limitation of the class list, not of the code, and it is not
closable by tuning. It is why Module 6 has two tiers: the edge tier decides
only *whether to stop the user walking* — where calling a CNG a car is
adequate, because the decision is about size and closeness — and the cloud
tier does all naming and all ground-hazard detection. The cloud tier needs a
network, so **rickshaw/CNG identification and manhole detection do not work
offline**, and `Dashboard.visionOfflineSaw` says so out loud rather than
letting silence read as "nothing there".

## Replacing it with a Dhaka-trained model

Training one needs a labelled Dhaka dataset and a GPU, which was out of scope
for this module. If one is ever produced, a replacement must:

1. Keep the input shape `[1, 300, 300, 3]` uint8, **or** change
   `VisionConfig.edgeInputSize` and the quantization handling in
   `EdgeHazardDetector._toInputTensor` together.
2. Emit the same four post-processed tensors in the same order. A model with
   raw outputs needs NMS added to `EdgeHazardDetector.detect`.
3. Ship a `labelmap.txt` with one label per line, indexed to match the class
   tensor.
4. Have its new classes added to `kHazardClassWeights` in
   `vision_detection.dart` with a relative-danger weight, and to
   `Dashboard.visionObjectLabel` with a Bangla and English spoken name.

`HazardAssessor.imminentThreshold` is tuned to *this* model's box statistics
and would have to be re-measured. Treat it the way
`WakeWordService.defaultDetectionThreshold` was treated before real
measurement existed: a starting point, not a finding.


---

# Depth model — `midas_v21_small.tflite`

MiDaS v2.1 small, from [isl-org/MiDaS v2_1](https://github.com/isl-org/MiDaS/releases/download/v2_1/model_opt.tflite).
**66 MB, float32.** MIT licensed.

| | Shape | Type |
| --- | --- | --- |
| input | `[1, 256, 256, 3]` | float32, 0-1 |
| output | `[1, 256, 256, 1]` | float32 |

Output is **inverse** depth: larger means nearer. It is relative and
unscaled, so there is no distance in metres anywhere in it — which is why
`DropoffVerdict.paces` is three coarse bands from image geometry rather than
a measurement.

## Why it is 66 MB

Because that is the only public build. Kaggle's and Qualcomm's quantised
copies are gated behind acceptance forms, and TFLite-to-TFLite float16
conversion is not a supported path — the converter takes a SavedModel or a
Keras model, not an existing `.tflite`. Shrinking it means rebuilding from
the ONNX or PyTorch source through a TF conversion, which is its own pipeline
with its own accuracy risk.

The trade was made deliberately: a descending step is the hazard that injures
a blind pedestrian rather than inconveniencing them, and it is invisible to
every other tier — COCO has no stairs class, and the cloud tier needs a signal
that underpasses and lift lobbies do not have.

## Calibrating it — this has not been done

`DepthProfile.defaultMinScore` is **6.0 and is a guess.** No threshold here
has met a real kerb. Synthetic images cannot settle it: a depth model shown a
*drawing* of stairs estimates the depth of a drawing, which was tried and
produced profiles indistinguishable from flat ground.

The calibration walk, which is what `[Depth]` log lines exist for:

1. Build with the ambient scanner on and a blind-profile account.
2. Walk a stretch of level pavement. Record the `score=` values.
3. Walk up to a known kerb and a known staircase, stopping a pace short.
   Record those `score=` values.
4. Put `defaultMinScore` between the two populations, nearer the level one —
   a missed drop is a fall and a false alarm is an annoyance, so err low.

This is exactly how `WakeWordService.defaultDetectionThreshold` was eventually
set, and that story is worth reading first: the measured gap there was between
0.016-0.144 for non-phrase speech and 0.300+ for real attempts, and the
default had been sitting at a guessed 0.5.

## Cost per scan

Unmeasured on target hardware. float32 256x256 on four CPU threads should be
in the low hundreds of milliseconds on a Redmi, and it runs on the *same*
frame as the object detector once every ambient interval — so the ambient duty
cycle estimate of ~3% is now optimistic and needs re-measuring too.
