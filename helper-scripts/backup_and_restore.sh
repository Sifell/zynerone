#!/usr/bin/env bash

DEBIAN_DOCKER_IMAGE="zynerone/backup:latest"

if [[ ! -z ${ZYNERONE_BACKUP_LOCATION} ]]; then
  BACKUP_LOCATION="${ZYNERONE_BACKUP_LOCATION}"
fi

if [[ ! ${1} =~ (backup|restore) ]]; then
  echo "First parameter needs to be 'backup' or 'restore'"
  exit 1
fi

if [[ ${1} == "backup" && ! ${2} =~ (crypt|vmail|redis|rspamd|postfix|mysql|all|--delete-days) ]]; then
  echo "Second parameter needs to be 'vmail', 'crypt', 'redis', 'rspamd', 'postfix', 'mysql', 'all' or '--delete-days'"
  exit 1
fi

if [[ -z ${BACKUP_LOCATION} ]]; then
  while [[ -z ${BACKUP_LOCATION} ]]; do
    read -ep "Backup location (absolute path, starting with /): " BACKUP_LOCATION
  done
fi

if [[ ! ${BACKUP_LOCATION} =~ ^/ ]]; then
  echo "Backup directory needs to be given as absolute path (starting with /)."
  exit 1
fi

if [[ -f ${BACKUP_LOCATION} ]]; then
  echo "${BACKUP_LOCATION} is a file!"
  exit 1
fi

if [[ ! -d ${BACKUP_LOCATION} ]]; then
  echo "${BACKUP_LOCATION} is not a directory"
  read -p "Create it now? [y|N] " CREATE_BACKUP_LOCATION
  if [[ ! ${CREATE_BACKUP_LOCATION,,} =~ ^(yes|y)$ ]]; then
    exit 1
  else
    mkdir -p ${BACKUP_LOCATION}
    chmod 755 ${BACKUP_LOCATION}
  fi
else
  if [[ ${1} == "backup" ]] && [[ -z $(echo $(stat -Lc %a ${BACKUP_LOCATION}) | grep -oE '[0-9][0-9][5-7]') ]]; then
    echo "${BACKUP_LOCATION} is not write-able for others, that's required for a backup."
    exit 1
  fi
fi

BACKUP_LOCATION=$(echo ${BACKUP_LOCATION} | sed 's#/$##')
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
COMPOSE_FILE=${SCRIPT_DIR}/../docker-compose.yml
ENV_FILE=${SCRIPT_DIR}/../.env
THREADS=$(echo ${THREADS:-1})

if ! [[ "${THREADS}" =~ ^[1-9]+$ ]] ; then
  echo "Thread input is not a number!"
  exit 1
elif [[ "${THREADS}" =~ ^[1-9]+$ ]] ; then
  echo "Using ${THREADS} Thread(s) for this run."
  echo "Notice: You can set the Thread count with the THREADS Variable before you run this script."
fi

if [ ! -f ${COMPOSE_FILE} ]; then
  echo "Compose file not found"
  exit 1
fi

if [ ! -f ${ENV_FILE} ]; then
  echo "Environment file not found"
  exit 1
fi

echo "Using ${BACKUP_LOCATION} as backup/restore location."
echo

source ${SCRIPT_DIR}/../zynerone.conf

if [[ -z ${COMPOSE_PROJECT_NAME} ]]; then
  echo "Could not determine compose project name"
  exit 1
else
  echo "Found project name ${COMPOSE_PROJECT_NAME}"
  CMPS_PRJ=$(echo ${COMPOSE_PROJECT_NAME} | tr -cd "[0-9A-Za-z-_]")
fi

if grep --help 2>&1 | head -n 1 | grep -q -i "busybox"; then
  >&2 echo -e "\e[31mBusyBox grep detected on local system, please install GNU grep\e[0m"
  exit 1
fi


