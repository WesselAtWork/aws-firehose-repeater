# AWS Firehose Repeater

Guess what!  
You _can't_ point AWS Firehose at your internal VPC!  
**That sucks!**

This uses the `Firehose -> S3` Path to allow you to pretend to be firehose inside of your private vpc.

# WARNING

* **We build weekly!**   
  We shoot our feet here: Every tag will track! 

* Not 1:1
* Some Jank™
* Not Volume Tested
* Limits from official spec NOT enforced (i.e. 10k records limit, 1Mi record limit etc. )
* Good Enough

# Setup AWS Firehose

You need to setup AWS firehose with:

* Pointing to a s3 bucket of your choice.
* Newline delimiter enabled
* File extention is set to `.json.gz`

# Env Variables

* `FIREHOSE_TARGET`  
  The api target URL e.g. `https://example.com/api/v1/firehose`
* `FIREHOSE_KEY`  
  The "Api Key" on your recieving end. e.g. `somesecr3t`
* `FIREHOSE_COMMON_ATR`  
  The Common attributes header e.g. `'{"commonAttributes":{}}'`
* `S3_BUCKET`  
  The s3 vucket name. e.g. `some-bucket-name`
* `S3_PREFIX`  
  The prefix under which to pull from e.g. `firehose/output/`
* `S3_DELETE`  
  Enable deletion of s3 object after processing. Unset or null to dry-run  e.g. `any-value`
  > (keeping this off will result in duplicates; you should keep this on after you have tested your target.)
* `NPROCS`  
  The amount of process to run in parralel for upload e.g. `0` for auto
* `FD_DEBUG`  
  Enable debug output e.g. `/dev/stderr` or `/tmp/debug.logs`
* `CURL_EXTRA_OPTS`
  The final POST curl's extra options. e.g. `--insecure`
* `AWS_REGION`
  You should probably set this one e.g. `aq-central-1`
* `AWS_`
  You should be able to set all the normal `AWS_` var

# How to

## install dev tools

`task install:tools`

## build

`task podman:build:local`

# FAQ

## Why do the s3 get with a curl request?

Well see, aws-cli runs on python, try to do `cat s3objects.big.list | xargs -P0 -I{} aws s3 cp {} -` and see what happens to your resources.

## Why do the weird `printf`, `cat` json generation instead of using `jq`?

Could not figure out how to `--slurp + --stream` the output into an array without using all my memory, feel free to open a PR if you do.  

## Why `--squash-all`?

I whish I could do `--layers=true --squash` but there is an [issue](https://github.com/containers/podman/issues/20824) with that combo.

## Why bash? Why not fish?

Damnit I should have started with that `:(`

## Why not use **[PROGRAMING LANGUAGE]**?

It's my [Cursed Hammer](https://loststeak.com/if-programming-languages-were-weapons/#bash) and I _must_ hit every ~~thumb~~ _Nail_ I see!

## What's up with the Container annotations?

Not very well suppoorted by podman, the annotations from Alpine fall through to the main layer. So I have to set them all.

## I have an s3 key with a space in, it's not working!

Please open a PR!
