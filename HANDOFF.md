# socktainer bugs found while getting DDEV running on Apple Container (2026-08-02)

Working notes from an investigation into [DDEV](https://github.com/ddev/ddev) issue
[#7372](https://github.com/ddev/ddev/issues/7372) (Apple Container / socktainer support).
Getting a real Docker Compose stack (three services, two user-defined networks, a reverse
proxy routing by container name) end-to-end on socktainer surfaced several socktainer bugs.
This file is expected to be deleted once the issues below are filed/fixed — it's a handoff
note, not documentation.

Environment throughout: Apple `container` 1.2.0, socktainer 1.2.1 (Homebrew), macOS 26,
Docker CLI 29.4.0, docker context `socktainer`.

**None of the repro steps below need DDEV.** Each is a plain `docker`/`container`/`dig`
sequence. The DDEV-specific reproduction is in the last section, for confirming a fix
actually closes the loop on the real workload that found the bug.

## Already filed upstream

- **[#329](https://github.com/socktainer/socktainer/issues/329) — malformed EDNS0 DNS
  response.** This is "Bug A" below; someone else filed it four days before this
  investigation independently hit the same thing. See that issue for a second,
  independent repro (Dapr/Postgres rather than DDEV/Traefik) — the two reports corroborate
  each other. Nothing new to add here except that it's the single highest-impact fix in
  this list: it breaks *every* Go or musl-averse client's name resolution on a
  socktainer network, not just DDEV's.

Checked but not duplicates: issue [#21](https://github.com/socktainer/socktainer/issues/21)
(closed) is a different, already-fixed exec bug — malformed JSON in the resize/start
request for *interactive* (`Tty:true`) execs. The exec bug below is about *non-interactive*
execs and is a connection-lifecycle issue, not a parsing one.

## Not yet filed — up for grabs

### 1. DNS: per-network resolver answers with the wrong network's address ("Bug B")

Distinct from #329 — this one is about *which* address comes back, not how the packet is
encoded. On a container attached to two networks, the DNS resolver scoped to one network
answers a lookup for a peer's name with that peer's address **on the other network**,
which the querying container can't reach.

**Repro** (no DDEV, no Compose even — two networks, three plain containers):

```bash
docker network create netA
docker network create netB

# "web" joins both networks; "client" only joins netB
docker run -d --name web   --network netA --network-alias web nginx:alpine
docker network connect netB web              # web is now on both netA and netB
docker run -d --name client --network netB alpine sleep 300

# Find netB's DNS sidecar IP
docker network inspect netB --format '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{"\n"}}{{end}}'

# Ask netB's resolver (not netA's) for web's address
docker exec client sh -c 'apk add --no-cache bind-tools >/dev/null; dig +noedns @<netB-dns-ip> web A'
```

Expected: the `A` record returned is `web`'s address **on netB** (the network the querying
container and the resolver are both on). Observed: the address returned is `web`'s address
on netA — unreachable from `client`, so anything using the name (rather than a
pre-resolved IP) times out instead of connecting.

This was found via a reverse-proxy container attached to two networks routing to a backend
also on both networks; the proxy got the backend's address on the *other* network and every
request timed out. `docker exec <proxy> curl --resolve <name>:<port>:<correct-ip> ...`
against the correct address succeeded immediately, confirming it's purely a DNS-answer
problem, not routing/firewall.

Likely location: `Sources/socktainer/DNS/NetworkDNSManager.swift` /
`SocktainerDNSServer.swift` — wherever the per-network resolver picks which of a
multi-homed container's addresses to return.

### 2. Non-interactive exec: hijacked connection never closes after the process exits

`POST /exec/{id}/start` with `{"Detach":false,"Tty":false}` upgrades the HTTP connection to
a raw hijacked stream, per the Docker Engine API contract, and the client is supposed to see
the far end close once the exec'd process exits (that close is what tells a `stdcopy`-style
reader "no more output coming"). socktainer delivers the process's output correctly over
that hijacked stream — byte-for-byte, correctly-framed multiplexed stdout/stderr — but never
closes the connection afterward, so any client that waits for EOF (which the Docker Go
client and Docker CLI itself both do for exec's Go/CLI-internal codepath) hangs forever,
long after the command has finished and all output has already arrived.

**Repro** (raw HTTP against the socket, no docker CLI's own exec plumbing involved, since
the CLI's `docker exec` without `-it` happens to use the codepath that *doesn't* hijack —
see the workaround below):

```bash
CID=$(docker run -d alpine sleep 300)

# Create the exec
EXEC_ID=$(curl -s --unix-socket ~/.socktainer/container.sock \
  -H 'Content-Type: application/json' \
  -d '{"Cmd":["echo","hi"],"AttachStdout":true,"AttachStderr":true}' \
  -X POST "http://localhost/containers/$CID/exec" | jq -r .Id)

# Start it as a hijacked connection (the Docker API's documented upgrade path for
# an attached, non-detached exec) and time how long the client sits after output arrives
time curl -s --unix-socket ~/.socktainer/container.sock \
  -H 'Content-Type: application/json' -H 'Connection: Upgrade' -H 'Upgrade: tcp' \
  -d '{"Detach":false,"Tty":false}' \
  -X POST "http://localhost/exec/$EXEC_ID/start" --max-time 15
```

Expected: `hi` prints and the connection closes immediately after (well under a second, as
real `dockerd` does — confirmed against OrbStack's dockerd for comparison). Observed on
socktainer: `hi` prints correctly, then the connection sits open until `curl`'s
`--max-time` kills it — confirmed with `--max-time` values well past any plausible command
runtime.

**Confirmed workaround, which is itself evidence for where the bug is:** issuing the exact
same `/exec/{id}/start` POST *without* the `Upgrade` header (a plain, non-hijacked request —
what a client that never attaches stdin has no need to request) gets a normal HTTP response
instead: `Transfer-Encoding: chunked`, and it terminates correctly on both socktainer and
real dockerd. So the output-producing and framing code is fine either way; only the
post-exit connection teardown on the *hijacked* path is broken.

Likely location: `Sources/socktainer/Routes/Containers/ExecRoutes.swift` — the branch that
handles the Upgrade/hijack path for exec-start, specifically whatever should close the
connection when the underlying process's stdio pipes report EOF. The README's own
"Piping I/O to container processes" section (StdioPipes / fd double-close) may well be
related: if the hijacked connection's teardown depends on the same `stdout`/`stderr` pipe
close signal described there, a dropped or ignored close callback on this specific path
would produce exactly this symptom.

### 3. `docker ps --filter name=<x>` is silently ignored

```bash
docker run -d --name keep-me alpine sleep 300
docker run -d --name filter-me-out alpine sleep 300
docker ps --filter name=keep-me --format '{{.Names}}'
```

Expected: only `keep-me`. Observed: both containers are returned — the filter has no
effect at all. Severity note: this is the one worth fixing first, independent of any
particular client's use of it — it's silently *wrong* rather than unsupported, so anything
built on `docker ps --filter name=... | xargs docker rm -f` (a common idiom) will delete
containers it was never told to touch.

Likely location: `Sources/socktainer/Routes/Containers/ContainerListRoute.swift`.

### 4. `PUT /containers/{id}/archive` 404s on a created-but-not-started container

Docker allows copying files into a container between `create` and `start`; several tools
(buildx's buildkit bootstrap among them) rely on exactly this.

```bash
docker create --name archivetest alpine sleep 300
echo hi > /tmp/onefile.txt
docker cp /tmp/onefile.txt archivetest:/onefile.txt
```

Expected: succeeds (real dockerd allows writing into a container's filesystem before first
start). Observed: `Error response from daemon: 404 Rootfs not found` (or equivalent) —
works fine once the same container has been started at least once.

Likely location: `Sources/socktainer/Routes/Containers/ContainerArchiveRoute.swift` /
`Sources/socktainer/Clients/ClientArchiveService.swift`.

### 5. `docker cp` of a directory is unsupported, and hangs through the API instead of erroring

```bash
mkdir -p /tmp/cpdirtest/sub && echo hi > /tmp/cpdirtest/sub/file.txt
docker run -d --name cptarget alpine sleep 300
docker cp /tmp/cpdirtest/. cptarget:/dest/        # or: docker cp /tmp/cpdirtest cptarget:/dest/
```

Expected: either it works (real dockerd supports directory copy via a tar stream) or it
fails fast with a clear error. Observed: single-file copies work; directory copies either
error (`cannot copy directory` for the no-trailing-dot form) or, for the `/.` form driven
through the raw API rather than the CLI's own tar-then-PUT behavior, **hang** rather than
returning an error at all — worse than a clean rejection, since a caller has no signal to
give up and fall back to per-file copies.

Likely location: `Sources/socktainer/Utilities/ArchiveUtility.swift`.

### 6. Healthcheck timing: long `start_period` never reports, and health regresses `healthy` → `starting`

```bash
docker run -d --name healthtest \
  --health-cmd "true" --health-interval=1s --health-timeout=70s --health-start-period=120s \
  alpine sleep 300
sleep 20 && docker inspect healthtest --format '{{.State.Health.Status}}: {{.State.Health.Log}}'
```

Expected: after `start_period` elapses (or once enough successful checks have run —
whichever a given engine uses to gate the *first* status update), `.State.Health.Status`
moves off `starting` and `.State.Health.Log` gets populated with check results. Observed:
with these timings status stays `starting` and the log stays empty indefinitely (verified
past 4 minutes, well beyond the 120s `start_period`). Shortening to
`--health-interval=2s --health-timeout=10s --health-start-period=10s` on the same command
makes it report `healthy` with a populated log within ~10s — so the checks *are* running,
something about the specific combination of long `start_period`/`timeout` values with a
short `interval` prevents the status transition from ever being applied.

Separately, health has also been observed to regress from `healthy` back to `starting` on
a container that's been running a while with no config change — so whatever tracks current
status is not stable over time either.

Likely location: `Sources/socktainer/Utilities/HealthCheckManager.swift` /
`Sources/socktainer/Clients/ClientHealthCheckService.swift`.

### 7. Version/Engine both report the API version (`v1.51`) instead of a product version

```bash
docker version --format '{{.Server.Version}}'
docker version --format '{{(index .Server.Components 0).Version}}'
```

Expected: something like `28.x.x` (a real Docker Engine version) or socktainer's own
version — some string a client's "is this Docker new enough" check can compare against a
minimum *engine* version. Observed: both fields report `v1.51`, which is the **API**
version (correct as the API version, wrong as the engine version) — this makes any tool
that version-gates on engine version (Docker Desktop update nags, DDEV's own "please
upgrade Docker" check, etc.) either misfire or emit a bogus warning, since `1.51` sorts
far below any real minimum-engine-version check.

Likely location: `Sources/socktainer/Routes/Server/VersionRoute.swift`.

### 8. Container names containing underscores are skipped for DNS registration

```bash
docker network create undertest
docker run -d --name has_underscore --network undertest alpine sleep 300
docker run -d --name plain_client --network undertest alpine sleep 300
docker exec plain_client getent hosts has_underscore
```

Expected: resolves, the same as any other container name on a user-defined network.
Observed: `getent hosts has_underscore` fails — the name was never registered in the DNS
sidecar at all, apparently because the registration path rejects/skips names containing
underscores (which Docker itself allows in container names, if not always in *hostnames*).

Likely location: `Sources/socktainer/DNS/NetworkDNSManager.swift` — whatever validates a
name before registering it as a DNS record.

## Explicitly out of scope here — filed against the wrong project otherwise

These looked at first like socktainer bugs but reproduce identically with the native
`container` CLI, socktainer entirely out of the request path — they belong in
[apple/container](https://github.com/apple/container), not here:

- Named volumes can only be attached read-write by one container at a time (read-only
  attach is shared and not exclusive, which is the important nuance — see the DDEV-side
  HANDOFF.md for the exact test matrix).
- Published ports (`-p host:container`) are accepted but connections to them get reset;
  the same container answers fine on its direct container IP.
- Ports below 1024 can't be published at all (`container`'s port forwarder runs
  unprivileged).
- `vmnet` network state degrades/disappears after periods of idle or heavy churn.

Don't spend socktainer-side effort on these — confirmed independently with `container run`
directly, no `docker`/socktainer involved.

## How to test against the actual workload that found these

The stack that surfaced all of the above is DDEV (a local dev-environment tool) running an
experimental "use socktainer as the Docker provider" mode. You don't need to understand
DDEV to use it as an end-to-end check — it's just a known-good multi-service Compose stack
(web + db + reverse-proxy, two networks) that happens to be more demanding than a
hand-rolled repro.

```bash
# Build DDEV from the experimental branch (separate checkout, e.g. ~/workspace/ddev)
cd ~/workspace/ddev
git fetch upstream
git checkout 20260802_rfay_apple_container_experiment
make                                    # -> .gotmp/bin/darwin_arm64/ddev
export PATH="$(pwd)/.gotmp/bin/darwin_arm64:$PATH"

docker context use socktainer

mkdir -p ~/tmp/appletest && cd ~/tmp/appletest
ddev config --project-type=php --docroot=web --auto
cat >> .ddev/config.yaml <<'EOF'
performance_mode: none
omit_containers: [ddev-ssh-agent]
EOF
ddev start
```

Before running `ddev start`, see `HANDOFF.md` in the `ddev` repo (same branch) for the
**cold-start recipe** — a `keepalive` container, a host-side `dnsmasq` forwarding to
socktainer's own DNS, and a hand-recreated buildkit node are all currently required for the
environment to have working DNS/builds at all, independent of any of the bugs above. That
file also has the full context these fixes came out of, including the exact byte-level
traces for bugs A and B and the design discussion for the volume-sharing problem (which is
Apple Container's, not socktainer's, per the "out of scope" section above).

As of this writing, with items 1–2 above (DNS Bug B and the exec hang) unfixed, `ddev start`
does not fully succeed: it reaches all three containers healthy and Traefik routing
correctly, then either 502s on the last hop (DNS) or hangs indefinitely in
`GetRouterConfigErrors()` (the exec hang — same `dockerutil.Exec()` codepath as the DNS Bug
B repro's proxy scenario above, just reached via DDEV's own router-status check instead of
a hand-rolled `curl`). Fixing #329 (already filed) plus items 1 and 2 in this file should be
enough to get a plain PHP project fully working end-to-end.
