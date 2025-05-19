# when the cw logs are too slow

```ruby
#!/usr/bin/ruby
require 'zlib'
require 'base64'
require 'stringio'

STDIN.each_line do |in_line|
  StringIO.open do |sio|
    sio.binmode
    Zlib::GzipWriter.wrap(sio,Zlib::BEST_SPEED,Zlib::DEFAULT_STRATEGY) do |gzw|
      gzw << in_line
    end
    STDOUT << Base64.encode64(sio.string)
  end
end

# idk why pipe is 2x slower then StringIO  :(
#STDIN.each_line do |in_line|
#  IO.pipe(binmode: true, autoclose: true) do |r, w|
#    Zlib::GzipWriter.wrap(w, Zlib::BEST_SPEED, Zlib::DEFAULT_STRATEGY) do |gzw|
#      gzw << in_line
#    end
#    STDOUT << Base64.encode64(r.read)
#  end
#end
```

# Mixed Data Handling

This was removed becuase it was too slow

## mixed data records2fh

```bash
# args: RID
# stream_in: firehose s3 records in the format '{...}\n\n{...}\ngzip(data)\n...'
# stream_out: firehose request json object '{...}'
records2fh() {
  # https://docs.aws.amazon.com/firehose/latest/dev/httpdeliveryrequestresponse.html#requestformat
  parallel --will-cite -k -j 2 -n 1 --pipe --recstart "$(printf '\x1f\x8b\x08')" --recend $'\n' zcat -f |
    tr -s '\n' '\n' | # remove all the extra newlines
    gojq -r 'if has("messageType") then "echo -n \( . | tostring | @sh) | gzip -1 | base64 -w0 && echo;" else "echo \( . | tostring | @base64 | @sh);" end' | bash |  # generate commands to process the different flavours of messages
    gojq -R -c 'select(. != "") | {"data": .}' |  # convert every line of base64 to a json object
    tr '\n' ',' | {
      printf '{"requestId":"%s","timestamp":%s,"records":[' "$1" "$(date -u +'%s%3N')";
      head -c-1;  # removes the last comma [jq should always output a final newline]
      printf ']}';
    } | tee -p -a /dev/fd/3
}
export -f records2fh
```

### xargs
Limited by arg size
```sh
xargs -P4 -i bash -c 'printf "%s" "{}" | xxd -ps -r | base64 -w0 && echo' | jq --stream -R -c '{"data": .}'
```

### awk
Limited by single thread
```sh
awk '{ print | "xxd -ps -r | base64 -w0" } { close("xxd -ps -r | base64 -w0") } { print "\n" }' ||
```

## FAQ related to this

### WTF is the `s/(1f8b.{16}.*?0000)/\n\1\n/g` line doing !?

**That** is a regex for firehose GZIPed data.  
Real GZIP stanzas are supposed to be single null (00) terminated, but for some reason it's a double null (0000).  

> This means this will break on gzip data that has additional headers with null runs, or "real" gzip data that is single terminated.

### That's not what I asked

__Fine__ that entire block came from the problem that I couldn't deal with the mixture of normal text and gziped data.  
Ideally, you'd have either JUST gziped stanzas or JUST normal text.  
The gziped data MAY contain `0a` (newlines) and therefor I can't cheat with the newline as the record delimiter.

### Why not `zcat -f` ?

That only decodes until it hits non-gzip data, it then "fails-open" and then acts as cat for the rest of the stream.
