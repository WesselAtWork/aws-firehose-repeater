#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

export AWS_ACCESS_KEY_ID="TEST"
export AWS_SECRET_ACCESS_KEY="TEST"
export AWS_SESSION_TOKEN="TEST"
export AWS_REGION="TEST"
export AWS_ACCOUNT="TEST"

export S3_BUCKET="TEST-BUCKET"
export S3_PREFIX="test/prefix/"
export FIREHOSE_TARGET="http://localhost/awsfirehose/api/v1/push"

curl() {
  #echo "fake cURL" >&2
  #echo "args:" "${@}" >&2
  case "${*}" in
    "--json"* )
      printf '↫ '; cat;
        ;;
    *"GET"* )
      gzip -1 < default.json;
        ;;
    *"DELETE"* )
      echo "fake delete" >&2;
        ;;
  esac
}
export -f curl

aws() {
  #echo "fake aws">&2
  #echo "args:" "${@}" >&2
  case "${1}" in
    "configure")
      echo "fake aws configure">&2
        ;;
    "s3api")
      cat s3.list
        ;;
  esac
}
export -f aws

../src/aws-firehose-repeater.bash
