---
title: "The registry, the chart, and a real upstream bug"
part: 2 of 3 (revised from the original 2-part plan — this stage earned its own post)
---

# The registry, the chart, and a real upstream bug

Last time, the cluster came up: three nodes, `kubeadm`, Calico, MetalLB satisfying a
`LoadBalancer` Service with nothing but ARP behind it, and storage working two different ways.
This installment covers the next piece: getting a container image — something I built myself —
running inside that cluster. On paper that's the boring part. In practice it turned into the best
debugging story of the project so far.

## Why a cluster needs its own registry

A container image is just a packaged, deployable version of an application — code plus everything
it needs to run, bundled up. A *registry* is where those images live so a cluster can pull them
down when it needs to run them; it's the same idea as a private package repository, just for
containers instead of npm or pip packages. `docker pull nginx` works because Docker Hub is a
public registry doing exactly this.

On a real on-prem deployment — which is what this whole project is simulating — you can't lean on
a public registry for everything. Anything custom-built, internal, or sensitive needs somewhere
private to live, and that "somewhere" has to be something you stand up and secure yourself, since
there's no cloud provider handing you one. So: build a private registry, with real authentication,
running on the same infrastructure as everything else.

## The registry: a systemd unit, not a container

The project has stayed deliberately Docker-free throughout, so `docker run registry:2` — the usual
five-second way to get a registry running — was off the table on principle. It didn't turn out to
matter: the registry software ships as a plain, self-contained program, so it runs as an ordinary
background service (via `systemd`, the same thing that manages every other service on a Linux
box), with a self-signed certificate for encryption and a username/password for authentication
sitting in front of it. No container runtime needed at all just to host it.

## Building an image with no Docker in sight

The rest of the cluster runs on `containerd`, a lower-level piece of software that Docker itself is
actually built on top of — it's the thing that actually runs containers, whether or not Docker is
involved. So building an image used `nerdctl` (a Docker-compatible command-line frontend for
containerd) plus `buildkit` (the actual engine that turns a Dockerfile into an image) — same
Dockerfile syntax, same mental model as `docker build`, no Docker anywhere underneath it. Push the
finished image to the private registry over an encrypted connection, and for a while everything
looked completely routine.

## Where it got interesting: one tool works, another doesn't

Pulling that same image back down with `crictl` — the tool Kubernetes' own container runtime
interface actually uses, and the one you reach for on a node with no Docker installed — failed:

```
tls: failed to verify certificate: x509: certificate signed by unknown authority
```

On the *same machine*, against the *same registry*, with the *same trust configuration* that
`nerdctl` had just used successfully seconds earlier. That split is the whole story: if the
certificate setup itself were wrong, both tools would fail the same way. One succeeding and one
failing on an identical target means the certificate is fine, and something about *how the two
tools go about resolving the registry* is different.

The instinct at that point is to start changing things — re-copy files, second-guess the
configuration, restart services — and my first move was exactly that kind of instinct, not a clean
diagnosis. A few real findings and a couple of self-inflicted dead ends, in the order they actually
happened:

- My first check compared two different kinds of certificate against each other — the certificate
  authority's own fingerprint against the fingerprint of the specific certificate the registry was
  serving live — and they didn't match, which looked exactly like a stale-trust problem. It wasn't
  a valid comparison at all: a certificate authority and the certificate it signs are two different
  objects that will *always* have different fingerprints, even when everything is working
  correctly. I chased that false signal far enough to restart the registry service before catching
  the mistake, and the restart almost certainly changed nothing — `crictl` failed identically
  afterward. The actual, valid way to check "does this authority vouch for this certificate" is a
  cryptographic verification step, not a fingerprint comparison, and once I ran that, the answer
  came back clean immediately.
- Separately, comparing fingerprints computed on two different computers produced two
  visually different results for what was actually the identical certificate — Mac and Linux
  default to different hashing algorithms for that command, so of course the output looked
  different. A second, unrelated way to fool yourself with the exact same command.
- Turning up containerd's logging detail to see what it was actually doing internally was the
  right instinct — but the text-editing command I used to do it accidentally created a duplicate
  entry in its configuration file, which the config format doesn't allow. containerd refused to
  start. For about a minute, the node's container runtime was down (already-running pods kept
  running fine — they don't depend on the daemon staying up minute to minute — but nothing new
  could be scheduled there). Diagnosed the problem straight from the daemon's own refusal-to-start
  error message, fixed the duplicate entry, and it came back clean. Worth including rather than
  editing out: this is what a real debugging session looks like, mistakes included, and recovering
  from your own self-inflicted outage in under a minute is itself a useful skill.
- With detailed logging actually working, the line that mattered showed up immediately: containerd
  was routing this particular pull through something called the "transfer service" — a newer,
  redesigned pull pipeline that the Kubernetes-facing side of containerd uses by default, which
  turns out *not* to consult the same trust configuration that the older, `nerdctl`-facing pull
  mechanism does. Two different code paths inside the same program, nominally reading the same
  configuration, actually behaving differently.

A quick search turned up an existing bug report describing the exact same split on a different
containerd version — confirmation this wasn't something specific to this cluster, but a real,
currently-unfixed defect in a piece of software a lot of Kubernetes clusters depend on.

## The workaround, and giving something back

Since Kubernetes itself pulls images through the same broken path `crictl` uses, this wasn't just a
minor command-line annoyance — left alone, it would have blocked the actual application from ever
starting, no matter how correctly everything else was configured. The practical fix: pull the image
down through the route that still works, directly into the specific location containerd's
Kubernetes-facing side looks for images, so it finds it already there and never needs to attempt
its own broken pull.

Rather than just work around it quietly, I wrote up the full reproduction — what I set up, the
exact symptom, the diagnostic steps in order, and the workaround — and posted it on the existing
bug report, confirming it happens on a different version than the original report. Small thing, but
it's a real, public, checkable contribution: not just a workaround for myself, but a trail that
makes it easier for whoever fixes this next.

## The chart itself, almost an afterthought by comparison

After all that, actually writing a Helm chart was the calm part of the day. Helm is Kubernetes'
templating system — instead of hand-editing YAML files every time you deploy an application, you
write a template once with the configurable pieces (image name, replica count, resource limits)
pulled out into variables, and Helm fills those in per environment. Most people who've "used Helm"
have only ever installed someone else's chart; writing one from scratch — the template files, the
naming conventions, the default values — is a different, more useful skill. Checked the output
carefully before ever touching the live cluster, then did a real trial-run install that shows
exactly what Helm resolves without actually deploying anything, before committing to the real
thing.

## Next up

Two stages left: putting the cluster through an actual version upgrade, taking — and restoring
from — a real backup of the cluster's core datastore after deliberately destroying something,
adding and cleanly removing a node, and then a deliberate round of breaking things on purpose just
to time how fast I can find and fix them. That's where the deepest, most interview-relevant
material lives, and after this stage, I'm not worried about running out of real stories to tell.
