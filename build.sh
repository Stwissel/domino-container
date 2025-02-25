#!/bin/bash

############################################################################
# Copyright Nash!Com, Daniel Nashed 2019, 2023 - APACHE 2.0 see LICENSE
# Copyright IBM Corporation 2015, 2020 - APACHE 2.0 see LICENSE
############################################################################

# Version 2.0.3

# Main Script to build images.
# Run without parameters for detailed syntax.
# The script checks if software is available at configured location (download location or local directory).
# In case of a local software directory it hosts the software on a local NGINX container.

SCRIPT_NAME=$(readlink -f $0)
SCRIPT_DIR=$(dirname $SCRIPT_NAME)

# Standard configuration overwritten by build.cfg
# (Default) NGINX is used hosting software from the local "software" directory.

# Default: Update Linux base image while building the image
LinuxYumUpdate=yes

# Default: Check if software exits
CHECK_SOFTWARE=yes

# ----------------------------------------

log_error_exit()
{
  echo
  echo $@
  echo

  exit 1
}

log()
{
  echo
  echo $@
  echo
}

check_version()
{
  count=1

  while true
  do
    VER=$(echo $1|cut -d"." -f $count)
    CHECK=$(echo $2|cut -d"." -f $count)

    if [ -z "$VER" ]; then return 0; fi
    if [ -z "$CHECK" ]; then return 0; fi

    if [ $VER -gt $CHECK ]; then return 0; fi
    if [ $VER -lt $CHECK ]; then
      echo "Warning: Unsupported $3 version $1 - Must be at least $2 !"
      sleep 1
      return 1
    fi

    count=$(expr $count + 1)
  done

  return 0
}

check_timezone()
{
  LARCH=$(uname)

  echo

  # If Timezone is not set use host's timezone
  if [ -z "$DOCKER_TZ" ]; then

    case "$LARCH" in

      Linux|Darwin)
        DOCKER_TZ=$(readlink /etc/localtime | awk -F'/zoneinfo/' '{print $2}')
        ;;

      *)
        DOCKER_TZ=""
      ;;
    esac

    echo "Using OS Timezone : [$DOCKER_TZ]"

  else

    if [ -e "/usr/share/zoneinfo/$DOCKER_TZ" ]; then
      echo "Timezone configured: [$DOCKER_TZ]"
    else
      log_error_exit "Invalid timezone specified [$DOCKER_TZ]"
    fi

  fi

  echo
  return 0
}

get_container_environment()
{
  # If specified use specified command. Else find out the platform.

  if [ -n "$CONTAINER_CMD" ]; then
    return 0
  fi

  if [ -n "$USE_DOCKER" ]; then
    CONTAINER_CMD=docker
    return 0
  fi

  if [ -x /usr/bin/podman ]; then
    CONTAINER_CMD=podman
    return 0
  fi

  if [ -n "$(which nerdctl 2> /dev/null)" ]; then
    CONTAINER_CMD=nerdctl
    return 0
  fi

  CONTAINER_CMD=docker

  return 0
}

check_container_environment()
{
  DOCKER_MINIMUM_VERSION="20.10.0"
  PODMAN_MINIMUM_VERSION="3.3.0"

  if [ "$CONTAINER_CMD" = "podman" ]; then
    DOCKER_ENV_NAME=Podman
    DOCKER_VERSION_STR=$(podman -v | head -1)
    DOCKER_VERSION=$(echo $DOCKER_VERSION_STR | awk -F'version ' '{print $2 }')
    check_version "$DOCKER_VERSION" "$PODMAN_MINIMUM_VERSION" "$CONTAINER_CMD"

    if [ -z "$DOCKER_NETWORK" ]; then
      if [ -n "$DOCKER_NETWORK_NAME" ]; then
        CONTAINER_NETWORK_CMD="--network=$CONTAINER_NETWORK_NAME"
      fi
    fi

    return 0
  fi

  if [ "$CONTAINER_CMD" = "docker" ]; then

    DOCKER_ENV_NAME=Docker

    if [ -z "$DOCKERD_NAME" ]; then
      DOCKERD_NAME=dockerd
    fi

    # check docker environment
    DOCKER_VERSION_STR=$(docker -v | head -1)
    DOCKER_VERSION=$(echo $DOCKER_VERSION_STR | awk -F'version ' '{print $2 }'|cut -d"," -f1)

    check_version "$DOCKER_VERSION" "$DOCKER_MINIMUM_VERSION" "$CONTAINER_CMD"

    # Use sudo for docker command if not root on Linux

    if [ $(uname) = "Linux" ]; then
      if [ ! "$EUID" = "0" ]; then
        if [ "$DOCKER_USE_SUDO" = "yes" ]; then
          CONTAINER_CMD="sudo $CONTAINER_CMD"
        fi
      fi
    fi

    if [ -z "$DOCKER_NETWORK" ]; then
      if [ -n "$DOCKER_NETWORK_NAME" ]; then
        CONTAINER_NETWORK_CMD="--network=$CONTAINER_NETWORK_NAME"
      fi
    fi

    return 0
  fi

  if [ "$CONTAINER_CMD" = "nerdctl" ]; then
    DOCKER_ENV_NAME=nerdctl

    if [ -z "$CONTAINER_NAMESPACE" ]; then
      CONTAINER_NAMESPACE=k8s.io
    fi

    CONTAINER_NAMESPACE_CMD="--namespace=$CONTAINER_NAMESPACE"

    DOCKER_VERSION_STR=$(nerdctl -v | head -1)
    DOCKER_VERSION=$(echo $DOCKER_VERSION_STR | awk -F'version ' '{print $2 }')
  fi

  return 0
}


usage()
{
  echo
  echo "Usage: $(basename $SCRIPT_NAME) { domino | traveler | volt | leap | safelinx } version fp hf"
  echo
  echo "-checkonly       checks without build"
  echo "-verifyonly      checks download file checksum without build"
  echo "-(no)check       checks if files exist (default: yes)"
  echo "-(no)verify      checks downloaded file checksum (default: no)"
  echo "-(no)url         shows all download URLs, even if file is downloaded (default: no)"
  echo "-(no)linuxupd    updates container Linux  while building image (default: yes)"
  echo "cfg|config       edits config file (either in current directory or if created in home dir)"
  echo "cpcfg            copies standard config file to config directory (default: $CONFIG_FILE)"
  echo
  echo "-tag=<image>     additional image tag"
  echo "-push=<image>    tag and push image to registry"
  echo
  echo Options
  echo
  echo "-from=<image>    builds from a specified build image. there are named images like 'ubi' predefined"
  echo "-imagename=<img> defines the target image name"
  echo "-imagetag=<img>  defines the target image tag"
  echo "-save=<img>      exports the image after build. e.g. -save=domino-container.tgz"
  echo "-tz=<timezone>   explictly set container timezone during build. by default Linux TZ is used"
  echo "-pull            always try to pull a newer base image version"
  echo "-openssl         adds OpenSSL to Domino image"
  echo "-borg            adds borg client and Domino Borg Backup integration to image"
  echo "-verse           adds Verse to a Domino image"
  echo "-nomad           adds the Nomad server to a Domino image"
  echo "-capi            adds the C-API sdk/toolkit to a Domino image"
  echo "-domlp=de        adds the German Language Pack to the image"
  echo "-restapi         adds the Domino REST API to the image"
  echo "-k8s-runas       adds K8s runas user support"
  echo "-startscript=x   installs specified start script version from software repository"
  echo
  echo SafeLinx options
  echo
  echo "-nomadweb        adds the latest Nomad Web version to a SafeLinx image"
  echo "-mysql           adds the MySQL client to the SafeLinx image"
  echo "-mssql           adds the Mircosoft SQL Server client to the SafeLinx image"
  echo
  echo "Special commands:"
  echo
  echo "save <img> <my.tgz>   exports the specified image to tgz format (e.g. save hclcom/domino:latest domino.tgz)"
  echo
  echo "Examples:"
  echo
  echo "  $(basename $SCRIPT_NAME) domino 12.0.1 fp1"
  echo "  $(basename $SCRIPT_NAME) traveler 12.0.1"
  echo

  return 0
}


print_delim()
{
  echo "--------------------------------------------------------------------------------"
}

header()
{
  echo
  print_delim
  echo "$1"
  print_delim
  echo
}

