# Read-only T1 preflight

Run `apple-ib-drv-preflight` explicitly, without sudo. It prints JSON and never
loads/unloads modules, binds/unbinds drivers, configures USB, changes power
policy, accesses firmware, or starts a service. It is not called by package
hooks, modules-load or udev. Existing automatic loading is unchanged.

| Exit | JSON status | Meaning |
|---|---|---|
| 0 | `checks-passed` | One production USB candidate in configuration 1, physical HID descendants and allowed observed owners, with no observed conflicting stack. |
| 1 | `refused` | A candidate exists but the documented checks reject its state; inspect `reasons`. |
| 2 | `unavailable` | Required state is missing, unreadable, malformed or changed between observations. |
| 3 | `not-applicable` | No production/recovery USB candidate was observed on the readable buses. |

Exit 0 is **not permission to hand over a device**, a functional test or a model
support claim. No caller currently uses this result to gate automatic loading.
Missing virtual HID children or unloaded modules need not indicate failure at
this diagnostic stage; the tool does not certify a working Touch Bar/Fn handler.

The production identity is USB `05ac:8600`. Apple `05ac:1281` is reported as a
recovery *candidate*, not proof of a particular device's firmware health. HID
nodes must descend from the selected production USB device; virtual
`1d6b:0301` nodes must also descend from its physical `05ac:8600` HID. Other
devices are not treated as targets. Expected driver names are those of this
package's pinned stack, not `apple-ib-tb`/`apple-ib-als`.

Owners may be unbound, `hid-generic`, `hid-sensor-hub`, or the expected driver
for that HID level. These are observed states only; allowing an owner in this
report does not authorize displacing it. A loaded bridge must expose enabled
`skip_acpi_power`. DMI is informational, without a MacBookPro14,3-only gate.
Fn mode, idle/dim timeouts and wake policy are neither required nor changed.

Two observations compare USB path/inode/devnum/configuration, descendant HID
identity/owners and relevant module state. This detects some races, not all:
sysfs is not atomic and state can change immediately afterward. Any future
mutating consumer must revalidate its target and define recovery separately.
Required missing attributes are unavailable, not silently false/disabled.

This extracts the identity/ancestry/ownership ideas from angellindo's reference
helper at `c06bcaa` in response to
[the #298 discussion](https://github.com/omacom/omarchy-pkgs/pull/298#issuecomment-5751453105).
It deliberately has no start operation or rollback claim. Late loading/HID
handover belongs in a separate opt-in proposal with complete failed-start
outcomes, including recovery failures and reenumeration.

`python3 -I -B test_preflight.py` exercises synthetic sysfs; no real device is
needed during package checks. Fixtures validate decisions and absence of
operations, not hardware functionality. Build, package transactions, boot and
physical controls/camera validation must be reported separately for each kernel
and model. No new suspend, power-consumption or generic model support claim is
made by this diagnostic tool.
