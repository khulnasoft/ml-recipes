#!/bin/bash

printf "Starting ML Hub\n"

incoming_args="$ADDITIONAL_ARGS"
execution_mode=${EXECUTION_MODE:-local}
if [ "$execution_mode" == "k8s" ]; then
  # make changes to nginx so that it works in Kubernetes as well
  # TODO: build into run_nginx.py script
  sed -i 's/resolver 127.0.0.11/resolver kube-dns.kube-system.svc.cluster.local/g' /etc/nginx/nginx.conf
  namespace="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)"
  sed -i "s/set \$service_suffix ''/set \$service_suffix .$namespace.svc.cluster.local/g" /etc/nginx/nginx.conf

  # Preserve Kubernetes-specific environment variables for sshd process
  echo "export KUBERNETES_SERVICE_HOST=$KUBERNETES_SERVICE_HOST" >> $SSHD_ENVIRONMENT_VARIABLES
  echo "export KUBERNETES_SERVICE_PORT=$KUBERNETES_SERVICE_PORT" >> $SSHD_ENVIRONMENT_VARIABLES
else
  if ! echo $HUB_NAME | pcregrep "^(?![0-9]+$)(?!-)[a-zA-Z0-9-]{1,5}(?<!-)$" > /dev/null; then
    echo "Container name for ml-recipes is either too long or not DNS-compatible. Make sure that a DNS-compatible name (--env HUB_NAME) with 1 to 5 characters is provided for the ml-recipes container."
    exit 1
  fi
fi

# create / copy certificates
$_RESOURCES_PATH/scripts/setup_certs.sh

function start_ssh {
    # See the documentation of the ssh-proxy image - the image this hub image is based on - for more information

    echo "Start SSH Daemon service"
    export SSH_TARGET_LABELS="mlrecipes.origin=$HUB_NAME"
    # Run ssh-bastion image entrypoint
    nohup python $_RESOURCES_PATH/start_ssh.py &
}

function start_jupyterhub {
    # Start server
    echo "Start JupyterHub"
    jupyterhub -f $_RESOURCES_PATH/jupyterhub_config.py &
}

function start_http_proxy {
    echo "Start configurable-http-proxy"
    configurable-http-proxy $incoming_args &
}

if [ "${START_SSH}" == true ]; then
  start_ssh
fi

if [ "${START_JHUB}" == true ]; then
  start_jupyterhub
fi

if [ "${START_CHP}" == true ]; then
  start_http_proxy
fi

if [ "${START_NGINX}" == true ]; then
  # It is possible to override the default sshd target with this command,
  # e.g. if it runs in a different container
  if [ ! -z "${SSHD_TARGET}" ]; then
    sed -i "s/127.0.0.1:22/${SSHD_TARGET}/g" /etc/nginx/nginx.conf
  fi
  # Configure and start nginx
  # TODO: restart nginx
  # TODO: make dependent on Kubernetes mode

  python $_RESOURCES_PATH/scripts/run_nginx.py
fi

# Copied from: https://docs.docker.com/config/containers/multi-service_container/
# Naive check runs checks once a minute to see if either of the processes exited.
# This illustrates part of the heavy lifting you need to do if you want to run
# more than one service in a container. The container exits with an error
# if it detects that either of the processes has exited.
# Otherwise it loops forever, waking up every 60 seconds
# If the greps find anything, they exit with 0 status (stored in $?)
while sleep 60; do
  if [ "${START_SSH}" == true ]; then
    ps aux |grep sshd |grep -q -v grep
    PROCESS_STATUS=$?
    if [ $PROCESS_STATUS -ne 0 ]; then
      echo "SSH Daemon stopped. Restart it..."
      start_ssh
    fi
  fi

  if [ "${START_JHUB}" == true ]; then
    ps aux |grep "jupyterhub " |grep -q -v grep
    PROCESS_STATUS=$?
    if [ $PROCESS_STATUS -ne 0 ]; then
      echo "JupyterHub stopped. Restart it..."
      start_jupyterhub
    fi
  fi

  if [ "${START_CHP}" == true ]; then
    ps aux |grep configurable-http-proxy |grep -q -v grep
    PROCESS_STATUS=$?
    if [ $PROCESS_STATUS -ne 0 ]; then
      echo "configurable-http-proxy stopped. Restart it..."
      start_http_proxy
    fi
  fi
done
