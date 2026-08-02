# ADR-0015: RustDesk Server OSS on host networking, with an enforced key and a persisted keypair

## Status

Accepted — 2026-08-02

## Context

We want a self-hosted remote-desktop relay (RustDesk Server OSS: `hbbs` for ID
registration/rendezvous, `hbbr` for relay) on the same VPS that already runs the
GitHub runners, Portainer, Vault, and the kind/k3d training clusters.

### Does it fit alongside the existing stack?

Ports in use today: 22, 80, 443 open via UFW; Portainer on `127.0.0.1:9443`;
Vault on `127.0.0.1:8200/8201`. RustDesk wants 21115–21117/tcp and 21116/udp
(plus 21118/21119/tcp for the browser client). **No collisions.**

Resource cost is negligible at idle — the upstream docs put the floor at a
Raspberry Pi. The real cost is relay bandwidth, and only for sessions where TCP
hole punching fails: 30 KB/s–3 MB/s per relayed session depending on resolution,
~100 KB/s for ordinary office use. Direct connections never touch the server.

### Three decisions fall out of putting it here specifically

**1. Networking mode.** RustDesk's reference compose uses `network_mode: host`.
The alternative is publishing ports with `-p`:

| | `network_mode: host` | `-p` port publishing |
|---|---|---|
| Client source IP seen by hbbs | real | rewritten by docker-proxy/NAT |
| NAT type detection | works | degraded |
| Firewall governance | UFW rules apply | Docker writes its own `DOCKER` iptables chain, which is consulted **before** UFW's — the ports are reachable regardless of UFW state |
| Port isolation | none — binds the host's ports directly | container-scoped |

The firewall row is the decisive one. ADR-0006 established UFW-via-Ansible as
the single source of truth for this VPS's inbound surface. Publishing RustDesk's
ports with `-p` would silently open six ports that UFW believes are closed —
a false-negative in exactly the mechanism we rely on. Host networking keeps the
UFW rules meaningful and gets correct NAT detection as a bonus.

**2. Relay authentication.** An OSS relay with no key set will happily relay for
anyone who knows the IP — it is an open bandwidth relay on a box that also holds
CI runners and Vault. Running `hbbs`/`hbbr` with `-k _` makes the server require
its generated public key, so only clients we have configured can register.

**3. Keypair persistence.** `hbbs` generates `id_ed25519` / `id_ed25519.pub` in
`/root` on first start. That keypair *is* the server's identity: lose it and
every configured client breaks and must be re-keyed by hand. With `-k _` this
goes from an inconvenience to a hard outage. It needs a named volume (per
ADR-0014) and it needs to be in the backup set.

### Where the role's UFW rules live

`common` currently owns every UFW rule (22/80/443). Putting RustDesk's six rules
there too would follow the existing pattern, but it splits the role's inbound
surface away from the role that opens it — removing `rustdesk` from `site.yml`
would leave the ports open. Keeping the rules in the `rustdesk` role makes the
role self-contained at the cost of one deviation from the current layout.

## Decision

- Deploy `hbbs` + `hbbr` as an Ansible role (`roles/rustdesk`) mirroring the
  `portainer` role's shape, **not** in the repo-root `docker-compose.yml` — that
  file is the application payload shipped by the Hostinger deploy action.
- Use `network_mode: host` for both containers.
- Run both with `-k _` so the relay requires the server's public key.
- Persist `/root` to a named volume (`rustdesk_data`) with an explicit `name:`
  so it is independent of the compose project prefix and can be addressed
  directly by backup tooling.
- Own the RustDesk UFW rules in the `rustdesk` role, not in `common`.
- Pin the image to `rustdesk/rustdesk-server:1.1.16` rather than `:latest`.
- Leave the web-client ports (21118/21119) closed by default, behind a flag.

## Consequences

**Positive**
- UFW remains an accurate description of the VPS's inbound surface (ADR-0006).
- hbbs sees real client addresses, so NAT type detection and hole punching work
  as designed — which keeps traffic *off* the relay and off our bandwidth bill.
- The relay is not usable by strangers.
- `rustdesk` can be removed from `site.yml` and take its firewall holes with it.

**Negative**
- Host networking gives both containers the host's full network namespace —
  weaker isolation than the rest of the stack, and they bind their ports whether
  or not UFW allows them through (UFW then blocks external reach, but the
  processes are still listening on all interfaces).
- `rustdesk_data` is now a single point of failure. TODO.md's backup item must
  cover it alongside `portainer_data` and `runner_work`.
- Six more open ports on a host that also runs privileged CI runners. The
  RustDesk containers are not privileged and do not mount the Docker socket, so
  they do not widen the socket exposure described in ADR-0013.
- CI load and relay quality contend for the same box: a kind cluster spinning up
  under a `privileged` runner can add latency to a live remote session. Accepted
  for a demo lab; a dedicated relay host is the fix if it ever matters.

**Deferred**
- Web client (21118/21119) stays off. On those ports hbbs/hbbr trust
  `X-Real-IP` / `X-Forwarded-For` **without validating them**, so anyone who can
  reach the port directly can spoof their apparent source IP. Enabling it safely
  means fronting it with a reverse proxy that overwrites both headers.

## Code

```yaml
services:
  hbbs:
    image: rustdesk/rustdesk-server:1.1.16
    command: ["hbbs", "-k", "_"]     # require the server's public key
    network_mode: host               # real client IPs; UFW stays authoritative
    volumes:
      - rustdesk_data:/root          # holds id_ed25519 — back this up
    depends_on:
      - hbbr
    restart: unless-stopped

  hbbr:
    image: rustdesk/rustdesk-server:1.1.16
    command: ["hbbr", "-k", "_"]
    network_mode: host
    volumes:
      - rustdesk_data:/root
    restart: unless-stopped

volumes:
  rustdesk_data:
    name: rustdesk_data
```
