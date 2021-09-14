#!/usr/bin/env bash

echo "Beginning Polycosm Boot."

systemctl stop bio

INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
PRIVATE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone | sed 's/[a-z]$//')

export HAB_BLDR_URL="https://bldr.reticulum.io"

# AWS role can take time to be applied, keep running AWS commands until success.
until aws ec2 describe-instances --region $REGION --instance-ids $INSTANCE_ID
do
  echo "Waiting for EC2 read permission."
  sleep 5
done

EC2_INFO=$(aws ec2 describe-instances --region $REGION --instance-ids $INSTANCE_ID)
STACK_NAME=$(echo "$EC2_INFO" | jq -r ".Reservations | map(.Instances) | flatten | .[] | select(.InstanceId == \"$INSTANCE_ID\") | .Tags | .[]? | select(.Key == \"aws:cloudformation:stack-name\") | .Value ")
STACK_ID=$(echo "$EC2_INFO" | jq -r ".Reservations | map(.Instances) | flatten | .[] | select(.InstanceId == \"$INSTANCE_ID\") | .Tags | .[]? | select(.Key == \"aws:cloudformation:stack-id\") | .Value ")
ROLES=$(echo "$EC2_INFO" | jq -r ".Reservations | map(.Instances) | flatten | .[] | select(.InstanceId == \"$INSTANCE_ID\") | .Tags | .[]? | select(.Key == \"polycosm-roles\") | .Value ")

until aws sts --region $REGION get-caller-identity
do
  echo "Waiting for account read permission."
  sleep 5
done

ACCOUNT_ID=$(aws sts --region $REGION get-caller-identity | jq -r ".Account")

# AWS role can take time to be applied, keep running AWS commands until success.
until aws cloudformation describe-stacks --region $REGION --stack-name $STACK_NAME
do
  echo "Waiting for stack read permission."
  sleep 5
done

# Wait until stack outputs are ready
until aws cloudformation describe-stacks --region $REGION --stack-name $STACK_NAME | jq -r ".Stacks | .[] | .Outputs" | grep -v null
do
  echo "Waiting for stack outputs."
  sleep 30
done

STACK_INFO=$(aws cloudformation describe-stacks --region $REGION --stack-name $STACK_NAME)
STORAGE_EFS_ID=$(echo "$STACK_INFO" | jq -r ".Stacks | .[] | .Outputs | .[] | select(.OutputKey == \"StorageEFSId\") | .OutputValue")
HOSTED_ZONE_ID=$(echo "$STACK_INFO" | jq -r ".Stacks | .[] | .Outputs | .[] | select(.OutputKey == \"InternalZoneId\") | .OutputValue")
HOSTED_ZONE_NAME=$(echo "$STACK_INFO" | jq -r ".Stacks | .[] | .Outputs | .[] | select(.OutputKey == \"InternalZoneDomainName\") | .OutputValue")
BOX_KEYS_BUCKET_NAME=$(echo "$STACK_INFO" | jq -r ".Stacks | .[] | .Outputs | .[] | select(.OutputKey == \"BoxKeysBucketName\") | .OutputValue")
BOX_KEYS_BUCKET_REGION=$(echo "$STACK_INFO" | jq -r ".Stacks | .[] | .Outputs | .[] | select(.OutputKey == \"BucketRegion\") | .OutputValue")
SES_REGION=$(echo "$STACK_INFO" | jq -r ".Stacks | .[] | .Outputs | .[] | select(.OutputKey == \"SESRegion\") | .OutputValue")
ASSETS_DOMAIN=$(echo "$STACK_INFO" | jq -r ".Stacks | .[] | .Outputs | .[] | select(.OutputKey == \"AssetsDomain\") | .OutputValue")

EXISTING_IP=""
INSTANCE_NAME=""

mkdir -p /var/lib/polycosm

echo $STACK_NAME > /var/lib/polycosm/stack_name
echo $STACK_ID > /var/lib/polycosm/stack_id
echo $ACCOUNT_ID > /var/lib/polycosm/account_id

