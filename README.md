# rest-stream-test

Test plugin for the sm-rest streaming HTTP download API. Not intended for production use.

## How it works

`sm_streamtest [url]` creates a GET request with `OnHeaders`, `OnProgress` and `OnData` callbacks. Each data callback appends its chunk to `addons/sourcemod/data/rest-stream-test.bin`. `sm_streamtest_file [url]` downloads the same URL through `SetOutputFile`, where the extension writes the file itself, for comparison. Progress is printed once per second to the server console and to the console of the client that ran the command. On completion it reports the HTTP status, bytes received, chunk count, largest chunk, on-disk file size, whether it matches `Content-Length`, and throughput.

## Chunk size and heap

`sm_streamtest_chunk_size` sets the extension's receive buffer (`RESTRequest.ChunkSize`), which bounds each chunk. Every chunk is copied onto the plugin heap before the callback runs, so the plugin is compiled with `#pragma dynamic 786432` (3 MiB of heap) and caps the chunk size at 2 MiB. With SteamWorks the chunks were fixed and small (18805 chunks for 1 GiB), so the per-callback pack-and-write loop dominated. Here the chunk size can be varied to measure whether larger chunks raise throughput:

```
sm_streamtest_chunk_size 16384
sm_streamtest "https://ash-speed.hetzner.com/1GB.bin"
sm_streamtest_chunk_size 1048576
sm_streamtest "https://ash-speed.hetzner.com/1GB.bin"
sm_streamtest_file "https://ash-speed.hetzner.com/1GB.bin"
```

`sm_streamtest_file` skips the plugin heap entirely because the extension writes the file, so it is the upper bound for the data callback path.

## Commands

| Command | What it does | Access |
| --- | --- | --- |
| `sm_streamtest [url]` | Streams the URL or `sm_streamtest_url` to disk through the data callback. | Root |
| `sm_streamtest_file [url]` | Streams the URL or `sm_streamtest_url` to disk through `SetOutputFile`. | Root |
| `sm_streamtest_cancel` | Cancels the running download. | Root |

## ConVars

| ConVar | Default | What it does |
| --- | --- | --- |
| `sm_streamtest_url` | `https://ash-speed.hetzner.com/1GB.bin` | Default test binary URL (1 GB). |
| `sm_streamtest_chunk_size` | `1048576` | Receive buffer size in bytes (1024 to 2097152). |

## Requirements

- sm-rest extension (https://github.com/BadServersNet/sm-rest). `include/rest.inc` in this repository is the extension's include.

## Installing

Copy `rest.ext.so` to `addons/sourcemod/extensions/`, `ca-bundle.crt` to `addons/sourcemod/configs/rest/` and `rest-stream-test.smx` to `addons/sourcemod/plugins/`, then `sm plugins load rest-stream-test`. The extension loads with the plugin.

Pass URLs from the server console in quotes; the Source console tokenizer splits on `:` otherwise.
