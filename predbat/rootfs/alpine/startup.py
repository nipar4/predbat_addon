import os
import subprocess
import sys
import time
print("Bootstrap Predbat")

root = "/config"

# Check if config exists, if not run locally
if not os.path.exists(root):
    root = "./"

# Predbat itself is baked into the image at build time (from a pinned commit);
# nothing is downloaded at runtime. run.docker.sh copies apps.yaml into place
# before this script runs, so a missing one is a setup error.
if not os.path.exists(os.path.join(root, "apps.yaml")):
    print("Error: {} not found, cannot start Predbat".format(os.path.join(root, "apps.yaml")))
    print("Sleep 5 minutes before restarting")
    time.sleep(5 * 60)
    sys.exit(1)

#
#  UPDATED by Nic
#
print("Startup")
subprocess.call([sys.executable, "/addon/hass.py"], cwd=root)

print("Shutdown, sleeping 20 seconds before restarting")
time.sleep(20)