attempt_generate_hostname() {
  ADJECTIVE=$(cat /usr/share/dict/hostname-adjectives | shuf | head -n1)
  NOUN=$(cat /usr/share/dict/hostname-nouns | shuf | head -n1)

  INSTANCE_NAME="${ADJECTIVE}-${NOUN}"
  DNS_IP=$(dig $INSTANCE_NAME.$HOSTED_ZONE_NAME A +short)

  if [[ ! -z "$DNS_IP" ]] ; then
    EXISTING_IP=$(aws ec2 --region $REGION describe-instances --no-paginate | grep $DNS_IP)
  fi
}

attempt_generate_hostname

while [[ ! -z $EXISTING_IP ]]
do
  attempt_generate_hostname
done

echo "Setting hostname to ${INSTANCE_NAME}"

HOSTNAME="$INSTANCE_NAME.$HOSTED_ZONE_NAME"
LOCAL_HOSTNAME="${INSTANCE_NAME}-local.${HOSTED_ZONE_NAME}"
hostname $HOSTNAME
echo "$HOSTNAME" > /etc/hostname
echo "$HOSTNAME" > /var/lib/polycosm/hostname
echo "$LOCAL_HOSTNAME" > /var/lib/polycosm/local-hostname
echo "$HOSTED_ZONE_ID" > /var/lib/polycosm/host-hosted-zone-id
service rsyslog restart

ROUTE53_PRIVATE_RECORD="{ \"ChangeBatch\": { \"Changes\": [ { \"Action\": \"UPSERT\", \"ResourceRecordSet\": { \"Name\": \"${LOCAL_HOSTNAME}.\", \"Type\": \"A\", \"TTL\": 900, \"ResourceRecords\": [ { \"Value\": \"$PRIVATE_IP\" } ] } } ] } }"

# AWS role can take time to be applied, keep running AWS commands until success.
if [[ ! $PUBLIC_IP == *"404"* ]] ; then
  ROUTE53_PUBLIC_RECORD="{ \"ChangeBatch\": { \"Changes\": [ { \"Action\": \"UPSERT\", \"ResourceRecordSet\": { \"Name\": \"${HOSTNAME}.\", \"Type\": \"A\", \"TTL\": 900, \"ResourceRecords\": [ { \"Value\": \"$PUBLIC_IP\" } ] } } ] } }"

  until aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" --cli-input-json "${ROUTE53_PUBLIC_RECORD}"
  do
    echo "Retrying DNS update"
  done
fi

until aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" --cli-input-json "${ROUTE53_PRIVATE_RECORD}"
do
  echo "Retrying tag update"
done

until aws ec2 create-tags --region $REGION --resources "${INSTANCE_ID}" --tags "Key=Name,Value=${INSTANCE_NAME}"
do
  echo "Retrying tag update"
done

mkdir -p /tmp/box-keys
until aws s3 sync --region $BOX_KEYS_BUCKET_REGION s3://${BOX_KEYS_BUCKET_NAME} /tmp/box-keys
do
  echo "Retrying key sync update"
done

# Set up 2FA
mv /tmp/box-keys/ssh-totp.cfg ~ubuntu/.google_authenticator
chmod 0600 ~ubuntu/.google_authenticator
chown ubuntu:ubuntu ~ubuntu/.google_authenticator
systemctl restart sshd.service

# Move QR code file
mkdir -p /hab/svc/ita/files
mv /tmp/box-keys/ssh-totp-qr.url /hab/svc/ita/files

# Copy Janus JWT file
mkdir -p /hab/svc/janus-gateway/files
cp /tmp/box-keys/jwt-pub.der /hab/svc/janus-gateway/files/perms.pub.der
chown -R hab:hab /hab/svc/janus-gateway/files

