# GLM-5.3-Flash with a 1M-token context on one DGX Station GB300

A tested recipe for serving `nvidia/GLM-5.3-Flash-NVFP4` on a single NVIDIA DGX Station GB300 with vLLM, at the
model's full 1,048,576-token context, as a systemd service that survives reboots and crash loops.

This is the configuration Petronella Technology Group, Inc. ran in production on its own GB300 starting
2026-09-25. Every number below was measured on that machine; the full results are on our
[GLM-5.3-Flash benchmark page](https://petronellatech.com/ai/llm-benchmarks/models/glm-5-3-flash/).

## What you get

| | |
|---|---|
| Model | `nvidia/GLM-5.3-Flash-NVFP4` (191 GB on disk) |
| Engine | vLLM, tensor parallel 1, image pinned by digest |
| Context | 1,048,576 tokens, chunked prefill and prefix caching on |
| KV cache | fp8 (from the checkpoint config), 5,933,986 tokens: room for 5.66 full 1M-token requests |
| Concurrency | `--max-num-seqs 256` |
| Tools | `--enable-auto-tool-choice --tool-call-parser glm47 --reasoning-parser glm45` |
| API | OpenAI-compatible on port 8888, served model name `glm-5.3-flash` |
| Start-up | about 7 minutes from `systemctl start` to serving (weights about 77 s, compile and graph capture the rest) |

## Measured at go-live (2026-09-25)

| Test | Result |
|---|---|
| Decode, 1 user, 256-token answers | 145.9 tok/s |
| Decode, 32 users at once | 1,464 tok/s aggregate (55.6 tok/s per user), 0 failures |
| Tool-call battery | 38 of 38 |
| Agent battery | 15 of 15 |
| Tool call smoke test | `get_weather` returned as a structured `tool_calls` entry |

The detailed ladder (time to first token, repeats) is in [`results/go-live-2026-09-25.md`](results/go-live-2026-09-25.md).

## The one thing that will bite you: page cache in HBM

On the GB300 the GPU's HBM is NUMA node 1. Heavy file I/O on the host (downloading or copying weights, rsync)
fills node 0's page cache and the kernel then places file pages in HBM. vLLM sees less free GPU memory than it
expects and dies while allocating the KV cache with a self-contradicting out-of-memory error such as
`Tried to allocate 151 GiB ... 159.43 GiB free`.

The fix has three parts, and this recipe does the first one for you:

1. **Drop the page cache before every start.** The pre-start script runs `sync; echo 1 > /proc/sys/vm/drop_caches`.
   Never start the container by hand without it.
2. **Keep bulk I/O off node 1.** Run downloads and copies with `numactl --membind=0 ...` or inside
   `docker run --cpuset-mems 0 ...` so their cache stays in LPDDR, even while the service is running.
3. **Never pin the vLLM container itself to node 0.** `--cpuset-mems 0` on the vLLM container makes CUDA
   initialisation fail with `Error 802`.

Check before a start: `grep FilePages /sys/devices/system/node/node1/meminfo` should be near 0.

## Install

Requirements: a DGX Station GB300, Docker with the NVIDIA container toolkit, and the checkpoint on local disk.
This is the hardware we tested; other GB300 systems should work but we have not measured them.

```bash
# 1. weights (keep the download's page cache off the HBM node)
numactl --membind=0 huggingface-cli download nvidia/GLM-5.3-Flash-NVFP4 --local-dir /srv/models/GLM-5.3-Flash-NVFP4

# 2. service files
sudo install -m 0755 systemd/glm53-flash-prestart.sh /usr/local/sbin/glm53-flash-prestart.sh
sudo install -m 0644 systemd/glm53-flash.service /etc/systemd/system/glm53-flash.service
sudo systemctl daemon-reload
sudo systemctl enable --now glm53-flash

# 3. about 7 minutes later
./scripts/smoke-test.sh http://127.0.0.1:8888/v1
```

Edit the two `-v` paths in `systemd/glm53-flash.service` if your weights or cache live elsewhere.

## Operate

```bash
systemctl status glm53-flash --no-pager
journalctl -u glm53-flash -n 100 --no-pager
docker logs --tail 200 glm53-flash
ls -t /var/log/glm53-flash/                     # logs of earlier containers, saved by the pre-start
sudo systemctl restart glm53-flash              # serving again in about 7 minutes
sudo systemctl reset-failed glm53-flash         # after a crash loop hit the 3-starts-per-hour limit
```

The unit restarts on failure 60 seconds apart, at most 3 times an hour, then stays down so an out-of-memory loop
does not hammer the machine. The pre-start saves the previous container's logs before removing it, because
`docker rm` erases the evidence you need after a crash.

## Known limits

- **No speculative decoding.** Multi-token prediction fails to load with this checkpoint in this vLLM build
  (`size of tensor a (1024) must match ... (2048)`), so the recipe runs without it.
- **No API key.** vLLM binds `0.0.0.0` with no authentication. Put it behind a firewall, a reverse proxy with auth,
  or a private network before anyone else can reach port 8888.
- The image digest pins the vLLM `nightly-aarch64` build of 2026-09-24. A newer build may change memory use or
  parser names; re-test before moving the pin.

## About

Built and measured by [Petronella Technology Group, Inc.](https://petronellatech.com/), which designs and runs
private AI on hardware its clients own. More measured configurations, including GB10 pods, RTX PRO 6000 and H200
servers, are on our [LLM benchmark hub](https://petronellatech.com/ai/llm-benchmarks/).

License: MIT (see `LICENSE`).
