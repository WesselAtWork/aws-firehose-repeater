# SPDX-License-Identifier: Apache-2.0
ARG alpine_version=latest

FROM docker.io/alpine:$alpine_version AS final
RUN apk add --no-cache curl gojq pigz gzip aws-cli bash coreutils tini openssl
RUN addgroup afhr -g 1000
RUN adduser  afhr -u 1000 -D -G afhr -g "AWS Firehose Repeater" -h /home/afhr -s /bin/bash
COPY --chmod=755 ./src/aws-firehose-repeater.bash /usr/local/bin
USER 1000:1000
WORKDIR /home/afhr
ENTRYPOINT ["/sbin/tini", "--", "/bin/bash", "-c"]
CMD ["/usr/local/bin/aws-firehose-repeater.bash"]