# Copy PostgREST JWT file
mkdir -p /hab/svc/postgrest/files
cp /tmp/box-keys/jwt-pub.json /hab/svc/postgrest/files/jwk.json
chown -R hab:hab /hab/svc/postgrest/files

# Remove non-bio keys
rm /tmp/box-keys/jwt*
rm /tmp/box-keys/vapid.json

# Set up bio keys
find /tmp/box-keys -type f -exec /opt/polycosm/mv_bio_key_to_cache.sh {} \;
chown -R root:hab /hab/cache/keys
chmod g+r /hab/cache/keys/*

# Supervisor communication key needs to be readable by ita
mkdir -p /hab/sup/default
echo $(bio sup secret generate) > /hab/sup/default/CTL_SECRET
chown root:hab /hab/sup/default
chown root:hab /hab/sup/default/CTL_SECRET
chmod 0750 /hab/sup/default
chmod 0640 /hab/sup/default/CTL_SECRET

systemctl restart systemd-sysctl.service

# Mount EFS
mkdir /storage
echo "${STORAGE_EFS_ID}.efs.${REGION}.amazonaws.com:/       /storage        nfs     nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=3,noresvport" >> /etc/fstab
mount /storage
chown hab:hab /storage

# Populate user.toml files
mkdir -p /hab/user/reticulum/config
mkdir -p /hab/user/janus-gateway/config
mkdir -p /hab/user/coturn/config
mkdir -p /hab/user/certbot/config
mkdir -p /hab/user/ita/config

mkdir -p /hab/svc/reticulum/files
mkdir -p /hab/svc/janus-gateway/files
mkdir -p /hab/svc/coturn/files
mkdir -p /hab/svc/pgbouncer/files
mkdir -p /hab/svc/certbot/logs

cat > /hab/user/ita/config/user.toml << EOTOML
[general]
host = "127.0.0.1"
port = 6000
server_domain = "$HOSTED_ZONE_NAME"
assets_domain = "$ASSETS_DOMAIN"

[aws]
region = "$REGION"
ses_region = "$SES_REGION"
stack_id = "$STACK_ID"
stack_name = "$STACK_NAME"
account_id = "$ACCOUNT_ID"
server_domain = "$HOSTED_ZONE_NAME"
assets_domain = "$ASSETS_DOMAIN"

[hab]
org = "$STACK_NAME"
http_host = "127.0.0.1"
sup_host = "127.0.0.1"
command = "bio"
user = "polycosm-config-user"
EOTOML

cat > /hab/user/certbot/config/user.toml << EOTOML
[general]
domain = "$HOSTNAME,$STACK_NAME-app.$HOSTED_ZONE_NAME"
EOTOML

cat > /hab/user/janus-gateway/config/user.toml << EOTOML
[transports.http]
admin_ip = "$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)"
EOTOML

cat > /hab/user/coturn/config/user.toml << EOTOML
[general]
listening_ip = "0.0.0.0"
external_ip = "$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)"
relay_ip = "$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)"
allowed_peer_ip = "$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)"
EOTOML

cat > /hab/svc/pgbouncer/files/users.txt << EOF
"postgres" "postgres"
EOF

# Add crons

# Restart Janus + Coturn every night for stability
if [[ $ROLES == "stream" || $ROLES == "app,stream" ]] ; then
  cat > /etc/cron.d/janus-restart << EOCRON
0 10 * * * hab PID=\$(head -n 1 /hab/svc/janus-gateway/var/janus-self.pid) ; kill \$PID ; sleep 10 ; kill -0 \$PID 2> /dev/null && kill -9 \$PID
EOCRON
  cat > /etc/cron.d/coturn-restart << EOCRON
0 10 * * * hab PID=\$(head -n 1 /hab/svc/coturn/var/turnserver.pid) ; kill \$PID ; sleep 10 ; kill -0 \$PID 2> /dev/null && kill -9 \$PID
EOCRON
fi

# Restart reticulum once a month to ensure new SSL cert is picked up
if [[ $ROLES == "app" || $ROLES == "app,stream" ]] ; then
  cat > /etc/cron.d/ret-restart << EOCRON
0 11 15 * * hab /usr/bin/bio svc stop raspberry-dream-labs/reticulum ; while ! /usr/bin/bio sup status raspberry-dream-labs/reticulum | tail -n 1 | awk '{ print \$4 }' | grep down ; do sleep 1 ; done ; /usr/bin/bio svc start raspberry-dream-labs/reticulum
EOCRON
fi

# Clean Mozilla biome packages and cache (note transitive dependencies will incrementally increase)
cat > /etc/cron.d/bio-pkg-cleanup << EOCRON
0 12 * * * root find /hab/pkgs/mozillareality -mindepth 1 -maxdepth 1 -exec sh -c 'ls {} -1Ntr | head -n -1 | xargs -IDIR rm -rf {}/DIR' \; ; find /hab/pkgs/mozillareality -mindepth 2 -maxdepth 2 -exec sh -c 'ls {} -1Ntr | head -n -1 | xargs -IDIR rm -rf {}/DIR' \; ; rm -rf /hab/cache/artifacts/mozillareality-*
EOCRON

/etc/init.d/cron reload

# Add log rate limiting and size limit
sed -i "s/#RateLimitBurst=1000/RateLimitBurst=5000/" /etc/systemd/journald.conf
sed -i "s/#SystemMaxUse=/SystemMaxUse=128M/" /etc/systemd/journald.conf
systemctl restart systemd-journald

# symlink SSL certs
ln -s /hab/svc/certbot/data/live/$HOSTNAME/chain.pem /hab/svc/reticulum/files/ssl-chain.pem
ln -s /hab/svc/certbot/data/live/$HOSTNAME/privkey.pem /hab/svc/reticulum/files/ssl.key
ln -s /hab/svc/certbot/data/live/$HOSTNAME/cert.pem /hab/svc/reticulum/files/ssl.pem

ln -s /hab/svc/certbot/data/live/$HOSTNAME/privkey.pem /hab/svc/janus-gateway/files/dtls.key
ln -s /hab/svc/certbot/data/live/$HOSTNAME/cert.pem /hab/svc/janus-gateway/files/dtls.pem
ln -s /hab/svc/certbot/data/live/$HOSTNAME/fullchain.pem /hab/svc/janus-gateway/files/wss.pem
ln -s /hab/svc/certbot/data/live/$HOSTNAME/privkey.pem /hab/svc/janus-gateway/files/wss.key

ln -s /hab/svc/certbot/data/live/$HOSTNAME/cert.pem /hab/svc/coturn/files/turn.pem
ln -s /hab/svc/certbot/data/live/$HOSTNAME/privkey.pem /hab/svc/coturn/files/turn.key

# Flush permissions and start services
chown -R hab:hab /hab/svc/certbot
chown -R hab:hab /hab/svc/reticulum/files
chown -R hab:hab /hab/svc/janus-gateway/files
chown -R hab:hab /hab/svc/coturn/files

# Touch signal file which will allow bio to start
touch /var/lib/polycosm/ready

echo "Waiting for bio."
systemctl start bio

while ! nc -z localhost 9632 ; do
  sleep 1
done # Wait for bio

systemctl enable bio

/usr/bin/bio pkg install raspberry-dream-labs/reticulum --url https://bldr.biome.sh

if [[ $ROLES == "app" || $ROLES == "app,stream" ]] ; then
  echo "Loading app services."
  /usr/bin/bio svc start mozillareality/ita

  echo "Waiting for ita."
  while [ ! -f /hab/svc/ita/var/ready ]; do sleep 1; done

  /usr/bin/bio svc start mozillareality/polycosm-static-assets
  echo "Waiting for polycosm assets."
  while [ ! -f /hab/svc/polycosm-static-assets/var/dist/assets/assets/pages/unavailable.html ]; do sleep 1; done
fi

echo "Waiting for certs."

sleep 2

# Use a shared NFS advisory lock to serialize certificate challenges
# Certbot has a hard time wrangling DNS if multiple nodes are gettng challenged at once.
#
# Also perform the necessary filesystem operations to restore from AWS backup in the critical section.
(
  flock 9 || exit 1

  /usr/bin/bio svc start mozillareality/certbot

  # Wait for certificates for 5 minutes before starting services
  for i in $(seq 1 300); do [ -f /hab/svc/certbot/data/live/$HOSTNAME/privkey.pem ] && break || sleep 1; done

  mv /storage/aws-backup-lost+found* /storage/lost+found
  mv /storage/aws-backup-restore*/* /storage
  rm -rf /storage/aws-backup-restore*

) 9>/storage/certbot-lock

