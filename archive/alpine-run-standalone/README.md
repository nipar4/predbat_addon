This used to live at `predbat/rootfs/alpine/run.standalone.sh`.

It was copied into every `Dockerfile.alpine`/`.slim` image build (via `COPY rootfs/alpine/*
/addon/`, which grabs every file in that directory) but nothing ever executed it — the s6
`predbat` service's `run` script always execs `run.docker.sh`, never this one. No `CMD` override,
docs, or workflow referenced it as an alternative entrypoint.

It's the same *shape* as `rootfs/noble/run.standalone.sh` (which **is** live — it's
`Dockerfile.noble`'s only entrypoint, no s6 involved): copy files into `/config`, block on the
`template` gate, then loop `python3 startup.py` with a crash-restart. Reads like an abandoned
attempt at giving alpine/slim the same s6-free standalone mode noble already has, never finished or
wired up.

Kept here (not deleted) in case someone wants to pick that up properly - e.g. a documented `CMD`
override so alpine/slim can run without `/init`/s6. If nothing ever needs it, this directory can be
deleted outright.
