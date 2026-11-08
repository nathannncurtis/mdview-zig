# Image decoder fixtures

Every file here is a small synthetic image (gradients, circles, rectangles, random palettes). None of it is third-party content, and it is released under the same licence as the repository.

- PNG, APNG, GIF and BMP files were written with throwaway encoders that build each colour type, bit depth, interlace mode, disposal method, RLE mode and bit mask by hand, so the expected pixels are known without any decoder.
- JPEG and WebP files were encoded with Pillow 12 (libjpeg-turbo and libwebp). Their expected pixels come from Pillow's decoders, and the Zig decoders match them byte for byte.

`manifest.txt` has one line per fixture: file name, width, height, frame count, total plays (0 loops forever), CRC-32 of all frames' RGBA bytes in order, and the comma-separated frame delays in milliseconds. `src/image/image_test.zig` decodes every file and compares all of it.
