# syntax=docker/dockerfile:1
#
# Shared Lambda container image for metadata_handler.py and
# thumbnail_handler.py. One image, two Lambda functions — see
# terraform/modules/lambda/main.tf, where each aws_lambda_function sets
# package_type = "Image" against this same image_uri and picks its handler
# via image_config.command, so this (large, ffmpeg-laden) image only needs
# to be built and pushed once.
#
# Why a container image instead of zip + Lambda Layer: ffmpeg/ffprobe
# static binaries run ~140MB each. A zip-packaged function's total unzipped
# size — function code + every attached layer — is capped at 250MB by AWS;
# two ffmpeg-family binaries alone blow past that before any Python code is
# counted. Lambda container images are capped at 10GB uncompressed instead,
# which is why this project deploys these two functions as images rather
# than the zip-based functions used for validate/database (which have no
# native binary dependencies and comfortably fit the zip path — see
# terraform/modules/lambda/main.tf for both patterns side by side).
#
# Why download ffmpeg here instead of `dnf install ffmpeg`: Amazon Linux
# 2023's default repos (which this base image uses) don't ship ffmpeg —
# multimedia codec packages are excluded from AWS's own repos for licensing
# reasons, same as most enterprise Linux distros. BtbN/FFmpeg-Builds
# publishes prebuilt static-ish Linux binaries as GitHub Releases
# specifically for cases like this; "latest" is a stable, always-current
# alias URL. Pin FFMPEG_BUILD_URL to a dated release tag instead if you
# want fully reproducible image builds (see BtbN's releases page).

FROM public.ecr.aws/lambda/python:3.12

ARG FFMPEG_BUILD_URL=https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linux64-gpl.tar.xz

RUN dnf install -y tar xz && \
    curl -L -o /tmp/ffmpeg.tar.xz "${FFMPEG_BUILD_URL}" && \
    mkdir -p /tmp/ffextract && \
    tar -xJf /tmp/ffmpeg.tar.xz -C /tmp/ffextract --strip-components=2 --wildcards '*/bin/ffmpeg' '*/bin/ffprobe' && \
    mv /tmp/ffextract/ffmpeg /usr/local/bin/ffmpeg && \
    mv /tmp/ffextract/ffprobe /usr/local/bin/ffprobe && \
    chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe && \
    rm -rf /tmp/ffmpeg.tar.xz /tmp/ffextract && \
    dnf remove -y tar xz && \
    dnf clean all

ENV FFMPEG_PATH=/usr/local/bin/ffmpeg \
    FFPROBE_PATH=/usr/local/bin/ffprobe

COPY metadata_handler.py thumbnail_handler.py ${LAMBDA_TASK_ROOT}/

# Default CMD makes `docker run` do something sane locally without extra
# flags; both real Lambda functions override this via Terraform's
# image_config.command (see terraform/modules/lambda/main.tf).
CMD ["metadata_handler.lambda_handler"]
