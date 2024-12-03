#!/bin/bash
# shellcheck disable=SC2317
# SPDX-License-Identifier: AGPL-3.0-or-later

set -e
set -u
set -o pipefail

# Redirections

: "${FD_OUT:="/dev/stdout"}"
: "${FD_ERR:="/dev/stderr"}"
: "${FD_DEBUG:="/dev/null"}"

exec 1> "$FD_OUT"
exec 2> "$FD_ERR"
exec 3> "$FD_DEBUG"

# Loads AWS Creds into env

echo ${AWS_PROFILE:+"Using AWS Profile ${AWS_PROFILE}"} >&3

eval "$(aws configure export-credentials --format env)"
export AWS_REGION=${AWS_REGION:-"$(aws configure get region)"}
export AWS_ACCOUNT=${AWS_ACCOUNT:-"$(aws sts get-caller-identity --query Account --output text)"}

# Main Variables

: "${S3_BUCKET:?"Please Set S3_BUCKET! e.g. some-bucket-name"}"
: "${S3_PREFIX:="/"}"

: "${FIREHOSE_TARGET:?"Please Set FIREHOSE_TARGET! e.g. http://my-ineternal-host/awsfirehose/api/v1/push"}"

: "${FIREHOSE_KEY:=""}"
: "${FIREHOSE_COMMON_ATR:="{\"commonAttributes\":{}}"}"

# Functions

# args: RID FIREHOSENAME
# stream_out: none
fakeFireHosePost() {
  echo "Sending: $1" > /dev/stderr
  # https://docs.aws.amazon.com/firehose/latest/dev/httpdeliveryrequestresponse.html
  curl --json @- -X POST "$FIREHOSE_TARGET" \
    --connect-timeout "${CURL_TIMEOUT:-5}" --retry-max-time "${CURL_RETRY_MAX_TIME:-65}" --retry "${CURL_RETRY:-6}" \
    -H 'Content-Type: application/json' \
    -H "X-Amz-Firehose-Protocol-Version: ${FIREHOSE_PROTOCOL_VERSION:-1.0}" \
    -H "X-Amz-Firehose-Request-Id: ${1}" \
    -H "X-Amz-Firehose-Source-Arn: arn:aws:firehose:${AWS_REGION}:${AWS_ACCOUNT}:deliverystream/${2}" \
    -H "X-Amz-Firehose-Access-Key: ${FIREHOSE_KEY}" \
    -H "X-Amz-Firehose-Common-Attributes: ${FIREHOSE_COMMON_ATR}" \
    --silent --fail-with-body | { printf '%s' 'Response: '; cat; printf '\n'; } | paste &> /dev/stderr

  # using paste here as a substitute for sponge :^)
}
export -f fakeFireHosePost

# args: METHOD BUCKET OBJKEY
s3micro() {
  # see https://github.com/paulhammond/s3simple/blob/main/s3simple
  local method="$1"
  local bucket="$2"
  local objKey="$3"

  local path="${bucket}/${objKey}"

  local args md5
  md5=""
  args=(-o "-")

  local aws_headers=""
  if [ -n "${AWS_SESSION_TOKEN-}" ]; then
    args=("${args[@]}" -H "x-amz-security-token: ${AWS_SESSION_TOKEN}")
    aws_headers="x-amz-security-token:${AWS_SESSION_TOKEN}\n"
  fi

  local date
  date="$(date -u '+%a, %e %b %Y %H:%M:%S +0000')"

  local string_to_sign
  printf -v string_to_sign "%s\n%s\n\n%s\n%b%s" "$method" "$md5" "$date" "$aws_headers" "/$path"

  local signature
  signature=$(echo -n "$string_to_sign" | openssl sha1 -binary -hmac "${AWS_SECRET_ACCESS_KEY}" | openssl base64)

  local authorization="AWS ${AWS_ACCESS_KEY_ID}:${signature}"

  curl "${args[@]}" \
    -H "Date: ${date}" \
    -H "Authorization: ${authorization}" \
    -X "$method" \
    "https://${bucket}.s3.amazonaws.com/${objKey}" \
    --silent --fail-with-body
}
export -f s3micro

# args: objKey
# stream_out: object data
getObject() {
  echo "Getting: $1" > /dev/stderr
  s3micro "GET" "$S3_BUCKET" "$1"
}
export -f getObject

# args: objKey
deleteObject() {
  if [ -n "${S3_DELETE:-}" ]; then
    s3micro "DELETE" "$S3_BUCKET" "$1"
    echo "Deleted: $1" > /dev/stderr
  else
    echo "[DRY RUN]" "Deleted: $1" > /dev/stderr
  fi
}
export -f deleteObject

# args: RID
# stream_in: json records in the format '{...}\n{...}\n{...}\n...\n'
# stream_out: firehose request json object '{...}'
records2fh() {
  # https://docs.aws.amazon.com/firehose/latest/dev/httpdeliveryrequestresponse.html#requestformat
  # Could not figure out how to jq slurp+stream in a memory effcient manner, so printf + head/cat/tail it is.
  jq -c '{"data": .|@base64}' \
    | tr '\n' ',' \
    | {
        printf '{"requestId":"%s","timestamp":%s,"records":[' "$1" "$(date -u +'%s%3N')";
        head -c-1;
        printf ']}';
      } | tee -p -a /dev/fd/3
}
export -f records2fh

# args: objKey
process() {
  local objkey filename
  objkey=$(tr -d '[:space:]' <<< "$1");
  filename=$(basename -s '.json.gz' "$objkey");

  # this is the most jank part of the entire thing
  local sansRID sansDate sansV
  sansRID=${filename%-*-*-*-*-*};
  sansDate=${sansRID%-*-*-*-*-*-*};
  sansV=${sansDate%-*};

  local fireHoseName rid
  fireHoseName="$sansV";
  rid="${filename#"${sansRID}"-}"

  echo "[DEBUG] vars: $filename := $sansRID ; $sansDate ; $sansV | $rid" >&3

  local s3URL
  s3URL="s3://$S3_BUCKET/$objkey"
  echo "Processing: $s3URL" > /dev/stderr

  {
    { getObject "$objkey" | gunzip \
      | records2fh "$rid" \
      | fakeFireHosePost "$rid" "$fireHoseName"
    } && deleteObject "$objkey"
  } || return 1

  echo "$s3URL" > /dev/stdout
  return 0
}
export -f process

# Debug Env

env >&3
export -p >&3

# Main Process

aws s3api list-objects-v2 --bucket "$S3_BUCKET" --prefix "$S3_PREFIX" --query 'Contents[].Key' --output text \
  | tr '\t' '\0' \
  | tr '\n' '\0' \
  | xargs -0 -P"${NPROCS:-4}" -n1 bash -e -u -o pipefail -c 'process "$@"' _

exit 0