function backup() {
  DATE=$(date +"%Y-%m-%d-%H-%M-%S")
  mkdir -p "${BACKUP_LOCATION}/zynerone-${DATE}"
  chmod 755 "${BACKUP_LOCATION}/zynerone-${DATE}"
  cp "${SCRIPT_DIR}/../zynerone.conf" "${BACKUP_LOCATION}/zynerone-${DATE}"
  for bin in docker; do
  if [[ -z $(which ${bin}) ]]; then
    >&2 echo -e "\e[31mCannot find ${bin} in local PATH, exiting...\e[0m"
    exit 1
  fi
  done
  while (( "$#" )); do
    case "$1" in
    vmail|all)
      docker run --name zynerone-backup --rm \
        -v ${BACKUP_LOCATION}/zynerone-${DATE}:/backup:z \
        -v $(docker volume ls -qf name=^${CMPS_PRJ}_vmail-vol-1$):/vmail:ro,z \
        ${DEBIAN_DOCKER_IMAGE} /bin/tar --warning='no-file-ignored' --use-compress-program="pigz --rsyncable -p ${THREADS}" -Pcvpf /backup/backup_vmail.tar.gz /vmail
      ;;&
    crypt|all)
      docker run --name zynerone-backup --rm \
        -v ${BACKUP_LOCATION}/zynerone-${DATE}:/backup:z \
        -v $(docker volume ls -qf name=^${CMPS_PRJ}_crypt-vol-1$):/crypt:ro,z \
        ${DEBIAN_DOCKER_IMAGE} /bin/tar --warning='no-file-ignored' --use-compress-program="pigz --rsyncable -p ${THREADS}" -Pcvpf /backup/backup_crypt.tar.gz /crypt
      ;;&
    redis|all)
      docker exec $(docker ps -qf name=redis-zynerone) redis-cli save
      docker run --name zynerone-backup --rm \
        -v ${BACKUP_LOCATION}/zynerone-${DATE}:/backup:z \
        -v $(docker volume ls -qf name=^${CMPS_PRJ}_redis-vol-1$):/redis:ro,z \
        ${DEBIAN_DOCKER_IMAGE} /bin/tar --warning='no-file-ignored' --use-compress-program="pigz --rsyncable -p ${THREADS}" -Pcvpf /backup/backup_redis.tar.gz /redis
      ;;&
    rspamd|all)
      docker run --name zynerone-backup --rm \
        -v ${BACKUP_LOCATION}/zynerone-${DATE}:/backup:z \
        -v $(docker volume ls -qf name=^${CMPS_PRJ}_rspamd-vol-1$):/rspamd:ro,z \
        ${DEBIAN_DOCKER_IMAGE} /bin/tar --warning='no-file-ignored' --use-compress-program="pigz --rsyncable -p ${THREADS}" -Pcvpf /backup/backup_rspamd.tar.gz /rspamd
      ;;&
    postfix|all)
      docker run --name zynerone-backup --rm \
        -v ${BACKUP_LOCATION}/zynerone-${DATE}:/backup:z \
        -v $(docker volume ls -qf name=^${CMPS_PRJ}_postfix-vol-1$):/postfix:ro,z \
        ${DEBIAN_DOCKER_IMAGE} /bin/tar --warning='no-file-ignored' --use-compress-program="pigz --rsyncable -p ${THREADS}" -Pcvpf /backup/backup_postfix.tar.gz /postfix
      ;;&
    mysql|all)
      SQLIMAGE=$(grep -iEo '(mysql|mariadb)\:.+' ${COMPOSE_FILE})
      if [[ -z "${SQLIMAGE}" ]]; then
        echo "Could not determine SQL image version, skipping backup..."
        shift
        continue
      else
        echo "Using SQL image ${SQLIMAGE}, starting..."
        docker run --name zynerone-backup --rm \
          --network $(docker network ls -qf name=^${CMPS_PRJ}_zynerone-network$) \
          -v $(docker volume ls -qf name=^${CMPS_PRJ}_mariadb-vol-1$):/var/lib/mysql/:ro,z \
          -t --entrypoint= \
          --sysctl net.ipv6.conf.all.disable_ipv6=1 \
          -v ${BACKUP_LOCATION}/zynerone-${DATE}:/backup:z \
          ${SQLIMAGE} /bin/sh -c "mariabackup --host mysql --user root --password ${DBROOT} --backup --rsync --target-dir=/backup_mariadb ; \
          mariabackup --prepare --target-dir=/backup_mariadb ; \
          chown -R 999:999 /backup_mariadb ; \
          /bin/tar --warning='no-file-ignored' --use-compress-program='gzip --rsyncable' -Pcvpf /backup/backup_mariadb.tar.gz /backup_mariadb ;"
      fi
      ;;&
    --delete-days)
      shift
      if [[ "${1}" =~ ^[0-9]+$ ]]; then
        find ${BACKUP_LOCATION}/zynerone-* -maxdepth 0 -mmin +$((${1}*60*24)) -exec rm -rvf {} \;
      else
        echo "Parameter of --delete-days is not a number."
      fi
      ;;
    esac
    shift
  done
}