dump_config()
{
  header "Build Configuration"
  echo "Build Environment    : [$CONTAINER_CMD]"
  echo "BASE_IMAGE           : [$BASE_IMAGE]"
  echo "DOWNLOAD_FROM        : [$DOWNLOAD_FROM]"
  echo "SOFTWARE_DIR         : [$SOFTWARE_DIR]"
  echo "PROD_NAME            : [$PROD_NAME]"
  echo "PROD_VER             : [$PROD_VER]"
  echo "PROD_FP              : [$PROD_FP]"
  echo "PROD_HF              : [$PROD_HF]"
  echo "DOMLP_VER            : [$DOMLP_VER]"
  echo "DOMRESTAPI_VER       : [$DOMRESTAPI_VER]"
  echo "PROD_DOWNLOAD_FILE   : [$PROD_DOWNLOAD_FILE]"
  echo "PROD_FP_DOWNLOAD_FILE: [$PROD_FP_DOWNLOAD_FILE]"
  echo "PROD_HF_DOWNLOAD_FILE: [$PROD_HF_DOWNLOAD_FILE]"
  echo "PROD_EXT             : [$PROD_EXT]"
  echo "CHECK_SOFTWARE       : [$CHECK_SOFTWARE]"
  echo "CHECK_HASH           : [$CHECK_HASH]"
  echo "DOWNLOAD_URLS_SHOW   : [$DOWNLOAD_URLS_SHOW]"
  echo "TAG_LATEST           : [$TAG_LATEST]"
  echo "TAG_IMAGE            : [$TAG_IMAGE]"
  echo "PUSH_IMAGE           : [$PUSH_IMAGE]"
  echo "DOCKER_FILE          : [$DOCKER_FILE]"
  echo "VERSE_VERSION        : [$VERSE_VERSION]"
  echo "NOMAD_VERSION        : [$NOMAD_VERSION]"
  echo "CAPI_VERSION         : [$CAPI_VERSION]"
  echo "NOMADWEB_VERSION     : [$NOMADWEB_VERSION]"
  echo "MYSQL_INSTALL        : [$MYSQL_INSTALL]"
  echo "MSSQL_INSTALL        : [$MSSQL_INSTALL]"
  echo "BORG_INSTALL         : [$BORG_INSTALL]"
  echo "STARTSCRIPT_VER      : [$STARTSCRIPT_VER]"
  echo "EXPOSED_PORTS        : [$EXPOSED_PORTS]"
  echo "LinuxYumUpdate       : [$LinuxYumUpdate]"
  echo "DOMINO_LANG          : [$DOMINO_LANG]"
  echo "NAMESPACE            : [$CONTAINER_NAMESPACE]"
  echo "K8S_RUNAS_USER       : [$K8S_RUNAS_USER_SUPPORT]"
  echo "SPECIAL_CURL_ARGS    : [$SPECIAL_CURL_ARGS]"
  echo "BUILD_SCRIPT_OPTIONS : [$BUILD_SCRIPT_OPTIONS]"
  echo
  return 0
}

check_build_nginx_image()
{
  if [ -z "$NGINX_IMAGE_NAME" ]; then
    return 0
  fi

  local IMAGE_ID="$($CONTAINER_CMD inspect --format "{{.ID}}" $NGINX_IMAGE_NAME 2>/dev/null)"

  if [ -n "$IMAGE_ID" ]; then
    # Image already exists
    log "Info: $NGINX_IMAGE_NAME already exists"
    sleep 1
    return 0
  fi

  header "Building NGINX Image $NGINX_IMAGE_NAME ..."

  if [ -z "$NGINX_BASE_IMAGE" ]; then
    NGINX_BASE_IMAGE=registry.access.redhat.com/ubi9/ubi-minimal:latest
  fi

  # Get Build Time
  BUILDTIME=$(date +"%d.%m.%Y %H:%M:%S")

  # Switch to directory containing the dockerfiles
  cd dockerfiles

  export BUILDAH_FORMAT

  $CONTAINER_CMD build --no-cache $BUILD_OPTIONS $DOCKER_PULL_OPTION -f dockerfile_nginx -t $NGINX_IMAGE_NAME --build-arg NGINX_BASE_IMAGE=$NGINX_BASE_IMAGE .

  cd ..

}

nginx_start()
{
  # Create a nginx container hosting software download locally

  local IMAGE_NAME=nginx

  if [ -n "$NGINX_IMAGE_NAME" ]; then
    check_build_nginx_image
    IMAGE_NAME=$NGINX_IMAGE_NAME
  fi

  # Check if we already have this container in status exited
  STATUS="$($CONTAINER_CMD inspect --format '{{ .State.Status }}' $SOFTWARE_CONTAINER 2>/dev/null)"

  if [ -z "$STATUS" ]; then
    echo "Creating Docker container: $SOFTWARE_CONTAINER hosting [$SOFTWARE_DIR]"
    $CONTAINER_CMD run --name $SOFTWARE_CONTAINER -p $SOFTWARE_PORT:80 -v $SOFTWARE_DIR:/usr/share/nginx/html:Z -d $IMAGE_NAME
  elif [ "$STATUS" = "exited" ]; then
    echo "Starting existing Docker container: $SOFTWARE_CONTAINER"
    $CONTAINER_CMD start $SOFTWARE_CONTAINER
  fi

  echo "Starting Docker container: $SOFTWARE_CONTAINER"

  # Start local nginx container to host SW Repository

  SOFTWARE_REPO_IP="$($CONTAINER_CMD inspect --format '{{ .NetworkSettings.IPAddress }}' $SOFTWARE_CONTAINER 2>/dev/null)"
  if [ -z "$SOFTWARE_REPO_IP" ]; then
    echo "No specific IP address using host address"
    SOFTWARE_REPO_IP=$(hostname --all-ip-addresses | cut -f1 -d" "):$SOFTWARE_PORT
  fi

  DOWNLOAD_FROM=http://$SOFTWARE_REPO_IP
  echo "Hosting HCL Software repository on $DOWNLOAD_FROM"
  echo
}

nginx_stop()
{
  # Stop and remove SW repository

  $CONTAINER_CMD stop $SOFTWARE_CONTAINER
  $CONTAINER_CMD container rm $SOFTWARE_CONTAINER
  echo "Stopped & Removed Software Repository Container"
  echo
}

print_runtime()
{
  hours=$((SECONDS / 3600))
  seconds=$((SECONDS % 3600))
  minutes=$((seconds / 60))
  seconds=$((seconds % 60))
  h=""; m=""; s=""
  if [ ! $hours = "1" ] ; then h="s"; fi
  if [ ! $minutes = "1" ] ; then m="s"; fi
  if [ ! $seconds = "1" ] ; then s="s"; fi
  if [ ! $hours = 0 ] ; then echo "Completed in $hours hour$h, $minutes minute$m and $seconds second$s"
  elif [ ! $minutes = 0 ] ; then echo "Completed in $minutes minute$m and $seconds second$s"
  else echo "Completed in $seconds second$s"; fi
  echo
}

http_head_check()
{
  local CURL_RET=$($CURL_CMD -w 'RESP_CODE:%{response_code}\n' --silent --head "$1" | grep 'RESP_CODE:200')

  if [ -z "$CURL_RET" ]; then
    return 0
  else
    return 1
  fi
}

get_current_version()
{
  if [ -n "$DOWNLOAD_FROM" ]; then

    DOWNLOAD_FILE=$DOWNLOAD_FROM/$VERSION_FILE_NAME

    http_head_check "$DOWNLOAD_FILE"
    if [ "$?" = "1" ]; then
      DOWNLOAD_VERSION_FILE=$DOWNLOAD_FILE
    fi
  fi

  if [ -n "$DOWNLOAD_VERSION_FILE" ]; then
    echo "Getting current software version from [$DOWNLOAD_VERSION_FILE]"
    LINE=$($CURL_CMD --silent $DOWNLOAD_VERSION_FILE | grep "^$1|")
  else
    if [ ! -r "$VERSION_FILE" ]; then
      echo "No current version file found! [$VERSION_FILE]"
    else
      echo "Getting current software version from [$VERSION_FILE]"
      LINE=$(grep "^$1|" $VERSION_FILE)
    fi
  fi

  PROD_VER=$(echo $LINE|cut -d'|' -f2)
  PROD_FP=$(echo $LINE|cut -d'|' -f3)
  PROD_HF=$(echo $LINE|cut -d'|' -f4)

  return 0
}

get_current_addon_version()
{
  local S1=$2
  local S2=${!2}

  if [ -n "$DOWNLOAD_FROM" ]; then

    DOWNLOAD_FILE=$DOWNLOAD_FROM/$VERSION_FILE_NAME

    http_head_check "$DOWNLOAD_FILE"
    if [ "$?" = "1" ]; then
      DOWNLOAD_VERSION_FILE=$DOWNLOAD_FILE
    fi
  fi

  if [ -n "$DOWNLOAD_VERSION_FILE" ]; then
    echo "Getting current add-on version from [$DOWNLOAD_VERSION_FILE]"
    LINE=$($CURL_CMD --silent $DOWNLOAD_VERSION_FILE | grep "^$1|")
  else
    if [ ! -r "$VERSION_FILE" ]; then
      echo "No current version file found! [$VERSION_FILE]"
    else
      echo "Getting current software version from [$VERSION_FILE]"
      LINE=$(grep "^$1|" $VERSION_FILE)
    fi
  fi

  export $2=$(echo $LINE|cut -d'|' -f2 -s)

  return 0
}

