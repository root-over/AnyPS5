#!/bin/bash
set -uo pipefail

say() { echo "BENCH $*"; }
stamp() { echo "$EPOCHREALTIME"; }
elapsed() { awk -v a="$1" -v b="$(stamp)" 'BEGIN { printf "%.1f", b - a }'; }
load() { cut -d' ' -f1-3 /proc/loadavg; }
stats() { ccache --print-stats | awk '/^(direct_cache_hit|preprocessed_cache_hit|cache_miss)\t/ { printf "%s=%s ", $1, $2 }'; }

say "ninja $(ninja --version) | $(cmake --version | head -1) | $(ccache --version | head -1) | $(gcc --version | head -1)"
say "nproc $(nproc) | $(awk '/^(MemTotal|MemAvailable|SwapTotal):/ { printf "%s %d MB ", $1, $2 / 1024 }' /proc/meminfo) | load $(load)"
say "cpu $(grep -m1 '^model name' /proc/cpuinfo | cut -d: -f2-)"
say "runner dirs $(ls -d /opt/actions-runner* 2>/dev/null | wc -l) | runner services $(systemctl list-units --all --no-legend 'actions.runner*' 2>/dev/null | wc -l) | flock $(command -v flock) | time $(command -v time)"
say "ccache config: $(ccache -p 2>/dev/null | grep -E ' (direct_mode|depend_mode|compiler_check|hash_dir|sloppiness|max_size|inode_cache) ' | sed 's/^(.*) //' | tr '\n' ';')"
say "cache dir usage $(du -sh /var/cache/anyps5 2>/dev/null | cut -f1) | disk $(df -h --output=avail /var/cache/anyps5 | tail -1)"

tools=$RUNNER_TOOL_CACHE/wild
dir=$tools/0.10.0
if [ ! -x "$dir/bin/ld" ]; then
  mkdir -p "$tools"
  tmp=$(mktemp -d "$tools/.wild.XXXXXX")
  name=wild-linker-0.10.0-x86_64-unknown-linux-gnu
  curl -fsSL --retry 3 -o "$tmp/$name.tar.gz" "https://github.com/davidlattimore/wild/releases/download/0.10.0/$name.tar.gz"
  echo "641265506a7c06cfb03181b8916ab663ec8407855db6d4db7f8450667d105283  $tmp/$name.tar.gz" | sha256sum -c - || exit 1
  tar -xzf "$tmp/$name.tar.gz" -C "$tmp"
  mkdir -p "$tmp/out/bin"
  mv "$tmp/$name/wild" "$tmp/out/bin/wild"
  ln -s wild "$tmp/out/bin/ld"
  mv -T "$tmp/out" "$dir" 2>/dev/null || test -x "$dir/bin/ld"
  rm -rf "$tmp"
fi
lf=-B$dir/bin

configure() {
  local s
  s=$(stamp)
  cmake -S . -B build $CONFIGURE -DANYPS5_ENABLE_SPIRV_TOOLS=ON "-DCMAKE_EXE_LINKER_FLAGS=$lf" "-DCMAKE_SHARED_LINKER_FLAGS=$lf" "-DCMAKE_MODULE_LINKER_FLAGS=$lf" > configure.log 2>&1 || { tail -30 configure.log; exit 1; }
  say "configure $1 $(elapsed "$s") s load $(load)"
}

ninjalog() {
  python3 - build/.ninja_log "$1" <<'EOF'
import sys
rows = []
for line in open(sys.argv[1]):
    if line.startswith('#'):
        continue
    start, end, _, out, *_ = line.rstrip('\n').split('\t')
    rows.append((int(end) - int(start), out))
obj = [d for d, o in rows if o.endswith('.o')]
oth = [(d, o) for d, o in rows if not o.endswith('.o')]
print(f"BENCH ninjalog {sys.argv[2]}: steps {len(rows)}, .o {len(obj)} sum {sum(obj) / 1000:.1f} s mean {sum(obj) / max(len(obj), 1):.0f} ms, other {len(oth)} sum {sum(d for d, _ in oth) / 1000:.1f} s")
for d, o in sorted(oth, reverse=True)[:5]:
    print(f"BENCH   slowest other {d / 1000:.1f} s {o}")
for d, o in sorted(rows, reverse=True)[:5]:
    print(f"BENCH   slowest step {d / 1000:.1f} s {o}")
EOF
}

build() {
  local s rc
  rm -rf build
  configure "fresh-for-j$1"
  ccache -z > /dev/null
  s=$(stamp)
  cmake --build build -j "$1" -- -l "$(nproc)" > build.log 2>&1
  rc=$?
  say "build -j$1 rc=$rc $(elapsed "$s") s load $(load) | $(stats)"
  [ "$rc" = 0 ] || { tail -40 build.log; exit 1; }
  ninjalog "j$1"
}

build 2
build 8
build 2
build 8

s=$(stamp)
cmake --build build -- -l "$(nproc)" > noop.log 2>&1
say "no-op build $(elapsed "$s") s ($(tail -1 noop.log))"
configure "existing-dir"
s=$(stamp)
cmake --build build -- -l "$(nproc)" > noop.log 2>&1
say "build after reconfigure $(elapsed "$s") s ($(tail -1 noop.log))"

runtests() {
  local name=$1 s rc
  shift
  s=$(stamp)
  env ANYPS5_REQUIRE_VULKAN=1 GALLIUM_OVERRIDE_CPU_CAPS=avx "$@" ctest --test-dir build --timeout 120 --output-log "ctest-$name.log" > "ctest-$name.out" 2>&1
  rc=$?
  say "ctest $name rc=$rc $(elapsed "$s") s load $(load) | $(grep -E 'tests passed' "ctest-$name.out")"
  grep -E '^\s+[0-9]+ - ' "ctest-$name.out" | sed 's/^/BENCH   failed /' | head -20
}

runtests j2 CTEST_PARALLEL_LEVEL=2
runtests j4 CTEST_PARALLEL_LEVEL=4
runtests j8-lp2 CTEST_PARALLEL_LEVEL=8 LP_NUM_THREADS=2
runtests j8 CTEST_PARALLEL_LEVEL=8
runtests j4-again CTEST_PARALLEL_LEVEL=4

ninja -C build -t compdb > compdb.json
python3 - compdb.json <<'EOF'
import json, os, shlex, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
entries = [e for e in json.load(open(sys.argv[1])) if e['file'].endswith(('.cpp', '.cc', '.c')) and '3rdparty' not in e['file'] and os.path.exists(e['file'])]
entries.sort(key=lambda e: os.path.getsize(e['file']), reverse=True)
seen, pick = set(), []
for e in entries:
    if e['file'] not in seen:
        seen.add(e['file'])
        pick.append(e)
    if len(pick) == 16:
        break
env = dict(os.environ, CCACHE_DISABLE='1')
def run(e):
    p = subprocess.Popen(e['command'], shell=True, cwd=e['directory'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    _, status, ru = os.wait4(p.pid, 0)
    return ru.ru_maxrss / 1024, ru.ru_utime + ru.ru_stime, status, os.path.relpath(e['file'])
with ThreadPoolExecutor(4) as ex:
    res = list(ex.map(run, pick))
for mb, cpu, status, f in sorted(res, reverse=True):
    print(f"BENCH cold compile peak {mb:.0f} MB cpu {cpu:.1f} s status {status} {f}")
EOF
say "done load $(load)"
