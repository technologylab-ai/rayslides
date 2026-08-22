#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define NANOSVG_IMPLEMENTATION
#include "vendor/nanosvg.h"
#define NANOSVGRAST_IMPLEMENTATION
#include "vendor/nanosvgrast.h"

#include "svg_rasterizer.h"

static int clamped_dimension(float value) {
    if (!isfinite(value) || value <= 0.0f) return 0;
    if (value > 4096.0f) return 4096;
    return (int)ceilf(value);
}

int rayslides_svg_rasterize_file(
    const char *path,
    int requested_width,
    int requested_height,
    RayslidesSvgImage *out
) {
    if (path == NULL || out == NULL) return -1;
    memset(out, 0, sizeof(*out));

    NSVGimage *svg = nsvgParseFromFile(path, "px", 96.0f);
    if (svg == NULL || !isfinite(svg->width) || !isfinite(svg->height) ||
        svg->width <= 0.0f || svg->height <= 0.0f) {
        if (svg != NULL) nsvgDelete(svg);
        return -2;
    }

    out->natural_width = clamped_dimension(svg->width);
    out->natural_height = clamped_dimension(svg->height);
    if (out->natural_width == 0 || out->natural_height == 0) {
        nsvgDelete(svg);
        return -3;
    }

    float requested_scale = 1.0f;
    if (requested_width > 0)
        requested_scale = fmaxf(requested_scale, (float)requested_width / svg->width);
    if (requested_height > 0)
        requested_scale = fmaxf(requested_scale, (float)requested_height / svg->height);
    float scale = requested_scale * 2.0f;
    const float longest = fmaxf(svg->width, svg->height);
    if (longest * scale > 4096.0f) scale = 4096.0f / longest;
    if (scale <= 0.0f || !isfinite(scale)) {
        nsvgDelete(svg);
        return -4;
    }

    out->width = clamped_dimension(svg->width * scale);
    out->height = clamped_dimension(svg->height * scale);
    if (out->width == 0 || out->height == 0) {
        nsvgDelete(svg);
        return -5;
    }

    const size_t stride = (size_t)out->width * 4u;
    if (stride / 4u != (size_t)out->width ||
        (size_t)out->height > SIZE_MAX / stride) {
        nsvgDelete(svg);
        return -6;
    }
    out->pixels = (unsigned char *)calloc((size_t)out->height, stride);
    if (out->pixels == NULL) {
        nsvgDelete(svg);
        return -7;
    }

    NSVGrasterizer *rasterizer = nsvgCreateRasterizer();
    if (rasterizer == NULL) {
        rayslides_svg_image_free(out);
        nsvgDelete(svg);
        return -8;
    }
    nsvgRasterize(rasterizer, svg, 0.0f, 0.0f, scale, out->pixels, out->width, out->height, (int)stride);
    nsvgDeleteRasterizer(rasterizer);
    nsvgDelete(svg);
    return 0;
}

void rayslides_svg_image_free(RayslidesSvgImage *image) {
    if (image == NULL) return;
    free(image->pixels);
    memset(image, 0, sizeof(*image));
}