echo "Unloading mozillareality/reticulum"
/usr/bin/bio svc unload mozillareality/reticulum

/usr/bin/bio svc start mozillareality/pgbouncer
echo "Waiting for pgBouncer."
while ! nc -z localhost 5432 ; do sleep 1; done

echo "Waking up the database."
PGPASSWORD=postgres psql -hlocalhost -Upostgres polycosm_production -c "select 1"

# Start services for this node's roles
if [[ $ROLES == "stream" ]] ; then
  echo "Starting stream services."
  /usr/bin/bio svc start mozillareality/janus-gateway

  echo "Waiting for Janus."
  while ! nc -z localhost 8443 ; do sleep 1; done

  echo "Starting TURN services."
  /usr/bin/bio svc start mozillareality/coturn

  echo "Waiting for Coturn."
  while ! nc -z localhost 5349 ; do sleep 1; done
fi

if [[ $ROLES == "app" || $ROLES == "app,stream" ]] ; then
  echo "Starting app clients."

  /usr/bin/bio svc start mozillareality/hubs
  echo "Waiting for Hubs."
  while [ ! -f /hab/svc/hubs/var/dist/pages/index.html ]; do sleep 1; done

  /usr/bin/bio svc start mozillareality/spoke
  echo "Waiting for Spoke."
  while [ ! -f /hab/svc/spoke/var/dist/pages/index.html ]; do sleep 1; done

  # Start Janus to prevent reticulum from error spamming,
  # then start reticulum to ensure coturn database is up,
  # then start coturn.

  if [[ $ROLES == "app,stream" ]] ; then
    echo "Starting stream services."
    /usr/bin/bio svc start mozillareality/janus-gateway

    echo "Waiting for Janus."
    while ! nc -z localhost 8443 ; do sleep 1; done
  fi

  echo "Starting app services."

  /usr/bin/bio svc load raspberry-dream-labs/reticulum --strategy at-once
  /usr/bin/bio svc start raspberry-dream-labs/reticulum
  echo "Waiting for Reticulum."
  while ! curl -k "https://localhost:4000/health" ; do sleep 1; done

  /usr/bin/bio svc start mozillareality/postgrest
  echo "Waiting for PostgREST."
  while ! curl "http://localhost:3000" ; do sleep 1; done

  /usr/bin/bio svc start mozillareality/youtube-dl-api-server
  echo "Waiting for YT-DL."
  while ! curl "http://localhost:8080/api/version" ; do sleep 1; done

  if [[ $ROLES == "app,stream" ]] ; then
   echo "Starting TURN services."
    /usr/bin/bio svc start mozillareality/coturn

    echo "Waiting for Coturn."
    while ! nc -z localhost 5349 ; do sleep 1; done
  fi
fi

if [[ $ROLES == "app" || $ROLES == "app,stream" ]] ; then
  python2 /usr/local/bin/cfn-signal -e $? --stack $STACK_NAME --resource AppASG --region $REGION
fi

if [[ $ROLES == "stream" ]] ; then
  python2 /usr/local/bin/cfn-signal -e $? --stack $STACK_NAME --resource StreamASG --region $REGION
fi
