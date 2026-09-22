# rest-stream-test

Test plugin for the sm-rest streaming HTTP download API. Not intended for production use.

## How it works

`sm_streamtest [url]` creates a GET request with `OnHeaders`, `OnProgress` and `OnData` callbacks. Each data callback appends its chunk to `addons/sourcemod/data/rest-stream-test.bin`. `sm_streamtest_file [url]` downloads the same URL through `SetOutputFile`, where the extension writes the file itself, for comparison. Progress is printed once per second to the server console and to the console of the client that ran the command. On completion it reports the HTTP status, bytes received, chunk count, largest chunk, on-disk file size, whether it matches `Content-Length`, and throughput.

`sm_streamtest_chunk_size` sets the extension's receive buffer, which bounds each chunk. The plugin is compiled with `#pragma dynamic 786432` (3 MiB) because every chunk is copied onto the plugin heap before the callback runs, so the chunk size is capped at 2 MiB.

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

Pass URLs from the server console in quotes; the Source console tokenizer splits on `:` otherwise.
