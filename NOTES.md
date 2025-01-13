# The streamed stdin args section

## xargs
Limited by arg size
```sh
xargs -P4 -i bash -c 'printf "%s" "{}" | xxd -ps -r | base64 -w0 && printf "\n"' | jq --stream -R -c '{"data": .}'
```

## awk
Limited by single thread
```sh
awk '{ print | "xxd -ps -r | base64 -w0" } { close("xxd -ps -r | base64 -w0") } { print "\n" }' ||
```
