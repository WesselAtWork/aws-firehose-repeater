# SPDX-License-Identifier: Apache-2.0
ARG alpine_version=latest

FROM docker.io/alpine:$alpine_version AS final
RUN apk add --no-cache curl gojq pigz gzip aws-cli bash coreutils tini openssl
ARG usr=afhr
RUN addgroup "${usr}" -g 1000
RUN adduser  "${usr}" -u 1000 -D -G "${usr}"  -g "AWS Firehose Repeater" -h "/home/${usr}" -s /bin/bash
COPY --chmod=755 ./src/aws-firehose-repeater.bash /usr/local/bin
USER 1000:1000
WORKDIR /home/${usr}
ENTRYPOINT ["/sbin/tini", "--", "/bin/bash", "-c"]
CMD ["/usr/local/bin/aws-firehose-repeater.bash"]
