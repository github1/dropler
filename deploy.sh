#!/usr/bin/env bash

if [ -f ".env" ]; then
  source .env
fi

if [ -z "$DIGITALOCEAN_TOKEN" ]; then
  echo 'missing required env variable DIGITALOCEAN_TOKEN'
  exit 1
fi

ACTION=$1;shift
NAME=$(basename "${SCRIPT_PATH}")
WORKING_DIR=$(pwd -P)
LOCAL=false

while getopts d:n:,l flag; do
  case $flag in
  d)
    WORKING_DIR=$OPTARG
    ;;
  n)
    NAME=$OPTARG
    ;;
  l)
    LOCAL="true"
    ;;
  ?)
    ACTION="help"
    ;;
  esac
done

if [ ! -d "${WORKING_DIR}" ]; then
  echo "supplied dir not found - ${WORKING_DIR}"
  exit 1
fi

if [ -z "${NAME}" ]; then
  NAME=$(basename "$WORKING_DIR")
fi

SSH_KEY_NAME="${NAME}_ssh"

help() {
  echo "dropler"
  echo ""
  echo "usage:"
  echo "  deploy.sh [COMMAND] [OPTS]"
  echo ""
  echo "options:"
  echo "  -d         set the dir to upload from"
  echo "  -n         set the droplet name"
  echo ""
  echo "commands:"
  echo "  up         creates a DigitalOcean droplet"
  echo "  provision  runs docker-compose on the droplet if present"
  echo "  status     shows the status of the droplet and ipv4 address"
  echo "  down       destroys the droplet"
  echo "  ssh        connects to the droplet via SSH"
  exit 0
}

deployAction() {
  createKey
  SSH_PUB_KEY_ID=$(getKeyID)
  if [ "$SSH_PUB_KEY_ID" == "null" ]; then
    exit 1
  fi
  if [ "$(status)" == "down" ]; then
    curl -s -X POST -H "Content-Type: application/json" \
    -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" \
    -d '{"name":"'"$NAME"'","region":"nyc3","size":"1gb","image":"docker","ssh_keys":["'"$SSH_PUB_KEY_ID"'"],"tags":["'"$NAME"'"]}' \
    "https://api.digitalocean.com/v2/droplets" | jq
  fi

  n=0
  until [ $n -ge 30 -o "$(status)" == "active" ]; do
    echo "current status: $(status)"
    n=$[$n+1]
    sleep 1
  done

  if [ "$(status)" != "active" ]; then
    echo "failed to start"
  else
    echo "provisioning"
    provisionAction
    statusAction
  fi
}

provisionAction() {
  IP_ADDR=$(ipv4)
  until nc -zvw 1 ${IP_ADDR} 22; do
    sleep 2
  done
  read -r -d "" PROVISION <<EOF
if [ -f "/${NAME}/docker-compose.yml" ]; then
  if docker-compose -v > /dev/null; then
    echo "found docker-compose"
  else
    sudo curl -o /usr/local/bin/docker-compose -L "https://github.com/docker/compose/releases/download/1.15.0/docker-compose-\$(uname -s)-\$(uname -m)"
    sudo chmod +x /usr/local/bin/docker-compose
    docker-compose -v
  fi
  source /${NAME}/.env
  docker-compose -f /${NAME}/docker-compose.yml up
else
  echo "/${NAME}/docker-compose.yml not found"
fi
EOF
  ssh root@${IP_ADDR} -oStrictHostKeyChecking=no -i /tmp/${SSH_KEY_NAME} -t "rm -rf /$NAME && mkdir -p /$NAME"
  rsync -Pav --include='.env' --exclude='.git/' --filter='dir-merge,- .gitignore' -e "ssh -oStrictHostKeyChecking=no -i /tmp/$SSH_KEY_NAME" ${WORKING_DIR} root@${IP_ADDR}:/
  ssh root@${IP_ADDR} -oStrictHostKeyChecking=no -i /tmp/${SSH_KEY_NAME} -t "$PROVISION"
}

statusAction() {
  echo "status: $(status)"
  IPV4=$(ipv4)
  if [ -n "$IPV4" ]; then
    echo "ip: $(ipv4)"
  fi
}

destroyAction() {
  destroy
  n=0
  until [ $n -ge 30 -o "$(status)" == "down" ]; do
    echo "current status: $(status)"
    n=$[$n+1]
    sleep 1
  done

  if [ "$(status)" != "down" ]; then
    echo "failed to stop"
  else
    statusAction
  fi
}

sshAction() {
  if [ "$(status)" == "active" ]; then
    ssh root@$(ipv4) -oStrictHostKeyChecking=no -i /tmp/${SSH_KEY_NAME}
  else
    statusAction
  fi
}

getKeys() {
  curl -s -X GET -H "Content-Type: application/json" \
  -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" \
  "https://api.digitalocean.com/v2/account/keys"
}

getKeyID() {
  echo $(getKeys | jq -c '[ .ssh_keys[] | select( .name | contains("'"$SSH_KEY_NAME"'")).id ][0]' -r)
}

destroyKey() {
  if [ "$(getKeyID)" != "null" ]; then
    curl -s -X DELETE -H "Content-Type: application/json" \
    -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" \
    "https://api.digitalocean.com/v2/account/keys/$(getKeyID)"
  fi
}

createKey() {
  destroyKey
  rm /tmp/${SSH_KEY_NAME}
  rm /tmp/${SSH_KEY_NAME}.pub
  ssh-keygen -b 2048 -t rsa -f /tmp/${SSH_KEY_NAME} -N ""
  SSH_PUB_KEY=$(cat /tmp/${SSH_KEY_NAME}.pub)
  curl -s -X POST -H "Content-Type: application/json" \
  -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" \
  -d '{"name":"'"$SSH_KEY_NAME"'","public_key":"'"${SSH_PUB_KEY}"'"}' \
  "https://api.digitalocean.com/v2/account/keys" | jq
}

list() {
  curl -s -X GET -H "Content-Type: application/json" \
  -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" \
  "https://api.digitalocean.com/v2/droplets?tag_name=$NAME"
}

numInstances() {
  echo $(list | jq '.droplets | length')
}

status() {
  if [ "$(numInstances)" = 0 ]; then
    echo "down"
  else
    echo $(list | jq .droplets[0].status -r)
  fi
}

ipv4() {
  if [ "$(status)" != "down" ]; then
    echo $(list | jq .droplets[0].networks.v4[0].ip_address -r)
  fi
}

destroy() {
  if [ "$(status)" != "down" ]; then
    curl -X DELETE -H "Content-Type: application/json" \
    -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" \
    "https://api.digitalocean.com/v2/droplets?tag_name=$NAME"
  fi
}

if [ -z "${ACTION}" -o "${ACTION}" = "help" ]; then
  help
fi

if [ "${LOCAL}" = "true" ]; then

  if [ "${ACTION}" = "up" ]; then
    docker-compose -f docker-compose.local.yml up --remove-orphans
  elif [ "${ACTION}" = "down" ]; then
    docker-compose -f docker-compose.local.yml down
  else
    echo "Command '${ACTION}' supported in local mode"
  fi

else

  if [ "${ACTION}" = "up" ]; then
    deployAction
  elif [ "${ACTION}" = "provision" ]; then
    provisionAction
  elif [ "${ACTION}" = "status" ]; then
    statusAction
  elif [ "${ACTION}" = "down" ]; then
    destroyAction
  elif [ "${ACTION}" = "ssh" ]; then
    sshAction
  fi

fi

exit 0
