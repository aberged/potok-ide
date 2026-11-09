#!/bin/sh
# Peak memory inside the app container while something runs next to it
# (micro.exs, an avatar request): the cgroup's memory and the largest
# ImageMagick process. Run with `docker compose exec -T app sh /load_test/memwatch.sh 20`.
seconds=${1:-20}
end=$(( $(date +%s) + seconds ))
peak=0 base=$(cat /sys/fs/cgroup/memory.current) magick=0
while [ "$(date +%s)" -lt "$end" ]; do
  current=$(cat /sys/fs/cgroup/memory.current)
  [ "$current" -gt "$peak" ] && peak=$current
  for status in /proc/[0-9]*/status; do
    case "$(sed -n 's/^Name:[[:space:]]*//p' "$status" 2>/dev/null)" in
      magick|convert|rsvg*)
        hwm=$(sed -n 's/^VmHWM:[[:space:]]*\([0-9]*\).*/\1/p' "$status" 2>/dev/null)
        [ -n "$hwm" ] && [ "$hwm" -gt "$magick" ] && magick=$hwm ;;
    esac
  done
  sleep 0.05
done
echo "cgroup_base_mb=$((base / 1048576)) cgroup_peak_mb=$((peak / 1048576)) magick_peak_rss_mb=$((magick / 1024))"
