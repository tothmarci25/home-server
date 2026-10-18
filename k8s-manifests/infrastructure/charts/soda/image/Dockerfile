# Selkies desktop + 32-bit Wine, for running SODA Off-Road Racing (1997).
#
# Thin layer on top of the official Selkies desktop image: adds i386 multiarch,
# Wine (32-bit), audio, and the Mesa/Intel VA userspace driver so the node's
# iGPU can be used (falls back to llvmpipe if not). Does NOT set ENTRYPOINT/CMD
# so Selkies' own supervisor keeps booting the desktop. Does NOT bake in the
# game — that lives on the per-pod PVC (and is non-redistributable).
#
# Target platform is linux/amd64 (the homeserver). Build with buildx:
#   docker buildx build --platform linux/amd64 ...
FROM ghcr.io/selkies-project/selkies/desktop:2.0.0-ubuntu26.04

USER root

# 32-bit Wine needs the i386 architecture enabled before installing.
RUN dpkg --add-architecture i386 \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        wine \
        wine32:i386 \
        winbind \
        cabextract \
        # audio (32-bit client libs so Wine can reach the desktop's PulseAudio) \
        libpulse0 \
        libpulse0:i386 \
        libasound2-plugins:i386 \
        # graphics userspace: Mesa DRI + Intel VA-API driver + probe tools \
        libgl1-mesa-dri \
        libgl1-mesa-dri:i386 \
        mesa-va-drivers \
        intel-media-va-driver \
        vainfo \
        mesa-utils \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# winetricks is handy for runtime tweaks during Step C; fetch the standalone script.
RUN curl -fsSL https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks \
        -o /usr/local/bin/winetricks \
    && chmod +x /usr/local/bin/winetricks

# Return to the image's default (non-root) user. The Selkies base runs the
# desktop as `ubuntu` (uid 1000); inherit its entrypoint untouched.
USER ubuntu
