#!/bin/sh
set -e

echo "[predbat] Docker startup"

# Prepare config
if [ -z "$(ls -A /config)" ]; then
    echo "/config directory is empty, copying files"
    cp -v /addon/apps.yaml /config/
else
    if [ ! -f /config/apps.yaml ]; then
        cp -v /addon/apps.yaml /config/
    fi
fi

# Block until config is valid
while grep -q "^[^#]*template: true" /config/apps.yaml; do
    echo "#################################################"
    echo "Please update apps.yaml"
    echo "Remove 'template: True'"
    echo "#################################################"
    sleep 30
done

# Predbat's web login is off unless apps.yaml sets web_username/web_password:
# say so, without printing any values (D13). Predbat's own code is unchanged.
if ! grep -Eq '^[[:space:]]*web_(username|password):[[:space:]]*[^[:space:]#]' /config/apps.yaml; then
    echo "#################################################"
    echo "WARNING: the Predbat web interface (port 5052) has no login."
    echo "Anyone who can reach the port can change Predbat's settings."
    echo "Set web_username and web_password in apps.yaml, see"
    echo "https://springfall2008.github.io/batpred/apps-yaml/#web-interface"
    echo "#################################################"
fi

echo "[predbat] Starting Predbat"

# Startup
exec python3 /addon/startup.py