copy_config_file()
{
  if [ -e "$CONFIG_FILE" ]; then
    echo "Config File [$CONFIG_FILE] already exists!"
    return 0
  fi

  mkdir -p $DOMINO_DOCKER_CFG_DIR
  if [ -e "$BUILD_CFG_FILE" ]; then
    cp "$BUILD_CFG_FILE" "$CONFIG_FILE"
  else
    echo "Cannot copy config file"
  fi
}

edit_config_file()
{
  if [ ! -e "$CONFIG_FILE" ]; then
    echo "Creating new config file [$CONFIG_FILE]"
    copy_config_file
  fi

  $EDIT_COMMAND $CONFIG_FILE
}

check_for_hcl_image()
{
  # If the base is the HCL Domino image,
  # Also bypass software download check.
  # But check if the image is available.

  case "$FROM_IMAGE" in

    domino-docker*)
      LINUX_NAME="HCL Base Image"
      BASE_IMAGE=$FROM_IMAGE
      ;;

    *)
      return 0
      ;;
  esac

  IMAGE_ID=$($CONTAINER_CMD $CONTAINER_NAMESPACE_CMD images $BASE_IMAGE -q)
  if [ -z "$IMAGE_ID" ]; then
    log_error_exit "Base image [$FROM_IMAGE] does not exist"
  fi

  # Derive version from Docker image name
  PROD_NAME=domino
  PROD_VER=$(echo $FROM_IMAGE | cut -d":" -f 2 -s)

  # don't check software
  CHECK_SOFTWARE=no
  CHECK_HASH=no
}

check_from_image()
{
  if [ -z "$FROM_IMAGE" ]; then

    if [ "$PROD_NAME" = "domino" ]; then
      LINUX_NAME="CentOS Stream"
      BASE_IMAGE=quay.io/centos/centos:stream8
    elif [ "$PROD_NAME" = "safelinx" ]; then
      LINUX_NAME="CentOS Stream"
      BASE_IMAGE=quay.io/centos/centos:stream8

    else
      BASE_IMAGE=hclcom/domino:latest
    fi

    return 0
  fi

  case "$FROM_IMAGE" in

    centos8)
      LINUX_NAME="CentOS Stream"
      BASE_IMAGE=quay.io/centos/centos:stream8
      ;;

    centos9)
      LINUX_NAME="CentOS Stream 9"
      BASE_IMAGE=quay.io/centos/centos:stream9
      ;;

    rocky)
      LINUX_NAME="Rocky Linux"
      BASE_IMAGE=rockylinux/rockylinux
      ;;

    rocky8)
      LINUX_NAME="Rocky Linux 8"
      BASE_IMAGE=rockylinux/rockylinux:8
      ;;

    rocky9)
      LINUX_NAME="Rocky Linux 9"
      BASE_IMAGE=rockylinux/rockylinux:9
      ;;

    alma)
      LINUX_NAME="Alma Linux"
      BASE_IMAGE=almalinux/almalinux
      ;;

    alma8)
      LINUX_NAME="Alma Linux"
      BASE_IMAGE=almalinux/almalinux:8
      ;;

    amazon)
      LINUX_NAME="Amazon Linux"
      BASE_IMAGE=amazonlinux
      ;;

    oracle)
      LINUX_NAME="Oracle Linux 8"
      BASE_IMAGE=oraclelinux:8
      ;;

    photon)
      LINUX_NAME="Photon OS"
      BASE_IMAGE=photon
      ;;

    ubi)
      LINUX_NAME="RedHat UBI"
      BASE_IMAGE=registry.access.redhat.com/ubi
      ;;

    ubi8)
      LINUX_NAME="RedHat UBI 8"
      BASE_IMAGE=registry.access.redhat.com/ubi8
      ;;

    ubi9)
      LINUX_NAME="RedHat UBI 9"
      BASE_IMAGE=registry.access.redhat.com/ubi9
      ;;

    ubi9-minimal)
      LINUX_NAME="RedHat UBI 9 minimal"
      BASE_IMAGE=registry.access.redhat.com/ubi9/ubi-minimal
      ;;

    leap)
      LINUX_NAME="SUSE Leap"
      BASE_IMAGE=opensuse/leap
      ;;

    leap15.3)
      LINUX_NAME="SUSE Leap 15.3"
      BASE_IMAGE=opensuse/leap:15.3
      ;;

    leap15.4)
      LINUX_NAME="SUSE Leap 15.4"
      BASE_IMAGE=opensuse/leap:15.4
      ;;

    bci)
      LINUX_NAME="SUSE Enterprise"
      BASE_IMAGE=registry.suse.com/bci/bci-base
      ;;

    bci15.3)
      LINUX_NAME="SUSE Enterprise 15.3"
      BASE_IMAGE=registry.suse.com/bci/bci-base:15.3
      ;;

    bci15.4)
      LINUX_NAME="SUSE Enterprise 15.4"
      BASE_IMAGE=registry.suse.com/bci/bci-base:15.4
      ;;

    astra)
      LINUX_NAME="Astra Linux"
      BASE_IMAGE=orel:latest
      ;;

    *)
      LINUX_NAME="Manual specified base image"
      BASE_IMAGE=$FROM_IMAGE
      echo "Info: Manual specified base image used! [$FROM_IMAGE]"
      ;;

  esac

  echo "base Image - $LINUX_NAME"
}


set_standard_image_labels()
{

  if [ -z "$CONTAINER_MAINTAINER" ]; then
    CONTAINER_MAINTAINER="thomas.hampel, daniel.nashed@nashcom.de"
  fi

  if [ -z "$CONTAINER_VENDOR" ]; then
    CONTAINER_VENDOR="Domino Container Community Project"
  fi

  if [ -z "$CONTAINER_DOMINO_NAME" ]; then
    CONTAINER_DOMINO_NAME="HCL Domino Community Image"
  fi

  if [ -z "$CONTAINER_DOMINO_DESCRIPTION" ]; then
    CONTAINER_DOMINO_DESCRIPTION="HCL Domino Enterprise Server"
  fi

  if [ -z "$CONTAINER_TRAVELER_NAME" ]; then
    CONTAINER_TRAVELER_NAME="HCL Traveler Community Image"
  fi

  if [ -z "$CONTAINER_TRAVELER_DESCRIPTION" ]; then
    CONTAINER_TRAVELER_DESCRIPTION="HCL Traveler Mobile Sync Server"
  fi

  if [ -z "$CONTAINER_VOLT_NAME" ]; then
    CONTAINER_VOLT_NAME="HCL Volt Community Image"
  fi

  if [ -z "$CONTAINER_VOLT_DESCRIPTION" ]; then
    CONTAINER_VOLT_DESCRIPTION="HCL Volt - Low Code platform"
  fi

  if [ -z "$CONTAINER_LEAP_NAME" ]; then
    CONTAINER_LEAP_NAME="HCL Domino Leap Community Image"
  fi

  if [ -z "$CONTAINER_LEAP_DESCRIPTION" ]; then
    CONTAINER_LEAP_DESCRIPTION="HCL Domino Leap - Low Code platform"
  fi


  if [ -z "$CONTAINER_SAFELINX_NAME" ]; then
    CONTAINER_SAFELINX_NAME="HCL SafeLinx Community Image"
  fi

  if [ -z "$CONTAINER_SAFELINX_DESCRIPTION" ]; then
    CONTAINER_SAFELINX_DESCRIPTION="HCL SafeLinx - Secure reverse proxy & VPN"
  fi

  if [ -z "$CONTAINER_OPENSHIFT_EXPOSED_SERVICES" ]; then
    CONTAINER_OPENSHIFT_EXPOSED_SERVICES="1352:nrpc 80:http 110:pop3 143:imap 389:ldap 443:https 636:ldaps 993:imaps 995:pop3s"
  fi

  if [ -z "$CONTAINER_OPENSHIFT_MIN_MEMORY" ]; then
    CONTAINER_OPENSHIFT_MIN_MEMORY="2Gi"
  fi

  if [ -z "$CONTAINER_OPENSHIFT_MIN_CPU" ]; then
    CONTAINER_OPENSHIFT_MIN_CPU=2
  fi

}

check_exposed_ports()
{

  # Allow custom exposed ports
  if [ -n "$EXPOSED_PORTS" ]; then
    return 0
  fi

  EXPOSED_PORTS="1352 25 80 110 143 389 443 636 993 995 63148 63149"

  if [ -n "$NOMAD_VERSION" ]; then
    EXPOSED_PORTS="1352 25 80 110 143 389 443 636 993 995 9443 63148 63149"
  fi

  return 0
}

