# Image decoder fixtures

Every file here is a small synthetic image (gradients, circles, rectangles, random palettes). None of it is third-party content, and it is released under the same licence as the repository.

- PNG, APNG, GIF and BMP files were written with throwaway encoders that build each colour type, bit depth, interlace mode, disposal method, RLE mode and bit mask by hand, so the expected pixels are known without any decoder.
- JPEG and WebP files were encoded with Pillow 12 (libjpeg-turbo and libwebp). Their expected pixels come from Pillow's decoders.
- `jpeg_440*`, `jpeg_411` and `jpeg_arith_*` were encoded with libjpeg-turbo 3.0.4 `cjpeg` (`-sample 1x2`, `-sample 4x1`, `-arithmetic`, `-progressive`, `-restart`), and their expected pixels come from its `djpeg`.
- `webp_simple_filter*` and `webp_normal_filter_sharp` were encoded with libwebp 1.5.0 `cwebp` (`-nostrong` selects the simple loop filter), and their expected pixels come from its `dwebp`.
- `*_truncated.*` are real files cut short. Their expected pixels are what headless Chromium draws for the same bytes (canvas read-back): decoded rows kept, the rest transparent, interlaced GIFs with Chromium's row replication.
- `png_icc_*`, `png_gama*`, `png_chrm*`, `png_srgb_chunk_wins`, `png_gray_icc`, `jpeg_icc_*`, `jpeg_gray_icc`, `webp_icc_*` and `bmp_v5_icc_p3` carry synthetic matrix/TRC ICC profiles or PNG colour chunks. Their checksums are of this decoder's output, which was checked against Chromium's canvas read-back to within 1 per channel.
- `bmp_embedded_*` hold a JPEG or PNG payload (BI_JPEG, BI_PNG); the expected pixels are the embedded image decoded by Pillow.

`manifest.txt` has one line per fixture: file name, width, height, frame count, total plays (0 loops forever), CRC-32 of all frames' RGBA bytes in order, and the comma-separated frame delays in milliseconds. `src/image/image_test.zig` decodes every file and compares all of it.
