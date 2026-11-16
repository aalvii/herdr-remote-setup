# Roles and access model

This page defines the three roles in a tailnet, the tag rules, the ACL shape, and
the steps to onboard and revoke a client.

The simple PIN flow in `docs/QUICKSTART.md` uses the same OpenSSH key transport
and the same ACL model. It changes the pairing UX, not the access model.

Related files:

- `docs/acl-policy.hujson` is a paste-ready policy example.
- `docs/ARCHITECTURE.md` covers the three layers and the connection code.
- `docs/TROUBLESHOOTING.md` covers failures.

---

## 1. Three roles

| Role | Meaning | Identity | Example machine |
|------|---------|----------|-----------------|
| **operator** | Your own machine, full access | Tailscale account, `tag:operator` in the multi-user phase | Your laptop, phone |
| **herdr-host** | Runs the herdr server for remote clients | `tag:herdr-host` | A Linux or macOS server |
| **client** | Connects to the herdr host only | `tag:client` | A customer PC |

A single-owner tailnet needs no tags. Every machine is yours, so
`autogroup:member` is enough. Use tags when other people join.

> **Transport limit.** These rules govern the network layer only. herdr's remote
> transport must use OpenSSH with a key, never Tailscale SSH. The bridge is
> wrapped by `tailscaled be-child ssh`, and surface activation fails. Keep
> `sudo tailscale set --ssh=false` on a herdr host. If you want Tailscale SSH for
> human logins, move the system sshd to another port and point herdr at
> `ssh://user@host:port`.

---

## 2. Why tags, not IPs or hostnames

| Identifier | Survives reboot | Survives node rebuild | Note |
|------------|:---:|:---:|------|
| 100.x address | usually | no, it can change | fallback in the connection code |
| Hostname | yes | collision may add `-1` | not used for authorization |
| Account (`autogroup:self`) | yes | yes | cannot group machines |
| Tag | yes | yes, if set at join time | the only machine group |

A tag sticks after a rebuild only when the auth key that joined the node carried
it. A tag added later in the console applies to the current node only.

```bash
tailscale up --authkey=tskey-auth-xxxxxxxxxxxx --advertise-tags=tag:client
```

---

## 3. Single-owner phase

```json
"grants": [
  { "src": ["autogroup:member"], "dst": ["*"], "ip": ["*"] }
]
```

Every member reaches every device. `autogroup:self` limits SSH to a member's own
devices.

`action: "accept"` needs no browser confirmation, so unattended jobs work.
`action: "check"` asks for a browser confirmation and breaks automation.

---

## 4. Multi-user phase

### 4.1 Tag machines

| Machine | Command |
|---------|---------|
| Each operator machine | `sudo tailscale up --advertise-tags=tag:operator` |
| The herdr host | `sudo tailscale up --advertise-tags=tag:herdr-host` |
| Each client | `tailscale up --authkey=tskey-auth-xxxxxxxxxxxx --advertise-tags=tag:client` |

Do not add `--ssh` to the herdr host. The clients reach it over OpenSSH.

### 4.2 Replace grants

```json
"grants": [
  { "src": ["tag:operator"], "dst": ["*"], "ip": ["*"] },
  { "src": ["tag:client"], "dst": ["tag:herdr-host"], "ip": ["tcp:22"] }
]
```

### 4.3 Optional human SSH rules

```json
"ssh": [
  {
    "action": "accept",
    "src": ["tag:operator"],
    "dst": ["tag:herdr-host"],
    "users": ["alice"]
  }
]
```

Replace `alice` with the login user on the host.

### 4.4 Access matrix

| Source | Target | Result |
|--------|--------|--------|
| operator | any device | allowed, all ports |
| operator | herdr host SSH | allowed, `alice` |
| client | herdr host SSH | allowed, `alice` |
| client | any other device | denied, no grant and no ssh rule |
| any member | own devices | allowed, SSH |

The client has no grant except the host, so it is isolated from everything else.
That isolation is the point of the tag model.

---

## 5. Policy structure

`docs/acl-policy.hujson` is a complete example.

```json
{
  "tagOwners": { "tag:herdr-host": ["autogroup:admin"] },
  "grants":    [ ... ],
  "ssh":       [ ... ]
}
```

The `ssh` section is separate from `grants`. A grant alone does not allow SSH.

---

## 6. Onboard a client

1. **Choose the share method**

   | Method | Use when | Action |
   |--------|----------|--------|
   | Join your tailnet | You manage the machine | Console, invite the user |
   | Device sharing | The client needs one host | Machines, host, Share |

   Device sharing is narrower. The client sees only the shared host and you do not
   need to change the ACL.

2. **Tag the client**, only for the join method:

   ```bash
   tailscale up --authkey=tskey-auth-xxxxxxxxxxxx --advertise-tags=tag:client
   ```

3. **Confirm the host transport**. OpenSSH must be running, and Tailscale SSH
   must be off:

   ```bash
   pgrep -x sshd
   tailscale debug prefs | grep RunSSH    # expect false
   ```

4. **Issue the connection code** on the host:

   ```bash
   ./host/provision.sh
   ```

   Send the code to the client. It contains no private key. It can contain a
   one-time Tailscale auth key and a one-time enrollment token, so treat it as a
   secret.

5. **Run the client**:

   ```powershell
   client\setup.cmd
   ```

   Or `app/Herdr-Setup.command` on macOS.

6. **Verify isolation**:

   ```bash
   # On the client: the host answers
   ssh -o BatchMode=yes alice@<herdr-host> "echo OK"

   # On the client: another device times out
   tailscale ping <other-device>
   ```

---

## 7. Revoke a client

| Method | Action | Effect |
|--------|--------|--------|
| Device sharing | Machines, Share, remove the user | immediate |
| Join method | Remove the user or the `tag:client` | immediate |
| Auth key | Admin, Keys, Revoke | new connections fail |
| herdr key | Remove the client line from `authorized_keys` | that key stops working |

The most complete removal is the user plus the device plus the key line.

---

## 8. Verification commands

```bash
# Host: SSH state
tailscale debug prefs | grep RunSSH
pgrep -x sshd

# Host: tags
tailscale status --json | grep -o '"Tags":\[[^]]*\]'

# Client: key transport
ssh -o BatchMode=yes alice@<herdr-host> "echo OK"

# Client: isolation
tailscale ping <other-device>
```

---

## 9. Security notes

| Item | Rule |
|------|------|
| `action` | Use `accept` only with a narrow tuple |
| Auth key | Single use, short expiry, tagged |
| Server node | Disable key expiry |
| Client tag | `tag:client` only, never `tag:operator` |
| Connection code | base64, not encryption. Treat it as a secret |
| Logs | `tskey-...` is redacted |
| herdr key | One key per client, remove it on revocation |

---

## 10. Common misconceptions

| Belief | Fact |
|--------|------|
| "A reboot changes Tailscale identity" | It does not. Losing `/var/lib/tailscale` does |
| "A console tag is permanent" | It applies to the current node only |
| "A grant allows SSH" | SSH needs its own `ssh` rule |
| "A tag grants access" | A matching `grants` or `ssh` rule is still required |
| "Device sharing needs an ACL change" | It does not, sharing is the grant |