build_domino()
{
  $CONTAINER_CMD build --no-cache $BUILD_OPTIONS $DOCKER_PULL_OPTION \
    $CONTAINER_NETWORK_CMD $CONTAINER_NAMESPACE_CMD \
    -t $DOCKER_IMAGE \
    -f $DOCKER_FILE \
    --label maintainer="$CONTAINER_MAINTAINER" \
    --label name="$CONTAINER_DOMINO_NAME" \
    --label vendor="$CONTAINER_VENDOR" \
    --label description="$CONTAINER_DOMINO_DESCRIPTION" \
    --label summary="$CONTAINER_DOMINO_DESCRIPTION" \
    --label version="$DOCKER_IMAGE_VERSION" \
    --label buildtime="$BUILDTIME" \
    --label release="$BUILDTIME" \
    --label architecture="x86_64" \
    --label io.k8s.description="$CONTAINER_DOMINO_DESCRIPTION" \
    --label io.k8s.display-name="$CONTAINER_DOMINO_NAME" \
    --label io.openshift.tags="domino" \
    --label io.openshift.expose-services="$CONTAINER_OPENSHIFT_EXPOSED_SERVICES" \
    --label io.openshift.non-scalable=true \
    --label io.openshift.min-memory="$CONTAINER_OPENSHIFT_MIN_MEMORY" \
    --label io.openshift.min-cpu="$CONTAINER_OPENSHIFT_MIN_CPU" \
    --label DominoContainer.maintainer="$CONTAINER_MAINTAINER" \
    --label DominoContainer.description="$CONTAINER_DOMINO_DESCRIPTION" \
    --label DominoContainer.version="$DOCKER_IMAGE_VERSION" \
    --label DominoContainer.buildtime="$BUILDTIME" \
    --build-arg PROD_NAME=$PROD_NAME \
    --build-arg PROD_VER=$PROD_VER \
    --build-arg DOMLP_VER=$DOMLP_VER \
    --build-arg DOMRESTAPI_VER=$DOMRESTAPI_VER \
    --build-arg PROD_FP=$PROD_FP \
    --build-arg PROD_HF=$PROD_HF \
    --build-arg PROD_DOWNLOAD_FILE=$PROD_DOWNLOAD_FILE \
    --build-arg PROD_FP_DOWNLOAD_FILE=$PROD_FP_DOWNLOAD_FILE \
    --build-arg PROD_HF_DOWNLOAD_FILE=$PROD_HF_DOWNLOAD_FILE \
    --build-arg DOCKER_TZ=$DOCKER_TZ \
    --build-arg BASE_IMAGE=$BASE_IMAGE \
    --build-arg DownloadFrom=$DOWNLOAD_FROM \
    --build-arg LinuxYumUpdate=$LinuxYumUpdate \
    --build-arg OPENSSL_INSTALL="$OPENSSL_INSTALL" \
    --build-arg BORG_INSTALL="$BORG_INSTALL" \
    --build-arg VERSE_VERSION="$VERSE_VERSION" \
    --build-arg NOMAD_VERSION="$NOMAD_VERSION" \
    --build-arg CAPI_VERSION="$CAPI_VERSION" \
    --build-arg MYSQL_INSTALL="$MYSQL_INSTALL" \
    --build-arg MSSQL_INSTALL="$MSSQL_INSTALL" \
    --build-arg STARTSCRIPT_VER="$STARTSCRIPT_VER" \
    --build-arg DOMINO_LANG="$DOMINO_LANG" \
    --build-arg K8S_RUNAS_USER_SUPPORT="$K8S_RUNAS_USER_SUPPORT" \
    --build-arg EXPOSED_PORTS="$EXPOSED_PORTS" \
    --build-arg SPECIAL_CURL_ARGS="$SPECIAL_CURL_ARGS" \
    --build-arg BUILD_SCRIPT_OPTIONS="$BUILD_SCRIPT_OPTIONS" .
}

build_traveler()
{
  $CONTAINER_CMD build --no-cache $BUILD_OPTIONS $DOCKER_PULL_OPTION \
    $CONTAINER_NETWORK_CMD $CONTAINER_NAMESPACE_CMD \
    -t $DOCKER_IMAGE \
    -f $DOCKER_FILE \
    --label maintainer="$CONTAINER_MAINTAINER" \
    --label name="$CONTAINER_TRAVELER_NAME" \
    --label vendor="$CONTAINER_VENDOR" \
    --label description="$CONTAINER_TRAVELER_DESCRIPTION" \
    --label summary="$CONTAINER_TRAVELER_NAME" \
    --label version="$DOCKER_IMAGE_VERSION" \
    --label buildtime="$BUILDTIME" \
    --label release="$BUILDTIME" \
    --label architecture="x86_64" \
    --label io.k8s.description="$CONTAINER_TRAVELER_DESCRIPTION" \
    --label io.k8s.display-name="$CONTAINER_TRAVELER_NAME" \
    --label io.openshift.tags="traveler" \
    --label io.openshift.expose-services="$CONTAINER_OPENSHIFT_EXPOSED_SERVICES" \
    --label io.openshift.non-scalable=true \
    --label io.openshift.min-memory="$CONTAINER_OPENSHIFT_MIN_MEMORY" \
    --label io.openshift.min-cpu="$CONTAINER_OPENSHIFT_MIN_CPU" \
    --label TravelerContainer.description="$CONTAINER_TRAVELER_DESCRIPTION" \
    --label TravelerContainer.version="$DOCKER_IMAGE_VERSION" \
    --label TravelerContainer.buildtime="$BUILDTIME" \
    --build-arg PROD_NAME="$PROD_NAME" \
    --build-arg PROD_VER="$PROD_VER" \
    --build-arg PROD_DOWNLOAD_FILE=$PROD_DOWNLOAD_FILE \
    --build-arg DownloadFrom="$DOWNLOAD_FROM" \
    --build-arg LinuxYumUpdate="$LinuxYumUpdate" \
    --build-arg BASE_IMAGE=$BASE_IMAGE \
    --build-arg SPECIAL_CURL_ARGS="$SPECIAL_CURL_ARGS" .
}

build_volt()
{
  $CONTAINER_CMD build --no-cache $BUILD_OPTIONS $DOCKER_PULL_OPTION \
    $CONTAINER_NETWORK_CMD $CONTAINER_NAMESPACE_CMD \
    -t $DOCKER_IMAGE \
    -f $DOCKER_FILE \
    --label maintainer="$CONTAINER_MAINTAINER" \
    --label name="$CONTAINER_VOLT_NAME" \
    --label vendor="$CONTAINER_VENDOR" \
    --label description="$CONTAINER_VOLT_DESCRIPTION" \
    --label summary="$CONTAINER_VOLT_DESCRIPTION" \
    --label version="$DOCKER_IMAGE_VERSION" \
    --label buildtime="$BUILDTIME" \
    --label release="$BUILDTIME" \
    --label architecture="x86_64" \
    --label io.k8s.description="$CONTAINER_VOLT_DESCRIPTION" \
    --label io.k8s.display-name="$CONTAINER_VOLT_NAME" \
    --label io.openshift.tags="volt" \
    --label io.openshift.expose-services="$CONTAINER_OPENSHIFT_EXPOSED_SERVICES" \
    --label io.openshift.non-scalable=true \
    --label io.openshift.min-memory="$CONTAINER_OPENSHIFT_MIN_MEMORY" \
    --label io.openshift.min-cpu="$CONTAINER_OPENSHIFT_MIN_CPU" \
    --label VoltContainer.description="$CONTAINER_VOLT_DESCRIPTION" \
    --label VoltContainer.version="$DOCKER_IMAGE_VERSION" \
    --label VoltContainer.buildtime="$BUILDTIME" \
    --build-arg PROD_NAME="$PROD_NAME" \
    --build-arg PROD_VER="$PROD_VER" \
    --build-arg PROD_DOWNLOAD_FILE=$PROD_DOWNLOAD_FILE \
    --build-arg DownloadFrom="$DOWNLOAD_FROM" \
    --build-arg LinuxYumUpdate="$LinuxYumUpdate" \
    --build-arg BASE_IMAGE=$BASE_IMAGE \
    --build-arg SPECIAL_CURL_ARGS="$SPECIAL_CURL_ARGS" .
}

build_leap()
{
  $CONTAINER_CMD build --no-cache $BUILD_OPTIONS $DOCKER_PULL_OPTION \
    $CONTAINER_NETWORK_CMD $CONTAINER_NAMESPACE_CMD \
    -t $DOCKER_IMAGE \
    -f $DOCKER_FILE \
    --label maintainer="$CONTAINER_MAINTAINER" \
    --label name="$CONTAINER_LEAP_NAME" \
    --label vendor="$CONTAINER_VENDOR" \
    --label description="$CONTAINER_LEAP_DESCRIPTION" \
    --label summary="$CONTAINER_LEAP_DESCRIPTION" \
    --label version="$DOCKER_IMAGE_VERSION" \
    --label buildtime="$BUILDTIME" \
    --label release="$BUILDTIME" \
    --label architecture="x86_64" \
    --label io.k8s.description="$CONTAINER_LEAP_DESCRIPTION" \
    --label io.k8s.display-name="$CONTAINER_LEAP_NAME" \
    --label io.openshift.tags="leap" \
    --label io.openshift.expose-services="$CONTAINER_OPENSHIFT_EXPOSED_SERVICES" \
    --label io.openshift.non-scalable=true \
    --label io.openshift.min-memory="$CONTAINER_OPENSHIFT_MIN_MEMORY" \
    --label io.openshift.min-cpu="$CONTAINER_OPENSHIFT_MIN_CPU" \
    --label LeapContainer.description="$CONTAINER_LEAP_DESCRIPTION" \
    --label LeapContainer.version="$DOCKER_IMAGE_VERSION" \
    --label LeapContainer.buildtime="$BUILDTIME" \
    --build-arg PROD_NAME="$PROD_NAME" \
    --build-arg PROD_VER="$PROD_VER" \
    --build-arg PROD_DOWNLOAD_FILE=$PROD_DOWNLOAD_FILE \
    --build-arg DownloadFrom="$DOWNLOAD_FROM" \
    --build-arg LinuxYumUpdate="$LinuxYumUpdate" \
    --build-arg BASE_IMAGE=$BASE_IMAGE \
    --build-arg SPECIAL_CURL_ARGS="$SPECIAL_CURL_ARGS" .
}

