# Upstream rollout plan

Fixes for the bugs found in `HANDOFF.md`, each on its own branch in the
[rfay/socktainer](https://github.com/rfay/socktainer) fork. All are committed
locally with DCO sign-off and passing tests; none have been pushed as PRs to
`socktainer/socktainer` yet. Ranked by importance to unblocking the
[ddev/ddev Apple Container PR](https://github.com/ddev/ddev/issues/7372), with
diff risk/reviewability as the tiebreaker.

Plan: submit one at a time, starting with **#8**, rather than bundling. #7 and
#8 are both required for `ddev start` to fully succeed, but #8 is the safer
opener — it extends a timeout pattern already used elsewhere in the same
file, rather than restructuring a shared data structure the way #7 does.

| Rank | Issue | Branch | Fix summary | Why it matters to DDEV | Diff risk |
|---|---|---|---|---|---|
| 1 | [#8](https://github.com/rfay/socktainer/issues/8) exec hijack never closes | [`fix/exec-hijack-close`](https://github.com/rfay/socktainer/tree/fix/exec-hijack-close) | Bounds the wait on the exec'd process so the hijacked connection's channel always closes, even if Apple Container's XPC `wait()` stalls — races the close against a timeout instead of blocking on `wait()` indefinitely. | Named directly in HANDOFF as one of the two remaining blockers — this is why `ddev start` hangs in `GetRouterConfigErrors()`. | **Low.** One file; extends a timeout-racing pattern already used for the other two exec-start modes in the same file. |
| 2 | [#7](https://github.com/rfay/socktainer/issues/7) DNS wrong-network address | [`fix/dns-wrong-network-address`](https://github.com/rfay/socktainer/tree/fix/dns-wrong-network-address) | `SocktainerDNSServer` now stores one address per network for multi-homed hostnames, and returns whichever address shares a subnet with the querying client instead of an arbitrary one. | The other named blocker — this is the 502 on the last hop. | **Higher.** Restructures the core address-registry data structure; affects DNS resolution for every container, not just multi-homed ones. |
| 3 | [#13](https://github.com/rfay/socktainer/issues/13) version reports API version | [`fix/version-engine-version`](https://github.com/rfay/socktainer/tree/fix/version-engine-version) | `Server.Version` now reports socktainer's own build version instead of the Docker Engine API version (`v1.51`); `ApiVersion`/`MinAPIVersion` untouched. | HANDOFF names DDEV's own "please upgrade Docker" check as affected — can misfire a warning (or worse) during `ddev start`. | **Very low.** Smallest diff of the seven — effectively one line. |
| 4 | [#10](https://github.com/rfay/socktainer/issues/10) archive 404 pre-start | [`fix/archive-404-prestart`](https://github.com/rfay/socktainer/tree/fix/archive-404-prestart) | `ClientArchiveService` now materializes a created-but-never-started container's `rootfs.ext4` on first archive access, using the same local bundle-creation APIs Apple's runtime uses internally, instead of requiring a prior start. | Not named directly, but HANDOFF's cold-start recipe requires a hand-recreated buildkit node to get builds working — this bug (buildx's bootstrap relies on pre-start `docker cp`) is plausibly why. | Moderate. New function, one new `Package.swift` dependency, self-contained. |
| 5 | [#12](https://github.com/rfay/socktainer/issues/12) healthcheck timing | [`fix/healthcheck-timing`](https://github.com/rfay/socktainer/tree/fix/healthcheck-timing) | Fixes two bugs: status no longer regresses from `healthy` to `starting` on a single transient failure below the retry threshold, and the check loop now enforces its own timeout so a stalled probe step can't freeze status updates indefinitely. | Not currently blocking DDEV's specific config (its containers already reach `healthy`), but a real reliability bug for other interval/timeout/start_period combinations. | Moderate. Two independent bugs in one file; changes loop-control flow. |
| 6 | [#9](https://github.com/rfay/socktainer/issues/9) `--filter name=` ignored | [`fix/filter-name-ignored`](https://github.com/rfay/socktainer/tree/fix/filter-name-ignored) | `--filter name=` now matches by substring (OR'd across multiple values), matching Docker semantics, instead of requiring an exact match that effectively never matched. | Not called out as DDEV-blocking; general Docker-CLI correctness bug. | Low. Small, isolated change. |
| 7 | [#11](https://github.com/rfay/socktainer/issues/11) `docker cp` directory hang | [`fix/cp-directory-hang`](https://github.com/rfay/socktainer/tree/fix/cp-directory-hang) | The guest-preparation exec used for directory copies into a running container now has a timeout bound, so a wedged/slow guest shell can't hang the request forever. | Not called out as DDEV-blocking; buildx context upload doesn't go through this path. General robustness/never-hang guarantee. | Low-moderate. |
| 8 | [#1](https://github.com/rfay/socktainer/issues/1) `HostConfig.Privileged` dropped | [`fix/privileged-cap-all`](https://github.com/rfay/socktainer/tree/fix/privileged-cap-all) | `effectiveCapAdd` now grants all capabilities when `HostConfig.Privileged` is set. | Not DDEV-blocking directly; breaks buildx's `docker-container` builder, which the cold-start recipe depends on. | Low. Self-contained, one function. |
| 9 | *(no issue filed yet)* `HostConfig.PortBindings` nil on inspect | [`fix/port-bindings-inspect`](https://github.com/rfay/socktainer/tree/fix/port-bindings-inspect) | Derives `HostConfig.PortBindings` from the same `publishedPorts` data already used for `NetworkSettings.Ports`, instead of hardcoding it to `nil`. | Found this session: DDEV's router reads only `HostConfig.PortBindings` to exclude its own ports from a conflict check — `nil` meant a second DDEV project could never start, on any host, ever. | Low. Self-contained. |
| 10 | *(no issue filed yet)* dict-form filter values dropped for every key but `label` | [`fix/dict-filter-parsing`](https://github.com/rfay/socktainer/tree/fix/dict-filter-parsing) | `parseContainerFilters` now accepts the CLI's `{"key":{"value":true}}` encoding for every filter key, not just `label`. | Half of the same bug as #9/rank 6 above — that fix corrected matching, but the value never reached the matcher for `name`/`status`/`id` filters at all. | Low. Isolated parsing fix. |
| 11 | Independent local fix for [socktainer/socktainer#329](https://github.com/socktainer/socktainer/issues/329) (malformed EDNS0) | [`fix/dns-edns0-truncation`](https://github.com/rfay/socktainer/tree/fix/dns-edns0-truncation) | Refactors the local-response builders into a shared `baseResponse(packet:questionEnd:flags:)` that truncates at the question's end, dropping any EDNS0 OPT record instead of echoing a mismatched one back. | Already filed upstream by someone else (independent corroboration); breaks every Go/musl-averse client's name resolution on a socktainer network. | Moderate. Touches all three response builders in `SocktainerDNSServer.swift`. |

**Addendum to rank 3 (2026-08-05):** fixing `Version` wasn't sufficient on its own —
`ApiVersion`/`MinAPIVersion` themselves carried a `"v"` prefix (`"v1.51"`) reused from a
build-info label, which independently failed DDEV's minimum-Docker-version check
regardless of the (now-correct) `Version` value. Fixed in the same branch, commit
`f4d022c`, by stripping the prefix at the `VersionRoute` call site. See `HANDOFF.md` item 7
for the full root-cause trace.

**All eleven branches above are combined and verified together on `tmp/combined-verify-2`**
(built clean, full `ddev start`/`restart`/`describe`/`stop` cycle against a from-scratch
teardown-and-rebuild of apple container + socktainer, 2026-08-05).

**Not on this list:** [#14](https://github.com/rfay/socktainer/issues/14)
(underscore names skipped for DNS) — investigated thoroughly (live daemon +
variants) and could not be reproduced; no fix was made. Worth closing as
not-reproducible or asking the original reporter for a more specific repro
before pursuing further.

**Merge-order note:** #10 and #11 both touch `ClientArchiveService.swift`
(different functions, no logical conflict). If both eventually go upstream,
expect a small rebase if they land close together.
