#!/usr/bin/env bash

help() {
  echo "dropler"
  echo ""
  echo "usage:"
  echo "  ./dropler.sh [COMMAND] [OPTS]"
  echo ""
  echo "options:"
  echo "  -d         set the dir to upload from"
  echo "  -n         set the droplet name"
  echo "  -e         export environment variable from host to vm"
  echo ""
  echo "commands:"
  echo "  up         creates a DigitalOcean droplet"
  echo "  dns        updates dns A record address"
  echo "  provision  rsyncs local source code to droplet and runs docker-compose"
  echo "  rsync      rsyncs local source code to droplet"
  echo "  restart    restarts the containers on on the droplet"
  echo "  status     shows the status of the droplet and ipv4 address"
  echo "  down       destroys the droplet"
  echo "  ssh        connects to the droplet via SSH"
  echo "  logs       tails logs of containers on the droplet"
  exit 0
}

updateDNS() {
  if [ -n "${ROOT_DOMAIN}" ]; then
    if [ -n "${GODADDY_KEY}" ]; then
      IP_ADDR=$(ipv4)
      echo "updating ${NAME}.${ROOT_DOMAIN} to ${IP_ADDR}"
      curl -sX PUT "https://api.godaddy.com/v1/domains/${ROOT_DOMAIN}/records/A/${NAME}" \
        -H 'Content-Type: application/json' \
        -H "Authorization: sso-key ${GODADDY_KEY}:${GODADDY_SECRET}" \
        -d '[{"data":"'${IP_ADDR}'","ttl":600}]' 2>&1 > /dev/null
      echo "updated ${NAME}.${ROOT_DOMAIN} to ${IP_ADDR}"
    fi
  fi
}

deployAction() {
  if [ "$(status)" == "down" ]; then
    createKey
    SSH_PUB_KEY_ID=$(getKeyID)
    if [ "$SSH_PUB_KEY_ID" == "null" ]; then
      exit 1
    fi
    curl -s -X POST -H "Content-Type: application/json" \
    -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" \
    -d '{"name":"'"$NAME"'","region":"nyc1","size":"1gb","image":"docker","ssh_keys":["'"$SSH_PUB_KEY_ID"'"],"tags":["'"$NAME"'"]}' \
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

asExports() {
  for val in "$@"; do
    VARIABLE_NAME=$(echo ${val} | awk -F= '{print $1}')
    VARIABLE_VALUE="${!VARIABLE_NAME}"
    if [ $(echo ${val} | awk -F= '{print NF; exit}') = "2" ]; then
      VARIABLE_VALUE=$(echo ${val} | awk -F= '{print $2}')
    fi
    echo 'export '${VARIABLE_NAME}'='${VARIABLE_VALUE}';'
  done
}

provisionAction() {
  IP_ADDR=$(ipv4)
  updateDNS
  if [ -n "$VARS" ]; then
    HOST_VARS=$(asExports "${VARS[@]}")
  fi
  until nc -zvw 1 ${IP_ADDR} 22; do
    sleep 2
  done
  read -r -d "" PROVISION <<EOF
if docker-compose -v > /dev/null; then
  echo "found docker-compose"
else
  sudo curl -o /usr/local/bin/docker-compose -L "https://github.com/docker/compose/releases/download/1.15.0/docker-compose-\$(uname -s)-\$(uname -m)"
  sudo chmod +x /usr/local/bin/docker-compose
  docker-compose -v
fi
${HOST_VARS}
export DP_NAME=${NAME}
export DP_IP_ADDR=${IP_ADDR}
if [ -f "/${NAME}/run.sh" ]; then
  . "/${NAME}/run.sh"
else
  if [ -f "/${NAME}/docker-compose.yml" ]; then
    docker-compose -f /${NAME}/docker-compose.yml up -d
  else
    echo "/${NAME}/docker-compose.yml not found"
  fi
fi
EOF
  SSH_CMD="ssh root@${IP_ADDR} -o UserKnownHostsFile=/dev/null -oStrictHostKeyChecking=no -i /tmp/${SSH_KEY_NAME}"
  ${SSH_CMD} -t "rm -rf /${NAME} && mkdir -p /${NAME}"
  DROPLET_INIT_SCRIPT="${WORKING_DIR}/droplet.init.sh"
  if [ -f "${DROPLET_INIT_SCRIPT}" ]; then
    ${SSH_CMD} -t "${HOST_VARS} bash -s" < "${DROPLET_INIT_SCRIPT}"
  fi
  rsyncAction
  ${SSH_CMD} -t "$PROVISION"
}

rsyncAction() {
  IP_ADDR=$(ipv4)
  rsync -Pav --delete --exclude='.git/' --filter='dir-merge,- .gitignore' -e "ssh -o UserKnownHostsFile=/dev/null -oStrictHostKeyChecking=no -i /tmp/$SSH_KEY_NAME" ${WORKING_DIR} root@${IP_ADDR}:/
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
  CMD="${1}"
  if [ "$(status)" == "active" ]; then
    if [ -z "${CMD}" ]; then
      ssh root@$(ipv4) -o UserKnownHostsFile=/dev/null -oStrictHostKeyChecking=no -i /tmp/${SSH_KEY_NAME}
    else
      ssh root@$(ipv4) -o UserKnownHostsFile=/dev/null -oStrictHostKeyChecking=no -i /tmp/${SSH_KEY_NAME} -t "${CMD}"
    fi
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

if [ -z "${ENV_FILE}" ]; then
  ENV_FILE='.env'
fi

if [ -f ${ENV_FILE} ]; then
  source ${ENV_FILE}
fi

if ! which jq 2>&1 > /dev/null; then
  echo 'missing required dependency jq (https://stedolan.github.io/jq/)'
  exit 1
fi

if [ -z "$DIGITALOCEAN_TOKEN" ]; then
  echo 'missing required env variable DIGITALOCEAN_TOKEN'
  exit 1
fi

ACTION=$1;shift
NAME=$(basename "${SCRIPT_PATH}")
WORKING_DIR=$(pwd -P)
LOCAL=false
if [[ ! "${1}" == -* ]]; then
   ARG=$1;shift
fi
if [[ ! "${1}" == -* ]]; then
   ARG_2=$1;shift
fi
if [[ ! "${1}" == -* ]]; then
   ARG_3=$1;shift
fi

while getopts d:n:e:,l flag; do
  case $flag in
  d)
    WORKING_DIR=$OPTARG
    ;;
  n)
    NAME=$OPTARG
    ;;
  e)
    VARS+=("$OPTARG")
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
  elif [ "${ACTION}" = "dns" ]; then
    updateDNS
  elif [ "${ACTION}" = "provision" ]; then
    provisionAction
  elif [ "${ACTION}" = "rsync" ]; then
    rsyncAction
  elif [ "${ACTION}" = "restart" ]; then
    COMPOSE_SERVICE=${ARG}
    sshAction "cd /${NAME} && docker-compose -f docker-compose.yml restart ${COMPOSE_SERVICE}"
  elif [ "${ACTION}" = "status" ]; then
    statusAction
  elif [ "${ACTION}" = "ls" ]; then
    list
  elif [ "${ACTION}" = "down" ]; then
    destroyAction
  elif [ "${ACTION}" = "ssh" ]; then
    sshAction "${ARG}"
  elif [ "${ACTION}" = "logs" ]; then
    COMPOSE_SERVICE=${ARG}
    sshAction "cd /${NAME} && docker-compose -f docker-compose.yml logs --follow --tail='100' ${COMPOSE_SERVICE}"
  fi

fi

exit 0