build_safelinx()
{
  $CONTAINER_CMD build --no-cache $BUILD_OPTIONS $DOCKER_PULL_OPTION \
    $CONTAINER_NETWORK_CMD $CONTAINER_NAMESPACE_CMD \
    -t $DOCKER_IMAGE \
    -f $DOCKER_FILE \
    --label maintainer="$CONTAINER_MAINTAINER" \
    --label name="$CONTAINER_SAFELINX_NAME" \
    --label vendor="$CONTAINER_VENDOR" \
    --label description="$CONTAINER_SAFELINX_DESCRIPTION" \
    --label summary="$CONTAINER_SAFELINX_DESCRIPTION" \
    --label version="$DOCKER_IMAGE_VERSION" \
    --label buildtime="$BUILDTIME" \
    --label release="$BUILDTIME" \
    --label architecture="x86_64" \
    --label io.k8s.description="$CONTAINER_SAFELINX_DESCRIPTION" \
    --label io.k8s.display-name="$CONTAINER_SAFELINX_NAME" \
    --label io.openshift.expose-services="80:http 443:https" \
    --label io.openshift.min-memory="2Gi" \
    --label io.openshift.min-cpu=2 \
    --label SafeLinxContainer.description="$CONTAINER_SAFELINX_DESCRIPTION" \
    --label SafeLinxContainer.version="$DOCKER_IMAGE_VERSION" \
    --label SafeLinxContainer.buildtime="$BUILDTIME" \
    --build-arg PROD_NAME="$PROD_NAME" \
    --build-arg PROD_VER="$PROD_VER" \
    --build-arg PROD_DOWNLOAD_FILE=$PROD_DOWNLOAD_FILE \
    --build-arg NOMADWEB_VERSION="$NOMADWEB_VERSION" \
    --build-arg MYSQL_INSTALL="$MYSQL_INSTALL" \
    --build-arg MSSQL_INSTALL="$MSSQL_INSTALL" \
    --build-arg DownloadFrom="$DOWNLOAD_FROM" \
    --build-arg LinuxYumUpdate="$LinuxYumUpdate" \
    --build-arg BASE_IMAGE=$BASE_IMAGE \
    --build-arg SPECIAL_CURL_ARGS="$SPECIAL_CURL_ARGS" .
}

docker_build()
{
  # Get product name from file name
  if [ -z $PROD_NAME ]; then
    log_error_exit "No product specified"
  fi

  if [ -z "$DOWNLOAD_FROM" ]; then
    log_error_exit "No download location specified!"
  fi

  #CUSTOM_VER=$(echo "$CUSTOM_VER" | awk '{print toupper($0)}')
  CUSTOM_FP=$(echo "$CUSTOM_FP" | awk '{print toupper($0)}')
  CUSTOM_HF=$(echo "$CUSTOM_HF" | awk '{print toupper($0)}')

  if [ -n "$CUSTOM_VER" ]; then
    PROD_VER=$CUSTOM_VER
    PROD_FP=$CUSTOM_FP
    PROD_HF=$CUSTOM_HF
  fi

  if [ -z "$DOCKER_IMAGE_NAME" ]; then
    DOCKER_IMAGE_NAME="hclcom/$PROD_NAME"
  fi

  DOCKER_IMAGE_VERSION=$PROD_VER$PROD_FP$PROD_HF$PROD_EXT

  if [ -z "$DOCKER_IMAGE_TAG" ]; then
    DOCKER_IMAGE_TAG=$PROD_VER$PROD_FP$PROD_HF$PROD_EXT
  fi

  # Set default or custom LATEST tag
  if [ -n "$TAG_LATEST" ]; then
    DOCKER_TAG_LATEST="$DOCKER_IMAGE_NAME:$TAG_LATEST"
  fi

  if [ "$CONTAINER_CMD" = "nerdctl" ]; then
    # Currently nerdctl cannot handle a second tag
    DOCKER_TAG_LATEST=
  fi

  echo "Building Image : " $IMAGENAME

  # Get Build Time
  BUILDTIME=$(date +"%d.%m.%Y %H:%M:%S")

  # Get build arguments
  DOCKER_IMAGE=$DOCKER_IMAGE_NAME:$DOCKER_IMAGE_TAG

  # Switch to directory containing the dockerfiles
  cd dockerfiles

  DOCKER_IMAGE_BUILD_VERSION=$DOCKER_IMAGE_VERSION

  export BUILDAH_FORMAT

  set_standard_image_labels

  case "$PROD_NAME" in

    domino)

      if [ -z "$DOCKER_FILE" ]; then
        DOCKER_FILE=dockerfile
      fi

      build_domino
      ;;

    traveler)

      DOCKER_FILE=dockerfile_traveler

      build_traveler
      ;;

    volt)

      DOCKER_FILE=dockerfile_volt
      build_volt
      ;;

    leap)

      DOCKER_FILE=dockerfile_leap
      build_leap
      ;;

    safelinx)

      DOCKER_FILE=dockerfile_safelinx

      build_safelinx
      ;;

    *)
      log_error_exit "Unknown product [$PROD_NAME] - Terminating installation"
      ;;
  esac

  if  [ ! "$?" = "0" ]; then
    log_error_exit "Image build failed!"
  fi

  cd $CURRENT_DIR

  # Test image via automation testing before tagging and uploading it
  auto_test

  if [ -n "$DOCKER_TAG_LATEST" ]; then
    $CONTAINER_CMD tag $DOCKER_IMAGE $DOCKER_TAG_LATEST
    echo
  fi

  if [ -n "$TAG_IMAGE" ]; then
    $CONTAINER_CMD tag $DOCKER_IMAGE $TAG_IMAGE
    echo
  fi

  if [ -n "$PUSH_IMAGE" ]; then
    $CONTAINER_CMD tag $DOCKER_IMAGE $PUSH_IMAGE

    header "Pushing image $PUSH_IMAGE to registry"
    $CONTAINER_CMD push $PUSH_IMAGE
    echo
  fi

  # Save/Export image if requested
  docker_save

  echo
  return 0
}

