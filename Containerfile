# SPDX-License-Identifier: Apache-2.0
ARG alpine_version=latest

FROM docker.io/alpine:$alpine_version AS final
RUN apk add --no-cache curl jq xxd perl parallel aws-cli bash coreutils tini openssl
COPY --chmod=755 ./src/aws-firehose-repeater.bash /usr/local/bin
ENTRYPOINT ["/sbin/tini", "--", "/bin/bash", "-c"]
CMD ["/usr/local/bin/aws-firehose-repeater.bash"]
