export HAB_ORIGIN=raspberry-dream-labs
export HAB_BLDR_URL=https://bldr.biome.sh

env
echo "changing directories"
cd ./biome-habitats/plans

echo "changing to root"
sudo su root

echo "packaging reticulum"
bio pkg build ./reticulum

echo "uploading reticulum"
bio pkg upload "$(ls -t /hab/cache/artifacts/raspberry-dream-labs-reticulum-1.0.1* | head -n1)"

echo "promoting reticulum"
bio pkg promote raspberry-dream-labs/reticulum/1.0.1/"$(ls -t /hab/cache/artifacts/raspberry-dream-labs-reticulum-1.0.1* | head -n1 | sed 's|.*reticulum\-1\.0\.1\-||g' | sed 's|\-.*||g')" stable

