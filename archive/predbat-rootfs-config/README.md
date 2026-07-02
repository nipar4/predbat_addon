These files used to live at `predbat/rootfs/config/{apps.yaml,secrets.yaml}`.

They are not referenced by any Dockerfile in this repo. The `/addon/apps.yaml` that
`rootfs/alpine/run.docker.sh` / `run.standalone.sh` actually copy into `/config` on first boot comes
from upstream `batpred`'s own `apps/predbat/config/apps.yaml`, vendored in via the
`ADD https://github.com/springfall2008/batpred.git#$PREDBAT_VERSION:apps/predbat/config/ ...` line in
`Dockerfile.alpine`/`.slim`.

Kept here (not deleted) in case they turn out to be needed by a Dockerfile variant this audit missed.
If nothing ever needs them, this directory can be deleted outright.
