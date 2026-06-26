# Don't want to spend $$ on GitHub runners? Add a Docker dashboard — without opening a new port

> **Vendor angle:** Ansible, roles, idempotency, community.docker, SSH tunnels
> **Companion posts:** [GitHub side](./01-github-self-hosted-runners.md) · [Terraform side](./02-terraform-for-vps-inventory.md) · [Idempotent provisioning](./03-ansible-idempotent-vps-provisioning.md)

The VPS was running. The GitHub Actions runner was registered. Deployments were landing. Everything was working — and completely invisible unless you SSHed in and ran `docker ps` by hand.

That's the gap Portainer fills. It's a web UI that runs as a Docker container and gives you everything: running containers, logs, exec shell, image management, Compose stack control. This post is about how we added it as a proper Ansible role — idempotent, code-reviewed, provisioned the same way as everything else.

---

## Why add it through Ansible at all?

You could `docker run` Portainer manually once and call it done. But then:

- The next `provision.yml` run doesn't know Portainer exists
- If the VPS is replaced, Portainer isn't restored
- There's no record of *why* port binding decisions were made

The playbook is the recovery path (see [ADR-0008](../adr/0008-idempotent-playbook-design.md)). If it's not in a role, it doesn't exist.

---

## The role structure

We follow the same pattern as the existing `github_runner` role:

1. Create the directory
2. Template the `docker-compose.yml`
3. Pull the image
4. Start (or recreate) the container

```
roles/portainer/
├── defaults/main.yml
├── handlers/main.yml
├── tasks/main.yml
└── templates/
    └── docker-compose.yml.j2
```

### defaults/main.yml

```yaml
---
portainer_dir: /opt/portainer
```

One variable: where to put the compose file. Using a default means any playbook can override it without touching the role.

### tasks/main.yml

```yaml
---
- name: Create portainer directory
  ansible.builtin.file:
    path: "{{ portainer_dir }}"
    state: directory
    owner: root
    group: root
    mode: "0755"

- name: Write portainer docker-compose.yml
  ansible.builtin.template:
    src: docker-compose.yml.j2
    dest: "{{ portainer_dir }}/docker-compose.yml"
    mode: "0644"
  register: _compose_changed

- name: Pull latest Portainer image
  community.docker.docker_compose_v2_pull:
    project_src: "{{ portainer_dir }}"

- name: Start (or recreate if config changed) Portainer container
  community.docker.docker_compose_v2:
    project_src: "{{ portainer_dir }}"
    state: present
    recreate: auto
  notify: Verify portainer container
```

Three things worth noting:

**`community.docker.docker_compose_v2`** — not `ansible.builtin.shell: docker compose up`. Using the module means Ansible understands the container's desired state and can report `changed` vs `ok` accurately. `recreate: auto` only restarts the container if the compose file or image changed.

**`docker_compose_v2_pull`** — pulls the image separately before starting. This means image updates are applied on every provisioning run without changing the container definition.

**`notify: Verify portainer container`** — the handler checks that the container is actually `running` after startup. If Portainer crashes on start (bad config, port conflict), the play fails loudly instead of silently.

### templates/docker-compose.yml.j2

```yaml
services:
  portainer:
    image: portainer/portainer-ce:latest
    restart: unless-stopped
    ports:
      - "127.0.0.1:9443:9443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data

volumes:
  portainer_data:
```

The critical line: `127.0.0.1:9443:9443`. This binds Portainer to the loopback interface only — it is **not** accessible from the internet. See the next section for why.

---

## The security decision: loopback + SSH tunnel

Opening port 9443 in UFW would expose Portainer's login page to the internet. Even with strong credentials, that's an extra attack surface on a VPS that otherwise only accepts SSH, HTTP, and HTTPS.

The alternative: bind Portainer to `127.0.0.1` and reach it through an SSH tunnel.

```bash
ssh -L 9443:localhost:9443 <user>@<vps_ip> -N
```

This forwards your local `9443` through the SSH connection to the VPS's `localhost:9443` — where Portainer is listening. Open `https://localhost:9443` in your browser and you're in.

To make this seamless, add `LocalForward` to `~/.ssh/config`:

```sshconfig
Host hcw-vps
  HostName <YOUR_VPS_IP>
  User <YOUR_VPS_USER>
  IdentityFile ~/.ssh/hcw_vps_key
  LocalForward 9443 localhost:9443
  AddKeysToAgent yes
  ServerAliveInterval 60
  ServerAliveCountMax 3
```

Now every SSH connection — including VS Code Remote-SSH — automatically opens the tunnel. Portainer is always one `https://localhost:9443` away when you're connected to the VPS, with zero extra steps.

**The security posture is unchanged:** access still requires an SSH private key. No new firewall rules, no new public ports, no additional credential surface.

---

## Adding the role to site.yml

```yaml
---
- name: Provision VPS
  hosts: vps
  become: true
  gather_facts: true

  roles:
    - common          # system updates, UFW, SSH hardening
    - docker          # Docker Engine + Compose plugin
    - portainer       # Portainer CE for Docker visibility
    - github_runner   # runner as Docker container
    - kubernetes      # kind, k3d, kubectl, helm
```

`portainer` goes after `docker` (Docker must be running) and before `github_runner` (order doesn't technically matter after that, but this groups infrastructure before application containers).

---

## Idempotency check

Re-run the play against a fully-converged VPS:

```
PLAY RECAP
vps : ok=18  changed=0  unreachable=0  failed=0
```

`changed=0` means:
- Directory already exists — `ok`
- `docker-compose.yml` content unchanged — `ok`
- Image already pulled — `ok`
- Container already running with correct config — `ok`

That's the target. The handler only fires on `changed`, so `Verify portainer container` only runs when something actually needed updating.

---

## First-run gotcha: the 5-minute window

Portainer has a security timeout on the initial admin account creation. If you don't create the account within 5 minutes of the container starting, Portainer locks itself down and requires a restart to reset.

```bash
# If you miss the window:
docker restart portainer-portainer-1
# You now have another 5 minutes
```

After the account is created, this timeout never applies again.

---

## What you get

Once provisioned and tunneled in:

- **Dashboard** — container count, running status, image sizes, volume usage
- **Containers** — `docker ps` equivalent, but with one-click log streaming, exec shell, start/stop/restart
- **Stacks** — manage your Compose projects; edit `docker-compose.yml` directly in the UI if needed
- **Images** — see what's pulled, pull new ones, prune unused
- **Volumes** — inspect named volumes, see which containers use them

Everything you'd do with `docker` CLI, in a browser, available any time you have SSH access to the VPS.

---

## Next steps

- **Pin the Portainer image version** (`portainer/portainer-ce:2.x.x`) if you want to control upgrade timing
- **Add a vps-diagnostics check** for Portainer container status (already in our `vps-diagnostics.yml`)
- **Consider Portainer Agent** if you later manage multiple Docker hosts — Portainer CE can connect to remote agents without exposing the Docker socket over the network
