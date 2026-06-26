# ADR-0012: Docker Compose V2 plugin, not standalone docker-compose v1

## Status

Accepted — 2026-06-26

## Context

Two versions of Docker Compose exist:

| | V1 (`docker-compose`) | V2 (`docker compose`) |
|---|---|---|
| Binary | Standalone Python binary | Go plugin bundled with Docker Engine |
| Invocation | `docker-compose up` | `docker compose up` (space, not hyphen) |
| Install | `pip install docker-compose` or distro package | `docker-compose-plugin` apt package, ships with Docker Desktop |
| Maintenance | End-of-life June 2023 | Actively maintained |
| Default container naming | `projectname_service_1` | `projectname-service-1` (hyphens) |

Docker Inc. deprecated V1 in 2023. Distros are removing it from default repositories. New Docker Engine installations no longer include it.

Within Ansible, this mirrors to two collection modules:
- `community.docker.docker_compose` — wraps V1, deprecated
- `community.docker.docker_compose_v2` — wraps V2, current

## Decision

Use Docker Compose V2 exclusively:
- Install `docker-compose-plugin` via the `docker` Ansible role (not `docker-compose` standalone)
- Use `docker compose` (space) in all scripts and workflow steps
- Use `community.docker.docker_compose_v2` and `community.docker.docker_compose_v2_pull` in all Ansible tasks
- Container names follow the V2 pattern: `<project>-<service>-<index>` (e.g., `portainer-portainer-1`, `github-runner-runner-1`)

## Consequences

**Positive**
- Single binary: `docker compose` is always available if Docker Engine is installed — no separate install step to go stale
- V2 is significantly faster than V1 for large compose files (Go vs Python startup)
- No V1/V2 command mismatch if a team member has Docker Desktop (which ships V2 only)
- `community.docker.docker_compose_v2` reports `changed` vs `ok` accurately based on container state, not just file presence

**Negative**
- Container naming changed: scripts that reference `projectname_service_1` (V1 style) will break. All our references use V2-style names (hyphens).
- `docker_compose_v2` Ansible module requires `community.docker >= 3.0.0` — already pinned in `requirements.yml`

## Code

### Installation (docker role)

```yaml
- name: Install Docker Engine and Compose plugin
  ansible.builtin.apt:
    name:
      - docker-ce
      - docker-ce-cli
      - containerd.io
      - docker-buildx-plugin
      - docker-compose-plugin    # ← V2 plugin, not python docker-compose
    state: present
    update_cache: true
```

### Ansible task usage

```yaml
- name: Pull latest image
  community.docker.docker_compose_v2_pull:
    project_src: /opt/portainer

- name: Start container
  community.docker.docker_compose_v2:
    project_src: /opt/portainer
    state: present
    recreate: auto
```

### Shell usage (diagnostics, deploy workflow)

```bash
docker compose pull
docker compose up -d --remove-orphans
docker compose ps
```
