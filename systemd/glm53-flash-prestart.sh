#!/bin/bash
# Run as root by glm53-flash.service (ExecStartPre).
# 1. Save the logs of any previous glm53-flash container BEFORE removing it (docker rm erases the evidence).
# 2. Remove it.
# 3. Drop the page cache so HBM (NUMA node 1 on the GB300) holds no file pages when vLLM sizes its KV cache.
set -u
LOGDIR=${GLM53_LOGDIR:-/var/log/glm53-flash}
mkdir -p "$LOGDIR"
if docker inspect glm53-flash >/dev/null 2>&1; then
  TS=$(date +%Y%m%d-%H%M%S)
  docker logs glm53-flash > "$LOGDIR/prev-$TS.log" 2>&1 || true
  docker inspect glm53-flash --format '{{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} finished={{.State.FinishedAt}}' \
    >> "$LOGDIR/prev-$TS.log" 2>&1 || true
  docker rm -f glm53-flash >/dev/null 2>&1 || true
fi
# keep the 20 newest saved logs
find "$LOGDIR" -maxdepth 1 -name 'prev-*.log' -printf '%T@ %p\n' | sort -rn | tail -n +21 | cut -d' ' -f2- | xargs -r rm -f --
sync
echo 1 > /proc/sys/vm/drop_caches
echo "node1 $(grep FilePages /sys/devices/system/node/node1/meminfo)"