function restore() {
  for bin in docker; do
  if [[ -z $(which ${bin}) ]]; then
    >&2 echo -e "\e[31mCannot find ${bin} in local PATH, exiting...\e[0m"
    exit 1
  fi
  done

  if [ "${DOCKER_COMPOSE_VERSION}" == "native" ]; then
  COMPOSE_COMMAND="docker compose"

  elif [ "${DOCKER_COMPOSE_VERSION}" == "standalone" ]; then
    COMPOSE_COMMAND="docker-compose"

  else
    echo -e "\e[31mCan not read DOCKER_COMPOSE_VERSION variable from zynerone.conf! Is your zynerone up to date? Exiting...\e[0m"
    exit 1
  fi

  echo
  echo "Stopping watchdog-zynerone..."
  docker stop $(docker ps -qf name=watchdog-zynerone)
  echo
  RESTORE_LOCATION="${1}"
  shift
  while (( "$#" )); do
    case "$1" in
    vmail)
      docker stop $(docker ps -qf name=dovecot-zynerone)
      docker run -it --name zynerone-backup --rm \
        -v ${RESTORE_LOCATION}:/backup:z \
        -v $(docker volume ls -qf name=^${CMPS_PRJ}_vmail-vol-1$):/vmail:z \
        ${DEBIAN_DOCKER_IMAGE} /bin/tar --use-compress-program="pigz -d -p ${THREADS}" -Pxvf /backup/backup_vmail.tar.gz
      docker start $(docker ps -aqf name=dovecot-zynerone)
      echo
      echo "In most cases it is not required to run a full resync, you can run the command printed below at any time after testing wether the restore process broke a mailbox:"
      echo
      echo "docker exec $(docker ps -qf name=dovecot-zynerone) doveadm force-resync -A '*'"
      echo
      read -p "Force a resync now? [y|N] " FORCE_RESYNC
      if [[ ${FORCE_RESYNC,,} =~ ^(yes|y)$ ]]; then
        docker exec $(docker ps -qf name=dovecot-zynerone) doveadm force-resync -A '*'
      else
        echo "OK, skipped."
      fi
      ;;
    redis)
      docker stop $(docker ps -qf name=redis-zynerone)
      docker run -it --name zynerone-backup --rm \
        -v ${RESTORE_LOCATION}:/backup:z \
        -v $(docker volume ls -qf name=^${CMPS_PRJ}_redis-vol-1$):/redis:z \
        ${DEBIAN_DOCKER_IMAGE} /bin/tar --use-compress-program="pigz -d -p ${THREADS}" -Pxvf /backup/backup_redis.tar.gz
      docker start $(docker ps -aqf name=redis-zynerone)
      ;;
    crypt)
      docker stop $(docker ps -qf name=dovecot-zynerone)
      docker run -it --name zynerone-backup --rm \
        -v ${RESTORE_LOCATION}:/backup:z \
        -v $(docker volume ls -qf name=^${CMPS_PRJ}_crypt-vol-1$):/crypt:z \
        ${DEBIAN_DOCKER_IMAGE} /bin/tar --use-compress-program="pigz -d -p ${THREADS}" -Pxvf /backup/backup_crypt.tar.gz
      docker start $(docker ps -aqf name=dovecot-zynerone)
      ;;
    rspamd)
      docker stop $(docker ps -qf name=rspamd-zynerone)
      docker run -it --name zynerone-backup --rm \
        -v ${RESTORE_LOCATION}:/backup:z \
        -v $(docker volume ls -qf name=^${CMPS_PRJ}_rspamd-vol-1$):/rspamd:z \
        ${DEBIAN_DOCKER_IMAGE} /bin/tar --use-compress-program="pigz -d -p ${THREADS}" -Pxvf /backup/backup_rspamd.tar.gz
      docker start $(docker ps -aqf name=rspamd-zynerone)
      ;;
    postfix)
      docker stop $(docker ps -qf name=postfix-zynerone)
      docker run -it --name zynerone-backup --rm \
        -v ${RESTORE_LOCATION}:/backup:z \
        -v $(docker volume ls -qf name=^${CMPS_PRJ}_postfix-vol-1$):/postfix:z \
        ${DEBIAN_DOCKER_IMAGE} /bin/tar --use-compress-program="pigz -d -p ${THREADS}" -Pxvf /backup/backup_postfix.tar.gz
      docker start $(docker ps -aqf name=postfix-zynerone)
      ;;
    mysql|mariadb)
      SQLIMAGE=$(grep -iEo '(mysql|mariadb)\:.+' ${COMPOSE_FILE})
      if [[ -z "${SQLIMAGE}" ]]; then
        echo "Could not determine SQL image version, skipping restore..."
        shift
        continue
      elif [ ! -f "${RESTORE_LOCATION}/zynerone.conf" ]; then
        echo "Could not find the corresponding zynerone.conf in ${RESTORE_LOCATION}, skipping restore."
        echo "If you lost that file, copy the last working zynerone.conf file to ${RESTORE_LOCATION} and restart the restore process."
        shift
        continue
      else
        read -p "zynerone will be stopped and the currently active zynerone.conf will be modified to use the DB parameters found in ${RESTORE_LOCATION}/zynerone.conf - do you want to proceed? [Y|n] " MYSQL_STOP_ZYNERONE
        if [[ ${MYSQL_STOP_ZYNERONE,,} =~ ^(no|n|N)$ ]]; then
          echo "OK, skipped."
          shift
          continue
        else
          echo "Stopping zynerone..."
          ${COMPOSE_COMMAND} -f ${COMPOSE_FILE} --env-file ${ENV_FILE} down
        fi
        #docker stop $(docker ps -qf name=mariadb-zynerone)
        if [[ -d "${RESTORE_LOCATION}/mysql" ]]; then
        docker run --name zynerone-backup --rm \
          -v $(docker volume ls -qf name=^${CMPS_PRJ}_mariadb-vol-1$):/var/lib/mysql/:rw,z \
          --entrypoint= \
          -v ${RESTORE_LOCATION}/mysql:/backup:z \
          ${SQLIMAGE} /bin/bash -c "shopt -s dotglob ; /bin/rm -rf /var/lib/mysql/* ; rsync -avh --usermap=root:mysql --groupmap=root:mysql /backup/ /var/lib/mysql/"
        elif [[ -f "${RESTORE_LOCATION}/backup_mysql.gz" ]]; then
        docker run \
          -it --name zynerone-backup --rm \
          -v $(docker volume ls -qf name=^${CMPS_PRJ}_mariadb-vol-1$):/var/lib/mysql/:z \
          --entrypoint= \
          -u mysql \
          -v ${RESTORE_LOCATION}:/backup:z \
          ${SQLIMAGE} /bin/sh -c "mysqld --skip-grant-tables & \
          until mysqladmin ping; do sleep 3; done && \
          echo Restoring... && \
          gunzip < backup/backup_mysql.gz | mysql -uroot && \
          mysql -uroot -e SHUTDOWN;"
        elif [[ -f "${RESTORE_LOCATION}/backup_mariadb.tar.gz" ]]; then
        docker run --name zynerone-backup --rm \
          -v $(docker volume ls -qf name=^${CMPS_PRJ}_mariadb-vol-1$):/backup_mariadb/:rw,z \
          --entrypoint= \
          -v ${RESTORE_LOCATION}:/backup:z \
          ${SQLIMAGE} /bin/bash -c "shopt -s dotglob ; \
            /bin/rm -rf /backup_mariadb/* ; \
            /bin/tar -Pxvzf /backup/backup_mariadb.tar.gz"
        fi
        echo "Modifying zynerone.conf..."
        source ${RESTORE_LOCATION}/zynerone.conf
        sed -i --follow-symlinks "/DBNAME/c\DBNAME=${DBNAME}" ${SCRIPT_DIR}/../zynerone.conf
        sed -i --follow-symlinks "/DBUSER/c\DBUSER=${DBUSER}" ${SCRIPT_DIR}/../zynerone.conf
        sed -i --follow-symlinks "/DBPASS/c\DBPASS=${DBPASS}" ${SCRIPT_DIR}/../zynerone.conf
        sed -i --follow-symlinks "/DBROOT/c\DBROOT=${DBROOT}" ${SCRIPT_DIR}/../zynerone.conf
        source ${SCRIPT_DIR}/../zynerone.conf
        echo "Starting zynerone..."
        ${COMPOSE_COMMAND} -f ${COMPOSE_FILE} --env-file ${ENV_FILE} up -d
        #docker start $(docker ps -aqf name=mariadb-zynerone)
      fi
      ;;
    esac
    shift
  done
  echo
  echo "Starting watchdog-zynerone..."
  docker start $(docker ps -aqf name=watchdog-zynerone)
}

