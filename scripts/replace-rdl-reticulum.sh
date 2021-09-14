bio svc stop mozillareality/reticulum
bio svc unload mozillareality/reticulum
bio svc load raspberry-dream-labs/reticulum --strategy at-once --url https://bldr.biome.sh
bio svc start raspberry-dream-labs/reticulum
chgrp hab /hab/cache/keys/raspberry-dream-labs*pub
chown root:root /hab/svc/reticulum/files/*

