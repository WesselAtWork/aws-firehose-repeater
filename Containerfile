# SPDX-License-Identifier: AGPL-3.0-or-later
ARG alpine_version=latest

FROM docker.io/alpine:$alpine_version AS final
RUN apk add --no-cache curl jq aws-cli bash coreutils tini openssl
COPY --chmod=755 ./aws-firehose-repeater.bash /usr/local/bin
ENTRYPOINT ["/sbin/tini", "--", "/bin/bash", "-c"]
CMD ["/usr/local/bin/aws-firehose-repeater.bash"]
