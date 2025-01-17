# AWS Firehose Repeater

Guess what!  
You _can't_ point AWS Firehose at your internal VPC!  
**That sucks!**

This uses the `Firehose -> S3` Path to allow you to pretend to be Firehose inside your private vpc.

# WARNING

* **We build weekly!**   
  We shoot our feet here: Every tag will track! 

* Not 1:1
* Some Jank™
* Not Volume Tested (Should be able to deal with at least 6MB/s per thread at 4 cores.)
* Limits from official spec NOT enforced (i.e. 10k records limit, 1Mi record limit etc.)
* Spaces in S3 keys not supported.
* Good Enough
* Compatible with: Mixed UTF-8 Records Newline Delimited, GZIP Double Null Terminated Stanzas (16B headers). Anything else WILL break it. 
* If your custom PUT contains a newline, this will split it into a fake separate record.

# Setup AWS Firehose

You need to set up AWS Firehose with:

* Pointing to a s3 bucket of your choice.
* Newline delimiter enabled
* File extension is set to `.json.gz`

# Env Variables

* `FIREHOSE_TARGET`  
  The API target URL  
  e.g. `https://example.com/api/v1/firehose`

* `FIREHOSE_KEY`  
  The "API Key" on your receiving end.  
  e.g. `somesecr3t`

* `FIREHOSE_COMMON_ATR`  
  The Common attributes header  
  e.g. `{"commonAttributes":{}}`

* `S3_BUCKET`  
  The s3 bucket name.  
  e.g. `some-bucket-name`

* `S3_PREFIX`  
  The prefix under which to pull from  
  e.g. `firehose/output/`

* `S3_DELETE`  
  Enable deletion of s3 object after processing. Unset or null to dry-run  
  e.g. `any-value`
  > keeping this off will result in duplicates!  
  > you should keep this on after you have tested your target.

* `NPROCS`  
  The amount of process to run in parallel 
  e.g. `0` for auto

* `FD_DEBUG`  
  Enable debug output  
  e.g. `/dev/stderr` or `/tmp/debug.logs`

* `CURL_EXTRA_OPTS`
  The final POST curl's extra options.  
  e.g. `--insecure`

* `AWS_REGION`
  You should set this.  
  e.g. `aq-central-1`

* `AWS_*`
  You should be able to set any of the normal `AWS_` env vars.

# How to

## locally configure

`task init`  
`edit config/config.env`

## install dev tools

`task install:tools`

## build

`task podman:build:local`

## generate

`task init`  
`task kustomize:local`

# FAQ

## Why do the s3 get with a curl request?

Well see, aws-cli runs on python, try to do `cat s3objects.big.list | xargs -P0 -I{} aws s3 cp {} -` and see what happens to your resources.

## Why do the weird `printf`, `cat` JSON generation instead of using `jq -s --stream`?

Could not figure out how to `--slurp + --stream` the output into an array without using all my memory, feel free to open a PR if you know how.  

## Why `--squash-all`?

I wish I could do `--layers=true --squash`, but there is an [issue](https://github.com/containers/podman/issues/20824) with that combo.  
> `--sqaush` combines all the built layers into one and then puts it on top of the base image (great for userside layer efficiency),  
> `--squash-all` does the same but also combines the base layer.

## Why bash? Why not fish?

Dammit I should have started with that `:(`

## Why not use **[PROGRAMING LANGUAGE]**?

It's my [Cursed Hammer](https://loststeak.com/if-programming-languages-were-weapons/#bash) and I get to hit every ~~thumb~~ _Nail_ I see!

## What's up with the Container annotations?

Not well-supported by podman, the annotations from Alpine fall through to the main layer. So I have to set them all. `:(`

## I have a s3 key with a space in, it's not working!

If you need this functionality, please open a PR.

## Why are you sending base64(gzip(json)) encoded payloads?

The output of Firehose to the s3 bucket IS NOT GUARANTEED TO BE JSON!  
It will output a mixture of data types, you will especially notice this when you ingest cloudwatch logs, as those are transported as gziped stanzas.

## Why aren't you casting the input then! Shouldn't you interpret the input and convert it to JSON before sending it?

Well the problem is compatibility, I need to replicate what AWS does as closely as possible, and they send the records like that.  
Endpoints like [loki.source.awsfirehose](https://grafana.com/docs/alloy/latest/reference/components/loki/loki.source.awsfirehose/), not only deal with it, but actually EXPECT it to work that way so they can categorize it correctly.

## WTF is the `s/(1f8b.{16}.*?0000)/\n\1\n/g` line doing !?

**That** is a regex for firehose GZIPed data.  
Real GZIP stanzas are supposed to be single null (00) terminated, but for some reason it's a double null (0000).  

### NOTE
This means this will break on gzip data that has additional headers with null runs, or "real" gzip data that is single terminated.

## That's not what I asked

__Fine__ that entire block came from the problem that I couldn't deal with the mixture of normal text and gziped data.  
Ideally, you'd have either JUST gziped stanzas or JUST normal text.  
The gziped data MAY contain `0a` (newlines) and therefor I can't cheat with the newline as the record delimiter.
> TODO: look at parallel "--recend" and "--recstart"

# Further Optimizations

## `xxd | perl | sed` block

A little crazy, could do with a refactor.  

## `parallel "xxd | base64"

This bit actually takes a bit.  
It it the biggest slowdown.
`xxd -r` is pretty brutal.
> Think about using bbe

## `jq`

At this point we might be able to get away with just using the `parallel` line directly and printing the json like I did with the stream block.

## speed

Currently, we are limited by the `parallel xxd -r`, if we had split the data before, this would be so much faster.  
```sh
s3 | branch() | gunzip | parallel "base64" | jq
```

