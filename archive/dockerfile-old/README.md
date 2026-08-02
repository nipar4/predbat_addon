This used to live at `predbat/Dockerfile.old` — an Ubuntu/apt-based image predating the current
`Dockerfile.alpine`/`.noble`/`.slim` variants.

Its `CMD` was already commented out (`#CMD [ "/run.sh" ]`) before this move, so it had no working
entrypoint — building it as-is would silently inherit whatever `CMD`/`ENTRYPOINT` the base image
supplied via `BUILD_FROM`, which nothing in this repo sets for it. It isn't referenced by
`lint-build-boot-test.yml` or any other workflow, and its last touch (a "Slim and Alpine s6
changes" commit) looks incidental rather than a deliberate update.

Kept here (not deleted) in case there's a reason to revive it. If nothing ever needs it, this
directory can be deleted outright.