if [[ ${1} == "backup" ]]; then
  backup ${@,,}
elif [[ ${1} == "restore" ]]; then
  i=1
  declare -A FOLDER_SELECTION
  if [[ $(find ${BACKUP_LOCATION}/zynerone-* -maxdepth 1 -type d 2> /dev/null| wc -l) -lt 1 ]]; then
    echo "Selected backup location has no subfolders"
    exit 1
  fi
  for folder in $(ls -d ${BACKUP_LOCATION}/zynerone-*/); do
    echo "[ ${i} ] - ${folder}"
    FOLDER_SELECTION[${i}]="${folder}"
    ((i++))
  done
  echo
  input_sel=0
  while [[ ${input_sel} -lt 1 ||  ${input_sel} -gt ${i} ]]; do
    read -p "Select a restore point: " input_sel
  done
  i=1
  echo
  declare -A FILE_SELECTION
  RESTORE_POINT="${FOLDER_SELECTION[${input_sel}]}"
  if [[ -z $(find "${FOLDER_SELECTION[${input_sel}]}" -maxdepth 1 \( -type d -o -type f \) -regex ".*\(redis\|rspamd\|mariadb\|mysql\|crypt\|vmail\|postfix\).*") ]]; then
    echo "No datasets found"
    exit 1
  fi

  echo "[ 0 ] - all"
  # find all files in folder with *.gz extension, print their base names, remove backup_, remove .tar (if present), remove .gz
  FILE_SELECTION[0]=$(find "${FOLDER_SELECTION[${input_sel}]}" -maxdepth 1 \( -type d -o -type f \) \( -name '*.gz' -o -name 'mysql' \) -printf '%f\n' | sed 's/backup_*//' | sed 's/\.[^.]*$//' | sed 's/\.[^.]*$//')
  for file in $(ls -f "${FOLDER_SELECTION[${input_sel}]}"); do
    if [[ ${file} =~ vmail ]]; then
      echo "[ ${i} ] - Mail directory (/var/vmail)"
      FILE_SELECTION[${i}]="vmail"
      ((i++))
    elif [[ ${file} =~ crypt ]]; then
      echo "[ ${i} ] - Crypt data"
      FILE_SELECTION[${i}]="crypt"
      ((i++))
    elif [[ ${file} =~ redis ]]; then
      echo "[ ${i} ] - Redis DB"
      FILE_SELECTION[${i}]="redis"
      ((i++))
    elif [[ ${file} =~ rspamd ]]; then
      echo "[ ${i} ] - Rspamd data"
      FILE_SELECTION[${i}]="rspamd"
      ((i++))
    elif [[ ${file} =~ postfix ]]; then
      echo "[ ${i} ] - Postfix data"
      FILE_SELECTION[${i}]="postfix"
      ((i++))
    elif [[ ${file} =~ mysql ]] || [[ ${file} =~ mariadb ]]; then
      echo "[ ${i} ] - SQL DB"
      FILE_SELECTION[${i}]="mysql"
      ((i++))
    fi
  done
  echo
  input_sel=-1
  while [[ ${input_sel} -lt 0 ||  ${input_sel} -gt ${i} ]]; do
    read -p "Select a dataset to restore: " input_sel
  done
  echo "Restoring ${FILE_SELECTION[${input_sel}]} from ${RESTORE_POINT}..."
  restore "${RESTORE_POINT}" ${FILE_SELECTION[${input_sel}]}
fi
