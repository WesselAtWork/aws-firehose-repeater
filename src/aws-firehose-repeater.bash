#!/bin/bash
# shellcheck disable=SC2317
# SPDX-License-Identifier: Apache-2.0

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

## AWS_

echo ${AWS_PROFILE:+"Using AWS Profile: ${AWS_PROFILE}"} >&3

if [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
  eval "$(aws configure export-credentials --format env)"
fi
: "${AWS_ACCESS_KEY_ID:?"AWS Error! Could not determine key creds!"}"
: "${AWS_SECRET_ACCESS_KEY:?"AWS Error! Could not determine secret creds!"}"

export AWS_REGION=${AWS_REGION:-"$(aws configure get region)"} # aws is a pain, please just give me the region T_T.  `aws configure get region` only works with .aws/config.
: "${AWS_REGION:?"Could not determine the AWS_REGION! Please provide it."}"

export AWS_ACCOUNT=${AWS_ACCOUNT:-"$(aws sts get-caller-identity --query Account --output text)"}
: "${AWS_ACCOUNT:?"AWS Error! Could not determine account id!"}"

## S3_

: "${S3_BUCKET:?"Please Set S3_BUCKET! e.g. some-bucket-name"}"

export S3_PREFIX=${S3_PREFIX:="firehose/output/"}
export S3_CW_PREFIX=${S3_CW_PREFIX:="cw/"}
export S3_GENERIC_PREFIX=${S3_GENERIC_PREFIX:="generic/"}

if [ -z "${S3_DELETE:-}" ]; then
  echo "DRY RUNNING S3 DELETE" >&2
fi

## FIREHOSE_

: "${FIREHOSE_TARGET:?"Please Set FIREHOSE_TARGET! e.g. http://my-internal-host/awsfirehose/api/v1/push"}"

export FIREHOSE_KEY=${FIREHOSE_KEY:=""}
export FIREHOSE_COMMON_ATR=${FIREHOSE_COMMON_ATR:="{\"commonAttributes\":{}}"}


# Functions

# args: RID FIREHOSENAME
# stream_out: none
fakeFireHosePost() {
  echo "Sending: $1" >&2
  local e_opts
  e_opts=( "${CURL_EXTRA_OPTS:-}" )
  # https://docs.aws.amazon.com/firehose/latest/dev/httpdeliveryrequestresponse.html
  curl  --json @- -X POST "$FIREHOSE_TARGET" \
    "${e_opts[@]}" \
    --connect-timeout "${CURL_TIMEOUT:-5}" --retry-max-time "${CURL_RETRY_MAX_TIME:-65}" --retry "${CURL_RETRY:-6}" \
    -H 'Content-Type: application/json' \
    -H "X-Amz-Firehose-Protocol-Version: ${FIREHOSE_PROTOCOL_VERSION:-1.0}" \
    -H "X-Amz-Firehose-Request-Id: ${1}" \
    -H "X-Amz-Firehose-Source-Arn: arn:aws:firehose:${AWS_REGION}:${AWS_ACCOUNT}:deliverystream/${2}" \
    -H "X-Amz-Firehose-Access-Key: ${FIREHOSE_KEY}" \
    -H "X-Amz-Firehose-Common-Attributes: ${FIREHOSE_COMMON_ATR}" \
    -sS --fail-with-body 2>&1 | { printf '%s' 'Response: '; cat; printf '\n'; } | paste >&2

  # using paste here as a substitute for sponge :^)
  # the printf happens instantly, which messes with the cmd output
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
    -sS --fail-with-body
}
export -f s3micro

# args: objKey
# stream_out: object data
getObject() {
  echo "Getting: $1" >&2
  s3micro "GET" "$S3_BUCKET" "$1"
}
export -f getObject

# args: objKey
deleteObject() {
  if [ -n "${S3_DELETE:-}" ]; then
    s3micro "DELETE" "$S3_BUCKET" "$1" || {
      echo "S3 Delete Failed!" >&2
      exit 1
    }
    echo "Deleted: $1" >&2
  else
    echo "[DRY RUN]" "Deleted: $1" >&2
  fi
}
export -f deleteObject

# args: RID
# stream_in: firehose request records in the format '{data: base64({...})}\n{data: base64({...})}\n...'
# stream_out: firehose request json object '{...}'
data2fh() {
  # keeping things DRY
  tr '\n' ',' | {
    printf '{"requestId":"%s","timestamp":%s,"records":[' "$1" "$(date -u +'%s%3N')";
    head -c-1;  # removes the last comma [jq should always output a final newline]
    printf ']}';
  } | tee -p -a /dev/fd/3
}
export -f data2fh

# args: RID
# stream_in: firehose s3 records in the format '{...}\n\n{...}\n...'
# stream_out: firehose request json object '{...}'
genericRecords2fh() {
  tr -s '\n' '\n' |
    gojq -R -c  'select(. != "") | {"data": . | @base64}' |  # convert every line to the data: json object
    data2fh "${1}"
}
export -f genericRecords2fh

# args: RID
# stream_in: firehose CW s3 records in the format '{...}\n\n{...}\n...'
# stream_out: firehose request json object '{...}'
cwRecords2fh() {
  # cloudwatch is different, the receiver expects a different format. :(
  # note: the first `-R` is technically unnecessary because even though it gives a 2x speed up, the thing slowing down is the command interpreter. :(
  tr -s '\n' '\n' |
    gojq -R -r '"echo -n \( . | tostring | @sh) | gzip -1 | base64 -w0 && echo;"' | ash |  # generate commands; don't use pigz as it's startup invocation is slower then gzip
    gojq -R -c  'select(. != "") | {"data": .}' |  # convert every line of base64 to the data: json object
    data2fh "${1}"
}
export -f cwRecords2fh

# args: objKey
process() {
  local objkey filename
  objkey=$(tr -d '[:space:]' <<< "${1:-}"); # trimming is hard :(
  if [ -z "${objkey}" ]; then
    echo "input is empty" >&2
    return 1
  fi

  if [ "${objkey}" == "None" ]; then
    echo "s3 list is empty" >&2
    return 0
  fi

  local type
  type="unkown"

  case "${objkey}" in
    "${S3_PREFIX}${S3_CW_PREFIX}"* )
      echo "[DEBUG] ${objkey} -> CW" >&3;
      type="CW";
        ;;
    "${S3_PREFIX}${S3_GENERIC_PREFIX}"* )
      echo "[DEBUG] ${objkey} -> GENERIC" >&3;
      type="GENERIC";
        ;;
    *)
      echo "Could not determine if obj: ${objkey} belongs in CW: ${S3_PREFIX}${S3_CW_PREFIX} or GENERIC: ${S3_PREFIX}${S3_GENERIC_PREFIX}" >&2
      return 2
        ;;
  esac

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
  echo "Processing: $s3URL" >&2

  # need to write out every block because the pipelines like it that way
  case "${type}" in
    "GENERIC")
      {
        { getObject "$objkey" | pigz -d |
          genericRecords2fh "$rid" |
          fakeFireHosePost "$rid" "$fireHoseName"
        } && deleteObject "$objkey"
      } || return 1;
        ;;
    "CW")
      {
        { getObject "$objkey" | pigz -d |
          cwRecords2fh "$rid" |
          fakeFireHosePost "$rid" "$fireHoseName"
        } && deleteObject "$objkey"
      } || return 1;
        ;;
    *)
      echo "${s3URL} was type: ${type} ?!" >&2
      return 3
        ;;
  esac

  echo "$s3URL" >&1
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