check_software()
{
  CURRENT_NAME=$(echo $1|cut -d'|' -f1)
  CURRENT_VER=$(echo $1|cut -d'|' -f2)
  CURRENT_FILES=$(echo $1|cut -d'|' -f3)
  CURRENT_PARTNO=$(echo $1|cut -d'|' -f4)
  CURRENT_HASH=$(echo $1|cut -d'|' -f5)

  if [ -z "$DOWNLOAD_FROM" ]; then

    FOUND=
    DOWNLOAD_1ST_FILE=

    for CHECK_FILE in $(echo "$CURRENT_FILES" | tr "," "\n"); do

      # Check for absolute download link
      case "$CHECK_FILE" in

        *://*)
          if [ -z "$DOWNLOAD_1ST_FILE" ]; then
            DOWNLOAD_1ST_FILE=$(basename $CHECK_FILE)
          fi

          http_head_check "$CHECK_FILE"
          if [ "$?" = "1" ]; then
            CURRENT_FILE="$CHECK_FILE"
            FOUND=TRUE
            break
          fi
          ;;

        *)
          if [ -z "$DOWNLOAD_1ST_FILE" ]; then
            DOWNLOAD_1ST_FILE=$CHECK_FILE
          fi

          if [ -r "$SOFTWARE_DIR/$CHECK_FILE" ]; then
            CURRENT_FILE="$CHECK_FILE"
            FOUND=TRUE
            break
          fi
          ;;
      esac
    done

    if [ "$FOUND" = "TRUE" ]; then
      if [ -z "$CURRENT_HASH" ]; then
        CURRENT_STATUS="NA"
      else
        if [ ! "$CHECK_HASH" = "yes" ]; then
          CURRENT_STATUS="OK"
        else

          case "$CHECK_FILE" in

            *://*)
              HASH=$($CURL_CMD --silent $CHECK_FILE 2>/dev/null | sha256sum -b | cut -d" " -f1)
              ;;

            *)
              HASH=$(sha256sum $SOFTWARE_DIR/$CURRENT_FILE -b | cut -d" " -f1)
              ;;
          esac

          if [ "$CURRENT_HASH" = "$HASH" ]; then
            CURRENT_STATUS="OK"
          else
            CURRENT_STATUS="CR"
          fi
        fi
      fi
    else
      CURRENT_STATUS="NA"
    fi
  else

    FOUND=
    DOWNLOAD_1ST_FILE=

    for CHECK_FILE in $(echo "$CURRENT_FILES" | tr "," "\n") ; do

      # Check for absolute download link
      case "$CHECK_FILE" in
        *://*)
          DOWNLOAD_FILE=$CHECK_FILE

           if [ -z "$DOWNLOAD_1ST_FILE" ]; then
             DOWNLOAD_1ST_FILE=$(basename $CHECK_FILE)
           fi

          ;;

        *)
          DOWNLOAD_FILE=$DOWNLOAD_FROM/$CHECK_FILE

          if [ -z "$DOWNLOAD_1ST_FILE" ]; then
            DOWNLOAD_1ST_FILE=$CHECK_FILE
          fi
          ;;
      esac

      http_head_check "$DOWNLOAD_FILE"
      if [ "$?" = "1" ]; then
        CURRENT_FILE="$CHECK_FILE"
        FOUND=TRUE
        break
      fi
    done

    if [ ! "$FOUND" = "TRUE" ]; then
      CURRENT_STATUS="NA"
    else
      if [ -z "$CURRENT_HASH" ]; then
        CURRENT_STATUS="OK"
      else
        if [ ! "$CHECK_HASH" = "yes" ]; then
          CURRENT_STATUS="OK"
        else
          HASH=$($CURL_CMD --silent $DOWNLOAD_FILE 2>/dev/null | sha256sum -b | cut -d" " -f1)

          if [ "$CURRENT_HASH" = "$HASH" ]; then
            CURRENT_STATUS="OK"
          else
            CURRENT_STATUS="CR"
          fi
        fi
      fi
    fi
  fi

  CURRENT_DOWNLOAD_URL=""

  case "$CURRENT_NAME" in

    domino|traveler|volt|leap|verse|nomad|capi|borg|safelinx|nomadweb)

      if [ -n "$DOWNLOAD_1ST_FILE" ]; then
        if [ -z "$CURRENT_PARTNO" ]; then
          CURRENT_DOWNLOAD_URL="$DOWNLOAD_LINK_FLEXNET$DOWNLOAD_1ST_FILE$DOWNLOAD_LINK_FLEXNET_OPTIONS"
        elif [ "$CURRENT_PARTNO" = "-" ]; then
          CURRENT_DOWNLOAD_URL="$DOWNLOAD_LINK_FLEXNET$DOWNLOAD_1ST_FILE$DOWNLOAD_LINK_FLEXNET_OPTIONS"
        else
          CURRENT_DOWNLOAD_URL="$DOWNLOAD_LINK_FLEXNET$DOWNLOAD_1ST_FILE$DOWNLOAD_LINK_FLEXNET_OPTIONS"
        fi
      fi
      ;;

    startscript)

      STARTSCRIPT_FILE=domino-startscript_v${CURRENT_VER}.taz
      CURRENT_DOWNLOAD_URL=${STARTSCRIPT_GIT_URL}/releases/download/v${CURRENT_VER}/domino-startscript_v${CURRENT_VER}.taz
     ;;

    *)
      CURRENT_DOWNLOAD_URL=""
      ;;
  esac

  count=$(echo $CURRENT_VER | wc -c)
  while [[ $count -lt 20 ]] ;
  do
    CURRENT_VER="$CURRENT_VER "
    count=$((count+1));
  done;

  echo "$CURRENT_VER [$CURRENT_STATUS] $DOWNLOAD_1ST_FILE"

  if [ ! -z "$DOWNLOAD_URLS_SHOW" ]; then
    echo $CURRENT_DOWNLOAD_URL
  elif [ ! "$CURRENT_STATUS" = "OK" ]; then
    echo $CURRENT_DOWNLOAD_URL
    echo
    DOWNLOAD_ERROR_COUNT=$((DOWNLOAD_ERROR_COUNT+1))
  fi

  return 0
}

check_software_file()
{
  FOUND=""

  if [ -z "$PROD_NAME" ]; then
    echo
    echo "--- $1 ---"
    echo
  fi

  if [ -z "$2" ]; then
    SEARCH_STR="^$1|"
  else
    SEARCH_STR="^$1|$2|"
  fi

  if [ -z "$DOWNLOAD_SOFTWARE_FILE" ]; then

    while read LINE
    do
      check_software $LINE
      FOUND="TRUE"
    done < <(grep "$SEARCH_STR" $SOFTWARE_FILE)
  else
    while read LINE
    do
      check_software $LINE
      FOUND="TRUE"
    done < <($CURL_CMD --silent $DOWNLOAD_SOFTWARE_FILE | grep "$SEARCH_STR")
  fi

  if [ -z "$PROD_NAME" ]; then
    echo
  else
    if [ ! "$FOUND" = "TRUE" ]; then

      CURRENT_VER=$2
      count=$(echo $CURRENT_VER | wc -c)
      while [[ $count -lt 20 ]] ;
      do
        CURRENT_VER="$CURRENT_VER "
        count=$((count+1));
      done;

      echo "$CURRENT_VER [NA] $1 - Not found in software file!"
      DOWNLOAD_ERROR_COUNT=$((DOWNLOAD_ERROR_COUNT+1))
    fi
  fi
}

check_software_status()
{
  if [ ! -z "$DOWNLOAD_FROM" ]; then

    DOWNLOAD_FILE=$DOWNLOAD_FROM/$SOFTWARE_FILE_NAME

    http_head_check "$DOWNLOAD_FILE"
    if [ "$?" = "1" ]; then
      DOWNLOAD_SOFTWARE_FILE=$DOWNLOAD_FILE
      echo "Checking software via [$DOWNLOAD_SOFTWARE_FILE]"
    fi

  else

    if [ ! -r "$SOFTWARE_FILE" ]; then
      echo "Software [$SOFTWARE_FILE] Not found!"
      DOWNLOAD_ERROR_COUNT=99
      return 1
    else
      echo "Checking software via [$SOFTWARE_FILE]"
    fi
  fi

  if [ -z "$PROD_NAME" ]; then
    check_software_file "domino"
    check_software_file "traveler"
    check_software_file "volt"
    check_software_file "leap"
    check_software_file "safelinx"

    if [ -n "$VERSE_VERSION" ]; then
      check_software_file "verse" "$VERSE_VERSION"
    fi

    if [ -n "$DOMLP_VER" ]; then
      check_software_file "domlp" "$DOMLP_VER"
    fi

    if [ -n "$DOMRESTAPI_VER" ]; then
      check_software_file "domrestapi" "$DOMRESTAPI_VER"
    fi

    if [ -n "$NOMAD_VERSION" ]; then
      check_software_file "nomad" "$NOMAD_VERSION"
    fi

    if [ -n "$NOMADWEB_VERSION" ]; then
      check_software_file "nomadweb" "$NOMADWEB_VERSION"
    fi

    if [ -n "$CAPI_VERSION" ]; then
      check_software_file "capi" "$CAPI_VERSION"
    fi

    if [ -n "$STARTSCRIPT_VER" ]; then
      check_software_file "startscript" "$STARTSCRIPT_VER"
    fi

    if [ -n "$BORG_INSTALL" ]; then
      if [ ! "$BORG_INSTALL" = "yes" ]; then
        check_software_file "borg" "$BORG_INSTALL"
      fi
    fi

  else
    echo

    if [ -z "$PROD_VER" ]; then
      check_software_file "$PROD_NAME"
    else

      if [ -z "$PROD_DOWNLOAD_FILE" ]; then
        check_software_file "$PROD_NAME" "$PROD_VER"
      else

        if [ -z "$DOWNLOAD_FROM" ]; then

          if [ -e "$SOFTWARE_DIR/$PROD_DOWNLOAD_FILE" ]; then
            echo "Info: Not checking download file [$SOFTWARE_DIR/$PROD_DOWNLOAD_FILE]"
          else
            echo "Download file not found [$SOFTWARE_DIR/$PROD_DOWNLOAD_FILE]"
            exit 1
          fi

        else

          http_head_check "$DOWNLOAD_FROM/$PROD_DOWNLOAD_FILE"
          if [ "$?" = "1" ]; then
            echo "Info: Not checking download file [$DOWNLOAD_FROM/$PROD_DOWNLOAD_FILE]"
          else
            echo "Download file not found [$DOWNLOAD_FROM/$PROD_DOWNLOAD_FILE]"
            exit 1
          fi
        fi

      fi

      if [ -n "$PROD_FP" ]; then
        if [ -z "$PROD_FP_DOWNLOAD_FILE" ]; then
          check_software_file "$PROD_NAME" "$PROD_VER$PROD_FP"

        else

          if [ -z "$DOWNLOAD_FROM" ]; then

            if [ -e "$SOFTWARE_DIR/$PROD_FP_DOWNLOAD_FILE" ]; then
              echo "Info: Not checking download file [$SOFTWARE_DIR/$PROD_FP_DOWNLOAD_FILE]"
            else
              echo "Download file not found [$SOFTWARE_DIR/$PROD_FP_DOWNLOAD_FILE]"
              exit 1
            fi

          else

            http_head_check "$DOWNLOAD_FROM/$PROD_FP_DOWNLOAD_FILE"
            if [ "$?" = "1" ]; then
              echo "Info: Not checking download file [$DOWNLOAD_FROM/$PROD_FP_DOWNLOAD_FILE]"
            else
              echo "Download file not found [$DOWNLOAD_FROM/$PROD_FP_DOWNLOAD_FILE]"
              exit 1
            fi
          fi

        fi
      fi

      if [ -n "$PROD_HF" ]; then

        if [ -z "$PROD_HF_DOWNLOAD_FILE" ]; then
          check_software_file "$PROD_NAME" "$PROD_VER$PROD_FP$PROD_HF"

        else

          if [ -z "$DOWNLOAD_FROM" ]; then

            if [ -e "$SOFTWARE_DIR/$PROD_HF_DOWNLOAD_FILE" ]; then
              echo "Info: Not checking download file [$SOFTWARE_DIR/$PROD_HF_DOWNLOAD_FILE]"
            else
              echo "Download file not found [$SOFTWARE_DIR/$PROD_HF_DOWNLOAD_FILE]"
              exit 1
            fi

          else

            http_head_check "$DOWNLOAD_FROM/$PROD_HF_DOWNLOAD_FILE"
            if [ "$?" = "1" ]; then
              echo "Info: Not checking download file [$DOWNLOAD_FROM/$PROD_HF_DOWNLOAD_FILE]"
            else
              echo "Download file not found [$DOWNLOAD_FROM/$PROD_HF_DOWNLOAD_FILE]"
              exit 1
            fi
          fi

        fi
      fi
    fi

    if [ -n "$VERSE_VERSION" ]; then
      check_software_file "verse" "$VERSE_VERSION"
    fi

    if [ -n "$DOMLP_VER" ]; then
      check_software_file "domlp" "$DOMLP_VER"
    fi

    if [ -n "$DOMRESTAPI_VER" ]; then
      check_software_file "domrestapi" "$DOMRESTAPI_VER"
    fi

    if [ -n "$NOMAD_VERSION" ]; then
      check_software_file "nomad" "$NOMAD_VERSION"
    fi

    if [ -n "$NOMADWEB_VERSION" ]; then
      check_software_file "nomadweb" "$NOMADWEB_VERSION"
    fi

    if [ -n "$CAPI_VERSION" ]; then
      check_software_file "capi" "$CAPI_VERSION"
    fi

    if [ -n "$STARTSCRIPT_VER" ]; then
      check_software_file "startscript" "$STARTSCRIPT_VER"
    fi

    if [ -n "$BORG_INSTALL" ]; then
      if [ ! "$BORG_INSTALL" = "yes" ]; then
        check_software_file "borg" "$BORG_INSTALL"
      fi
    fi

    echo
  fi
}

