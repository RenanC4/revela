# Revela

Revela is an iPhone app for scanning color and black-and-white film negatives at home. You photograph the negative with the iPhone camera, and the app turns it into a positive using photographic density instead of a naive color invert.

It is meant to be used with a copy stand (such as a Lomography DigitaLIZA Max) and a clip-on macro on the 1× main camera, so the frame can fill the 48 MP sensor. The built-in lenses alone are fine for testing the pipeline, but they cannot match a dedicated macro for resolution.

## What it does

- Captures from the 1× Fusion camera in ProRAW, with exposure, focus, and white balance locked
- Converts the RAW file to a linear image, without a photographic look baked in
- Measures Dmin from the film rebate only, not from the whole frame
- Inverts with \(D = -\log_{10}(T)\), then scales each RGB channel
- Avoids `CIColorInvert` and other shortcuts that crush contrast or leave an orange mask
- Stitches 6×6 / 120 frames as a 2×2 mosaic when a single shot cannot cover the negative, then inverts once after the stitch

## Why it exists

Lab development is cheap. A lab scan is not, and a phone-camera invert in Photos (or a simple filter) usually destroys the file: the rebate stays orange, shadows clip, and each frame gets a different color cast. Revela is the capture and inversion step you control yourself, with a repeatable profile for a whole roll.

## Project

The Xcode project name is `scan-analog`. The name on the Home Screen is set via the target’s Display Name.

## Status

Personal project, in active development.