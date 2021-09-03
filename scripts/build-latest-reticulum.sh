export HAB_ORIGIN=raspberry-dream-labs
export HAB_BLDR_URL=https://bldr.biome.sh

git clone https://github.com/robert-rdl/biome-habitats.git

cd ./biome-habitats/plans

bio pkg build ./reticulum

bio pkg upload "$(ls -t /hab/cache/artifacts/raspberry-dream-labs-reticulum-1.0.1* | head -n1)"

bio pkg promote raspberry-dream-labs/reticulum/1.0.1/"$(ls -t /hab/cache/artifacts/raspberry-dream-labs-reticulum-1.0.1* | head -n1 | sed 's|.*reticulum\-1\.0\.1\-||g' | sed 's|\-.*||g')" stable