check_all_software()
{
  SOFTWARE_FILE=$SOFTWARE_DIR/software.txt

  # if software file isn't found check standard location (check might lead to the same directory if standard location already)
  if [ ! -e "$SOFTWARE_FILE" ]; then
    SOFTWARE_FILE=$PWD/software/$SOFTWARE_FILE_NAME
  fi

  DOWNLOAD_LINK_FLEXNET="https://hclsoftware.flexnetoperations.com/flexnet/operationsportal/DownloadSearchPage.action?search="
  DOWNLOAD_LINK_FLEXNET_OPTIONS="+&resultType=Files&sortBy=eff_date&listButton=Search"
  STARTSCRIPT_GIT_URL=https://github.com/nashcom/domino-startscript

  DOWNLOAD_ERROR_COUNT=0

  check_software_status

  if [ ! "$DOWNLOAD_ERROR_COUNT" = "0" ]; then
    echo "Correct Software Download Error(s) before building image [$DOWNLOAD_ERROR_COUNT]"

    if [ -z "$DOWNLOAD_FROM" ]; then
      if [ -z $SOFTWARE_DIR ]; then
        echo "No download location or software directory specified!"
        DOWNLOAD_ERROR_COUNT=99
      else
        echo "Copy files to [$SOFTWARE_DIR]"
      fi
    else
      echo "Upload files to [$DOWNLOAD_FROM]"
    fi

    echo
  fi

  CHECK_SOFTWARE_STATUS=$DOWNLOAD_ERROR_COUNT
}

docker_save()
{
  if [ -z "$DOCKER_IMAGE_EXPORT_NAME" ]; then
    return 0
  fi

  header "Exporting $DOCKER_IMAGE -> $DOCKER_IMAGE_EXPORT_NAME"

  $CONTAINER_CMD save $DOCKER_IMAGE | gzip > $DOCKER_IMAGE_EXPORT_NAME

  if [ "$?" = "0" ]; then
    IMAGE_SIZE=$(du -h $DOCKER_IMAGE_EXPORT_NAME)
    log "Exported container image: $IMAGE_SIZE"
  else
    log "Error exporting container image!"
  fi

  return 0
}

auto_test()
{
  if [ "$AutoTestImage" != "yes" ]; then
    return 0
  fi

  $SCRIPT_DIR/testing/AutomationTest.sh -image="$DOCKER_IMAGE"

  local ret=$?

  if [ "$ret" != "0" ]; then
    log_error_exit "Automation testing for image [$DOCKER_IMAGE failed] with $ret automation test errors!" 
  fi

  log "Automation testing for new image [$DOCKER_IMAGE] successful!"
}


# --- Main script logic ---

SOFTWARE_PORT=7777
SOFTWARE_FILE_NAME=software.txt
SOFTWARE_CONTAINER=hclsoftware
CURL_CMD="curl --location --max-redirs 10 --fail --connect-timeout 15 --max-time 300 $SPECIAL_CURL_ARGS"

VERSION_FILE_NAME=current_version.txt

# Use vi if no other editor specified in config

if [ -z "$EDIT_COMMAND" ]; then
  EDIT_COMMAND="vi"
fi

# Default config directory. Can be overwritten by environment

if [ -z "$BUILD_CFG_FILE"]; then
  BUILD_CFG_FILE=build.cfg
fi

if [ -z "$DOMINO_DOCKER_CFG_DIR" ]; then

  # Check for legacy config else use new location in user home

  if [ -r /local/cfg/build_config ]; then
    DOMINO_DOCKER_CFG_DIR=/local/cfg
    CONFIG_FILE=$DOMINO_DOCKER_CFG_DIR/build_config

  elif [ -r ~/DominoDocker/build.cfg ]; then
    DOMINO_DOCKER_CFG_DIR=~/DominoDocker
    CONFIG_FILE=$DOMINO_DOCKER_CFG_DIR/build.cfg

  elif [ -r ~/.DominoDocker/build.cfg ]; then
    DOMINO_DOCKER_CFG_DIR=~/.DominoDocker
    CONFIG_FILE=$DOMINO_DOCKER_CFG_DIR/build.cfg

  else
    DOMINO_DOCKER_CFG_DIR=~/.DominoContainer
    CONFIG_FILE=$DOMINO_DOCKER_CFG_DIR/$BUILD_CFG_FILE
  fi
fi

# Use a config file if present

if [ -r "$CONFIG_FILE" ]; then
  echo "(Using config file $CONFIG_FILE)"
  . $CONFIG_FILE
else
  if [ -r "$BUILD_CFG_FILE" ]; then
    . "$BUILD_CFG_FILE"
  fi
fi

VERSION_FILE=$SOFTWARE_DIR/$VERSION_FILE_NAME

# If version file isn't found check standard location (check might lead to the same directory if standard location already)
if [ ! -e "$VERSION_FILE" ]; then
  VERSION_FILE=$PWD/software/$VERSION_FILE_NAME
fi

if [ -z "$1" ]; then
  usage
  exit 0
fi

# Special commands
if [ "$1" = "save" ]; then
  if [ -z "$3" ]; then
    log_error_exit "Invalid syntax! Usage: $0 save <image name> <export name>"
  fi

  # get and check container environment (usually initialized after getting all the options)
  get_container_environment
  check_container_environment

  header "Exporting $2 -> $3 - This takes some time ..."
  $CONTAINER_CMD save "$2" | gzip > "$3"

  if [ "$?" = "0" ]; then
    IMAGE_SIZE=$(du -h $3)
    log "Exported container image: $IMAGE_SIZE"
  else
    log_error_exit "Error exporting container image!"
  fi

  exit 0
fi

# Install OpenSSL by default
if [ -z "$OPENSSL_INSTALL" ]; then
  OPENSSL_INSTALL=yes
fi

