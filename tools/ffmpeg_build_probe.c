#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>

#include <stdio.h>
#include <string.h>

int main(int argc, char** argv) {
    static const char* forbidden_configuration[] = {
        "--enable-gpl",
        "--enable-version3",
        "--enable-libx264",
        "--enable-libx265",
        "--enable-nonfree",
    };
    const char* version = av_version_info();
    const char* license = avutil_license();
    const char* configuration = avutil_configuration();
    static const struct {
        const char* name;
        int encoder;
        int decoder;
    } required_codecs[] = {
        { "h264_videotoolbox", 1, 0 },
        { "h264", 0, 1 },
        { "aac", 1, 1 },
        { "pcm_s16le", 1, 1 },
        { "pcm_u8", 1, 1 },
    };

    if (argc != 3) {
        fprintf(stderr, "usage: %s <expected-version> <expected-license>\n", argv[0]);
        return 2;
    }
    if (strcmp(version, argv[1]) != 0) {
        fprintf(stderr, "unexpected FFmpeg version: %s\n", version);
        return 1;
    }
    if (strcmp(license, argv[2]) != 0) {
        fprintf(stderr, "unexpected FFmpeg license: %s\n", license);
        return 1;
    }
    for (size_t index = 0;
         index < sizeof(forbidden_configuration) / sizeof(forbidden_configuration[0]);
         ++index) {
        if (strstr(configuration, forbidden_configuration[index]) != NULL) {
            fprintf(stderr, "forbidden FFmpeg option: %s\n", forbidden_configuration[index]);
            return 1;
        }
    }
    for (size_t index = 0;
         index < sizeof(required_codecs) / sizeof(required_codecs[0]);
         ++index) {
        const char* name = required_codecs[index].name;
        if (required_codecs[index].encoder
            && avcodec_find_encoder_by_name(name) == NULL) {
            fprintf(stderr, "required FFmpeg encoder is missing: %s\n", name);
            return 1;
        }
        if (required_codecs[index].decoder
            && avcodec_find_decoder_by_name(name) == NULL) {
            fprintf(stderr, "required FFmpeg decoder is missing: %s\n", name);
            return 1;
        }
    }
    if (swscale_version() == 0 || swresample_version() == 0) {
        fprintf(stderr, "required FFmpeg scaling or resampling library is unavailable\n");
        return 1;
    }

    printf("version=%s\n", version);
    printf("license=%s\n", license);
    printf("codecs=h264_videotoolbox,h264,aac,pcm_s16le,pcm_u8\n");
    printf("libraries=libavcodec,libavutil,libswresample,libswscale\n");
    printf("configuration=%s\n", configuration);
    return 0;
}
