#ifndef RAYSLIDES_SVG_RASTERIZER_H
#define RAYSLIDES_SVG_RASTERIZER_H

typedef struct RayslidesSvgImage {
    unsigned char *pixels;
    int width;
    int height;
    int natural_width;
    int natural_height;
} RayslidesSvgImage;

// Rasterizes at up to 2x the requested logical box size while preserving the
// SVG aspect ratio. Returns 0 on success; the caller owns `pixels`.
int rayslides_svg_rasterize_file(
    const char *path,
    int requested_width,
    int requested_height,
    RayslidesSvgImage *out
);

void rayslides_svg_image_free(RayslidesSvgImage *image);

#endif
