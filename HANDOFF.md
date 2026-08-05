# socktainer bugs found while getting DDEV running on Apple Container (2026-08-02)

Working notes from an investigation into [DDEV](https://github.com/ddev/ddev) issue
[#7372](https://github.com/ddev/ddev/issues/7372) (Apple Container / socktainer support).
Getting a real Docker Compose stack (three services, two user-defined networks, a reverse
proxy routing by container name) end-to-end on socktainer surfaced several socktainer bugs.
This file is expected to be deleted once the issues below are filed/fixed — it's a handoff
note, not documentation.

Environment throughout: Apple `container` 1.2.0, socktainer 1.2.1 (Homebrew), macOS 26,
Docker CLI 29.4.0, docker context `socktainer`. **Note (2026-08-05):** use the signed
installer's `container` CLI (`/usr/local/bin/container`, `installRoot: /usr/local/`), not
the Homebrew formula — Homebrew installs `container` as a shadowed, unused dependency of
something else on this machine (`brew info container` shows "Installed (as dependency)");
running the wrong one is a separate, not-yet-filed issue in its own right (see TODOs).

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

**Status (2026-08-05):** items 1–8 below are all fixed locally, each on its own branch under
`~/workspace/socktainer-worktrees/`, combined and verified together on `tmp/combined-verify-2`
(built clean, full `ddev start`/`restart`/`stop` cycle passes end-to-end). None has an open
PR — see `UPSTREAM_ROLLOUT.md` for the submission plan and two more bugs (9, 10 below) found
after this file was originally written.

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

**Fixed on `fix/dns-wrong-network-address`:** stores one address per network per
multi-homed container, returns whichever shares a subnet with the querying client.

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

**Fixed on `fix/exec-hijack-close`:** honors the upgrade request regardless of
`attachStdin`, closes on output EOF. Supersedes the two commits that shipped as closed PR
#347 — rewritten as one corrected commit.

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

**Fixed on `fix/filter-name-ignored`** (matching semantics) **+ `fix/dict-filter-parsing`**
(parsing) — both were needed: the matcher was wrong, and separately the dict-form filter
value was silently dropped before it ever reached the matcher for any key but `label`.

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

**Fixed on `fix/archive-404-prestart`:** materializes `rootfs.ext4` on first archive access
for a created-but-never-started container, using the same local bundle-creation APIs
Apple's own runtime uses internally.

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

**Fixed on `fix/cp-directory-hang`:** the guest-preparation exec used for directory copies
now has a timeout bound, so a wedged/slow guest shell can't hang the request forever.

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

**Fixed on `fix/healthcheck-timing`,** two commits: probes during `start_period` instead of
sleeping through it (status now correctly transitions once enough checks have run, however
long `start_period` is), and probes as the container's own user instead of root (a second,
independently-found bug — root-owned `/tmp/healthy` couldn't be removed by the container's
own user on the next probe, breaking `ddev restart` specifically; no unit test possible,
`execProbe` isn't reachable through the injectable test seam, verified live only).

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

**Fixed on `fix/version-engine-version`:** `Version`/`Components[0].Version` now report
socktainer's own build version instead of the API version.

**Found and fixed 2026-08-05, same branch (`f4d022c`):** fixing `Version` wasn't enough —
`ApiVersion`/`MinAPIVersion` themselves carry a literal `"v"` prefix (`"v1.51"`,
`"v1.32"`), reusing a build-info label (`make version`) meant for human-readable output as
the wire value. Real Docker Engine's `ApiVersion` field is always bare digits (`"1.51"`).
Confirmed with a throwaway Go program against
`github.com/moby/moby/client/pkg/versions`: `GreaterThanOrEqualTo("v1.51", "1.44")` is
`false`, but `GreaterThanOrEqualTo("1.51", "1.44")` is `true` — the leading `"v"` alone,
regardless of the actual number, is what makes any version-gating client (DDEV's own
minimum-Docker-version check among them) reject a perfectly adequate API version. Fixed by
stripping the `"v"` prefix at the `VersionRoute` call site only; the build-info getters
that supply the labeled form elsewhere are untouched.

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

**Status:** merged upstream independently (#344/#345) before this was ever filed; the local
`fix/underscore-dns` branch/worktree was retired as redundant.

### 9. `HostConfig.Privileged` is accepted but silently ignored

```bash
docker run -d --name privtest --privileged alpine sleep 300
docker inspect privtest --format '{{.HostConfig.Privileged}}'
```

Expected: the container actually runs with all capabilities granted, matching what
`HostConfig.Privileged: true` means on real Docker. Observed: the flag round-trips
correctly on inspect, but the container's effective capability set is unaffected — no
capabilities beyond the image's defaults are actually granted.

Likely location: `Sources/socktainer/Routes/Containers/ContainerCreateRoute.swift`.

**Fixed on `fix/privileged-cap-all`:** `effectiveCapAdd` now grants all capabilities when
`HostConfig.Privileged` is set, matching Docker's own behavior.

### 10. `HostConfig.PortBindings` is always `nil` on inspect

```bash
docker run -d --name porttest -p 8888:80 nginx:alpine
docker inspect porttest --format '{{json .HostConfig.PortBindings}}'
docker inspect porttest --format '{{json .NetworkSettings.Ports}}'
```

Expected: both fields report the same published-port mapping — Docker reports it in both
places, `HostConfig.PortBindings` is what was requested, `NetworkSettings.Ports` is what is
bound. Observed: `NetworkSettings.Ports` is correct; `HostConfig.PortBindings` is always
`nil`. Severity note: this is the one most worth fixing regardless of any particular
client — DDEV's own router-port-conflict check reads only `HostConfig.PortBindings` to
learn which ports its own already-running router holds, so a `nil` here meant it always
treated the router's own ports as some other process's conflict and a second project could
never start, on any host, every time.

Likely location: `Sources/socktainer/Routes/Containers/ContainerInspectRoute.swift` /
`Sources/socktainer/Models/RESTConfig.swift`.

**Fixed on `fix/port-bindings-inspect`:** derives both fields from the same
`publishedPorts` data instead of hardcoding `HostConfig.PortBindings` to `nil`.

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

Before running `ddev start`, see `HANDOFF.md` in the `ddev` repo (same branch) for two
recipes: **"Full teardown-and-rebuild recipe"** (rebuilding apple container, socktainer,
and the docker context themselves from nothing — verified reproducible 2026-08-05) and,
one layer up, the **cold-start recipe** — a `keepalive` container, a host-side `dnsmasq`
forwarding to socktainer's own DNS, and a hand-recreated buildkit node, all still required
for the environment to have working DNS/builds regardless of the bugs above. That file also
has the full context these fixes came out of, including the exact byte-level traces for
bugs A and B and the design discussion for the volume-sharing problem (which is Apple
Container's, not socktainer's, per the "out of scope" section above).

**Status as of 2026-08-05:** items 1–10 above are all fixed locally (combined and verified
on `tmp/combined-verify-2`, per the note at the top of this file). With all of them plus
#329 (DNS Bug A, already filed) applied, `ddev start`/`restart`/`describe`/`stop` succeed
end-to-end against a plain PHP project — confirmed via a full teardown-and-rebuild-from-
scratch run the same day. None of these fixes has an open PR yet; see
`UPSTREAM_ROLLOUT.md` for the submission plan.