for a in $@; do

  p=$(echo "$a" | awk '{print tolower($0)}')

  case "$p" in
    domino|traveler|volt|leap|safelinx)
      PROD_NAME=$p
      ;;

    -verse*|+verse*)
      VERSE_VERSION=$(echo "$a" | cut -f2 -d= -s)

      if [ -z "$VERSE_VERSION" ]; then
        get_current_addon_version verse VERSE_VERSION
      fi
      ;;

   -nomadweb*|+nomadweb*)
      NOMADWEB_VERSION=$(echo "$a" | cut -f2 -d= -s)

      if [ -z "$NOMADWEB_VERSION" ]; then
        get_current_addon_version nomadweb NOMADWEB_VERSION
      fi
      ;;

    -nomad*|+nomad*)
      NOMAD_VERSION=$(echo "$a" | cut -f2 -d= -s)

      if [ -z "$NOMAD_VERSION" ]; then
        get_current_addon_version nomad NOMAD_VERSION
      fi
      ;;

   -mysql*|+mysql*)
      MYSQL_INSTALL=yes
      ;;

   -mssql*|+mssql*)
      MSSQL_INSTALL=yes
      ;;

   -capi*|+capi*)
      CAPI_VERSION=$(echo "$a" | cut -f2 -d= -s)

      if [ -z "$CAPI_VERSION" ]; then
        get_current_addon_version capi CAPI_VERSION
      fi
      ;;

    -startscript=*|+startscript=*)
      STARTSCRIPT_VER=$(echo "$a" | cut -f2 -d= -s)
      ;;

    -from=*)
      FROM_IMAGE=$(echo "$a" | cut -f2 -d= -s)
      ;;

    -imagename=*)
      DOCKER_IMAGE_NAME=$(echo "$a" | cut -f2 -d= -s)
      ;;

    -imagetag=*)
      DOCKER_IMAGE_TAG=$(echo "$a" | cut -f2 -d= -s)
      ;;

    -save=*)
      DOCKER_IMAGE_EXPORT_NAME=$(echo "$a" | cut -f2 -d= -s)
      ;;

    -tz=*)
      DOCKER_TZ=$(echo "$a" | cut -f2 -d= -s)
      ;;

    -pull)
      DOCKER_PULL_OPTION="--pull" 
      ;;

   -tag=*)
      TAG_IMAGE=$(echo "$a" | cut -f2 -d= -s)
      ;;

   -push=*)
      PUSH_IMAGE=$(echo "$a" | cut -f2 -d= -s)
      ;;

   -prod_download=*)
      PROD_DOWNLOAD_FILE=$(echo "$a" | cut -f2 -d= -s)
      ;;


   -fp_download=*)
      PROD_FP_DOWNLOAD_FILE=$(echo "$a" | cut -f2 -d= -s)
      ;;

   -hf_download=*)
      PROD_HF_DOWNLOAD_FILE=$(echo "$a" | cut -f2 -d= -s)
      ;;

   -nginx=*)
      NGINX_IMAGE_NAME=$(echo "$a" | cut -f2 -d= -s)
      ;;

  -nginxbase=*)
      NGINX_BASE_IMAGE=$(echo "$a" | cut -f2 -d= -s)
      ;;

    9*|10*|11*|12*|14*|v12*|v14*)
      PROD_VER=$a
      ;;

    fp*)
      PROD_FP=$p
      ;;

    beta*)
      PROD_FP=$p
      ;;

    hf*|if*)
      PROD_HF=$p
      ;;

    -domlp=*)
      DOMLP_VER=$(echo "$a" | cut -f2 -d= -s)
      ;;

    -restapi*|+restapi*)
      DOMRESTAPI_VER=$(echo "$a" | cut -f2 -d= -s)

      if [ -z "$DOMRESTAPI_VER" ]; then
        get_current_addon_version domrestapi DOMRESTAPI_VER
      fi

      ;;

    _*)
      PROD_EXT=$a
      ;;

    # Special for other latest tags
    latest*)
      TAG_LATEST=$a
      ;;

    dockerfile*)
      DOCKER_FILE=$a
      ;;

    domino-docker:*)
      # To build on top of HCL image
      FROM_IMAGE=$a
      DOCKER_FILE=dockerfile_hcl
      ;;

    cfg|config)
      edit_config_file
      exit 0
      ;;

    cpcfg)
      copy_config_file
      exit 0
      ;;

    -checkonly)
      BUILD_IMAGE=no
      CHECK_SOFTWARE=yes
      ;;

    -check)
      CHECK_SOFTWARE=yes
      ;;

    -nocheck)
      CHECK_SOFTWARE=no
      ;;

    -verifyonly)
      BUILD_IMAGE=no
      CHECK_SOFTWARE=yes
      CHECK_HASH=yes
      ;;

    -verify)
      CHECK_SOFTWARE=yes
      CHECK_HASH=yes
      ;;

    -noverify)
      CHECK_HASH=no
      ;;

    -url)
      DOWNLOAD_URLS_SHOW=yes
      ;;

    -nourl)
      DOWNLOAD_URLS_SHOW=no
      ;;

    -linuxupd)
      LinuxYumUpdate=yes
      ;;

    -nolinuxupd)
      LinuxYumUpdate=no
      ;;

    -autotest)
      AutoTestImage=yes
      ;;

    -borg|-borg=*)
      BORG_INSTALL=$(echo "$a" | cut -f2 -d= -s)

      if [ -z "$BORG_INSTALL" ]; then
        get_current_addon_version borg BORG_INSTALL
      fi

      if [ -z "$BORG_INSTALL" ]; then
        BORG_INSTALL=yes
      fi
      ;;

    -openssl)
      OPENSSL_INSTALL=yes
      ;;

   -noopenssl)
      OPENSSL_INSTALL=no
      ;;

    -k8s-runas)
      K8S_RUNAS_USER_SUPPORT=yes
      ;;

    *)
      log_error_exit "Invalid parameter [$a]"
      ;;
  esac
done

check_timezone
get_container_environment
check_container_environment

echo "[Running in $CONTAINER_CMD configuration]"

# In case software directory is not set and the well know location is filled with software

if [ -z "$SOFTWARE_DIR" ]; then
  SOFTWARE_DIR=$PWD/software
fi

if [ -z "$DOWNLOAD_FROM" ]; then
  SOFTWARE_USE_NGINX=1
fi

if [ -z "$DOWNLOAD_FROM" ]; then

  echo "Getting software from [$SOFTWARE_DIR]"
else
  echo "Getting software from [$DOWNLOAD_FROM]"
fi

if [ -z "$PROD_VER" ]; then
  PROD_VER="latest"
fi

if [ -z "$BUILD_OPTIONS" ]; then
  BUILD_OPTIONS="--platform linux/amd64"
fi

check_for_hcl_image
check_from_image

if [ "$PROD_VER" = "latest" ]; then
  get_current_version "$PROD_NAME"

  if [ -z "$TAG_LATEST" ]; then
    TAG_LATEST="latest"
  fi
fi

# Calculate the right version for Language Pack
if [ -n "$DOMLP_VER" ]; then
  DOMLP_VER=$DOMLP_VER-$PROD_VER
fi

# Calculate the right version for Nomad server for selected Domino version
if [ -n "$NOMAD_VERSION" ]; then

  # Allow to specify explict nomad version (currently identified by "-". might change in future )
  case "$NOMAD_VERSION" in

    *-*)
      ;;

    *)
      NOMAD_VERSION=$NOMAD_VERSION-$PROD_VER
      ;;
  esac
fi

check_exposed_ports

# Ensure product versions are always uppercase
#PROD_VER=$(echo "$PROD_VER" | awk '{print toupper($0)}')
PROD_FP=$(echo "$PROD_FP" | awk '{print toupper($0)}')
PROD_HF=$(echo "$PROD_HF" | awk '{print toupper($0)}')

echo
echo "Product to install: $PROD_NAME $PROD_VER $PROD_FP $PROD_HF"
echo

dump_config

if [ "$CHECK_SOFTWARE" = "yes" ]; then
  check_all_software

  if [ ! "$CHECK_SOFTWARE_STATUS" = "0" ]; then
    #Terminate if status is not OK. Errors are already logged
    exit 0
  fi
fi

if [ "$BUILD_IMAGE" = "no" ]; then
  # no build requested
  exit 0
fi

if [ -z "$DOWNLOAD_FROM" ]; then
  SOFTWARE_USE_NGINX=1

  if [ -z "$SOFTWARE_DIR" ]; then
    SOFTWARE_DIR=$PWD/software
  fi
fi

echo

if [ -z "$PROD_NAME" ]; then
  log_error_exit "No product specified! - Terminating"
fi

if [ -z "$PROD_VER" ]; then
  log_error_exit "No Target version specified! - Terminating"
fi

# Podman started to use OCI images by default. We still want Docker image format

if [ -z "$BUILDAH_FORMAT" ]; then
  BUILDAH_FORMAT=docker
fi

if [ "$SOFTWARE_USE_NGINX" = "1" ]; then
  nginx_start
fi

CURRENT_DIR=$(pwd)

docker_build

cd "$CURRENT_DIR"

if [ "$SOFTWARE_USE_NGINX" = "1" ]; then
  nginx_stop
fi

print_runtime

exit 0
